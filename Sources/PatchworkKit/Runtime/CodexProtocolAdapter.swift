import Foundation

/// Speaks Codex's own `codex app-server` JSON-RPC protocol and translates it into the app's
/// (Pi-shaped) command and event vocabulary.
///
/// Codex is asynchronous in a way Pi is not: nothing can be asked of a thread until `initialize`
/// has been answered, `initialized` has been sent, and a thread has been started or resumed. App
/// commands that arrive inside that window are held here and replayed once the thread id exists,
/// so nothing above this file has to know a handshake happened.
///
/// Everything retained per session is bounded: the deferred-command queue, the in-flight request
/// map, streaming text, the open-item map, and the approval map all have explicit caps.
public final class CodexProtocolAdapter: AgentProtocolAdapter, AdapterWriteback {
    public init() {}

    public let agent: AgentKind = .codex

    /// Codex only ever reports OpenAI models over this protocol.
    public static let provider = "openai"

    private enum Limit {
        static let queuedCommands = 32
        static let inFlightRequests = 256
        static let streamCharacters = 200_000
        static let toolOutputCharacters = 20_000
        static let openItems = 200
        static let pendingApprovals = 16
        static let listedItems = 500
    }

    /// What a client request was for, so its response can be routed without re-parsing it.
    private enum Pending {
        case initialize
        case openThread(resume: Bool)
        case models(appID: String?)
        case commands(appID: String)
        case turn(appID: String)
        case compact(appID: String)
        /// Answer the caller with an empty object once Codex confirms the request.
        case acknowledge(appID: String)
    }

    private struct QueuedCommand {
        let command: String
        let id: String
        let payload: [String: PiJSONValue]
    }

    private struct Stream {
        var isThinking: Bool
        var text: String
    }

    /// What kind of JSON-RPC result a pending dialog answer has to be turned back into.
    private enum ApprovalKind {
        case commandExecution
        case fileChange
        /// `item/permissions/requestApproval`: approving means granting exactly what was asked.
        case permissions(requested: PiJSONValue)
        /// Legacy `execCommandApproval` / `applyPatchApproval`, which use `ReviewDecision`.
        case reviewDecision
        case elicitation
        case userInput(questionID: String)
    }

    private struct PendingApproval {
        let requestID: PiJSONValue
        let kind: ApprovalKind
    }

    // MARK: - Session state

    private var cwd: URL?
    private var resumeThreadID: String?
    private var threadID: String?
    private var sessionFile: String?
    private var sessionName: String?
    private var didRetryThreadStart = false

    private var requestCounter = 0
    private var approvalCounter = 0
    private var pending: [Int: Pending] = [:]
    private var pendingOrder: [Int] = []
    private var queued: [QueuedCommand] = []
    private var pendingWrites: [Data] = []

    private var models: [PiJSONValue] = []
    private var modelID: String?
    private var effort: String?
    private var steeringMode = "all"
    private var followUpMode = "all"

    private var turnID: String?
    private var settledTurn: String?
    private var isCompacting = false
    private var isRetrying = false
    private var retryAttempt = 0

    private var streams: [String: Stream] = [:]
    private var streamOrder: [String] = []
    private var openTools: [String: String] = [:]
    private var openToolOrder: [String] = []

    private var lastUsage: PiJSONValue?
    private var totalUsage: PiJSONValue?
    private var contextWindow: Int?

    private var approvals: [String: PendingApproval] = [:]
    private var approvalOrder: [String] = []


    // MARK: - Launch

    public func launchArguments(sessionPath: URL?, cwd: URL) -> [String] {
        ["app-server", "--stdio"]
    }

    public func startupLines(sessionPath: URL?, cwd: URL) -> [Data] {
        self.cwd = cwd
        resumeThreadID = Self.threadID(fromRolloutPath: sessionPath)
        sessionFile = sessionPath?.standardizedFileURL.path
        let line = request("initialize", params: [
            "clientInfo": ["name": "patchwork", "title": "Patchwork", "version": Self.clientVersion]
        ], as: .initialize)
        return line.map { [$0] } ?? []
    }

    private static let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    /// `rollout-2026-07-31T00-11-22-<threadId>.jsonl`. Resuming by id is what Codex prefers, so
    /// the id is recovered from the filename rather than by handing the path back.
    public static func threadID(fromRolloutPath path: URL?) -> String? {
        guard let path else { return nil }
        let name = path.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-") else { return nil }
        let candidate = String(name.dropFirst("rollout-".count).suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    public func reset() {
        cwd = nil
        resumeThreadID = nil
        threadID = nil
        sessionFile = nil
        sessionName = nil
        didRetryThreadStart = false
        requestCounter = 0
        approvalCounter = 0
        pending.removeAll()
        pendingOrder.removeAll()
        queued.removeAll()
        pendingWrites.removeAll()
        models.removeAll()
        modelID = nil
        effort = nil
        steeringMode = "all"
        followUpMode = "all"
        turnID = nil
        settledTurn = nil
        isCompacting = false
        isRetrying = false
        retryAttempt = 0
        streams.removeAll()
        streamOrder.removeAll()
        openTools.removeAll()
        openToolOrder.removeAll()
        lastUsage = nil
        totalUsage = nil
        contextWindow = nil
        approvals.removeAll()
        approvalOrder.removeAll()
    }

    public func drainPendingWrites() -> [Data] {
        defer { pendingWrites.removeAll() }
        return pendingWrites
    }

    // MARK: - Outbound commands

    public func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        // A query about the session has no honest answer before the session exists, so it waits
        // for the handshake rather than reporting an empty state the caller would believe.
        if threadID == nil, Self.answeredFromAdapterState.contains(command) {
            return threadScoped(command, id: id, payload: payload)
        }
        switch command {
        case "get_state":
            return .immediate(stateValue())
        case "get_session_stats":
            return .immediate(statsValue())
        case "get_available_models":
            guard models.isEmpty else { return .immediate(modelsValue()) }
            return threadScoped(command, id: id, payload: payload)
        case "get_available_thinking_levels":
            return .immediate(.object(["levels": .array(thinkingLevels().map(PiJSONValue.string))]))
        case "set_model":
            guard let requested = payload["modelId"]?.stringValue ?? payload["id"]?.stringValue else {
                return .unsupported("a model change without a model id")
            }
            modelID = requested
            effort = defaultEffort(for: requested) ?? effort
            return .immediate(selectedModelValue())
        case "set_thinking_level":
            guard let level = payload["level"]?.stringValue else {
                return .unsupported("a thinking level change without a level")
            }
            effort = Self.codexEffort(forLevel: level)
            return .immediate(.object(["level": .string(level)]))
        case "cycle_model":
            cycleModel()
            return .immediate(.object([
                "model": selectedModelValue(),
                "thinkingLevel": .string(Self.thinkingLevel(forEffort: effort))
            ]))
        case "cycle_thinking_level":
            let levels = thinkingLevels()
            let current = Self.thinkingLevel(forEffort: effort)
            let next = levels.isEmpty ? current : levels[((levels.firstIndex(of: current) ?? -1) + 1) % levels.count]
            effort = Self.codexEffort(forLevel: next)
            return .immediate(.object(["level": .string(next)]))
        case "set_steering_mode":
            steeringMode = payload["mode"]?.stringValue ?? steeringMode
            return .immediate(.object(["mode": .string(steeringMode)]))
        case "set_follow_up_mode":
            followUpMode = payload["mode"]?.stringValue ?? followUpMode
            return .immediate(.object(["mode": .string(followUpMode)]))
        case "abort_retry":
            // Codex owns its own retry loop; there is nothing to cancel, and reporting failure
            // here would surface an error for a purely advisory command.
            return .immediate(.object([:]))
        case "abort":
            // Nothing is running, so there is nothing to interrupt; failing here would surface
            // an error toast for a stop the user already has.
            guard turnID != nil else { return .immediate(.object([:])) }
            return threadScoped(command, id: id, payload: payload)
        case "prompt", "compact", "set_session_name", "get_commands":
            return threadScoped(command, id: id, payload: payload)
        case "get_entries":
            return .unsupported("reading transcript entries over its protocol")
        case "get_fork_messages":
            return .unsupported("listing fork points")
        case "export_html":
            return .unsupported("exporting a conversation to HTML")
        default:
            return .unsupported("the \(command) command")
        }
    }

    /// Commands that need a live thread. Before the handshake finishes they are held, not failed.
    private func threadScoped(_ command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        guard let threadID else {
            guard queued.count < Limit.queuedCommands else {
                return .unsupported("more commands while its session is still starting")
            }
            queued.append(QueuedCommand(command: command, id: id, payload: payload))
            return .deferred
        }
        return write(line(for: command, id: id, payload: payload, threadID: threadID))
    }

    private func line(for command: String, id: String, payload: [String: PiJSONValue], threadID: String) -> Data? {
        switch command {
        case "prompt":
            let input = Self.userInput(from: payload)
            if let turnID, settledTurn != turnID {
                return request("turn/steer", params: [
                    "threadId": threadID, "expectedTurnId": turnID, "input": input
                ], as: .turn(appID: id))
            }
            var params: [String: Any] = ["threadId": threadID, "input": input]
            if let modelID { params["model"] = modelID }
            if let effort { params["effort"] = effort }
            return request("turn/start", params: params, as: .turn(appID: id))
        case "abort":
            guard let turnID else { return nil }
            return request("turn/interrupt", params: [
                "threadId": threadID, "turnId": turnID
            ], as: .acknowledge(appID: id))
        case "compact":
            return request("thread/compact/start", params: ["threadId": threadID], as: .compact(appID: id))
        case "set_session_name":
            guard let name = payload["name"]?.stringValue else { return nil }
            return request("thread/name/set", params: [
                "threadId": threadID, "name": name
            ], as: .acknowledge(appID: id))
        case "get_commands":
            return request("skills/list", params: [:], as: .commands(appID: id))
        case "get_available_models":
            // Held with the thread-scoped commands only because `model/list` must not race the
            // handshake, not because it needs a thread.
            return request("model/list", params: [:], as: .models(appID: id))
        default:
            return nil
        }
    }

    private func write(_ line: Data?) -> AdapterOutbound {
        guard let line else { return .unsupported("that command right now") }
        return .write([line])
    }

    /// Turns a Pi prompt payload into Codex `UserInput` items. Attachments arrive as inline
    /// base64, which Codex accepts as a data URL image input.
    private static func userInput(from payload: [String: PiJSONValue]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        let text = payload["message"]?.stringValue ?? ""
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        let attachments = payload["images"]?.arrayValue ?? payload["attachments"]?.arrayValue ?? []
        for attachment in attachments.prefix(20) {
            if let path = attachment["path"]?.stringValue {
                input.append(["type": "localImage", "path": path])
            } else if let data = attachment["data"]?.stringValue {
                let mime = attachment["mimeType"]?.stringValue ?? "image/png"
                input.append(["type": "image", "url": "data:\(mime);base64,\(data)"])
            }
        }
        if input.isEmpty { input.append(["type": "text", "text": ""]) }
        return input
    }

    public func encodeUncorrelated(_ value: PiJSONValue) -> [Data] {
        guard value["type"]?.stringValue == "extension_ui_response",
              let dialogID = value["id"]?.stringValue,
              let approval = takeApproval(dialogID) else { return [] }
        let cancelled = value["cancelled"]?.boolValue == true
        let confirmed = value["confirmed"]?.boolValue
        let choice = value["value"]?.stringValue
        let accepted = !cancelled && (confirmed ?? (choice.map { !Self.decliningChoices.contains($0) } ?? false))
        let forSession = choice == Self.approveForSessionChoice

        let result: [String: Any]
        switch approval.kind {
        case .commandExecution:
            result = ["decision": accepted ? (forSession ? "acceptForSession" : "accept") : (cancelled ? "cancel" : "decline")]
        case .fileChange:
            result = ["decision": accepted ? (forSession ? "acceptForSession" : "accept") : (cancelled ? "cancel" : "decline")]
        case .reviewDecision:
            result = ["decision": accepted ? (forSession ? "approved_for_session" : "approved") : (cancelled ? "abort" : "denied")]
        case let .permissions(requested):
            // An empty profile grants nothing, which is how this protocol expresses a refusal.
            result = [
                "permissions": accepted ? Self.grantedPermissions(from: requested) : [String: Any](),
                "scope": forSession ? "session" : "turn"
            ]
        case .elicitation:
            result = ["action": accepted ? "accept" : (cancelled ? "cancel" : "decline")]
        case let .userInput(questionID):
            result = ["answers": [questionID: ["answers": accepted ? [choice ?? ""] : []]]]
        }
        guard let line = AdapterEncoding.line([
            "id": Self.rpcIdentifier(approval.requestID), "result": result
        ]) else { return [] }
        return [line]
    }

    /// JSON-RPC ids round-trip verbatim: an integer id must not come back as `3.0`.
    private static func rpcIdentifier(_ value: PiJSONValue) -> Any {
        if case let .number(number) = value, number == number.rounded() { return Int(number) }
        return value.anyValue
    }

    private static func grantedPermissions(from requested: PiJSONValue) -> [String: Any] {
        var granted: [String: Any] = [:]
        if let fileSystem = requested["fileSystem"] { granted["fileSystem"] = fileSystem.anyValue }
        if let network = requested["network"] { granted["network"] = network.anyValue }
        return granted
    }

    // MARK: - Inbound

    public func decode(line: Data) -> [AdapterInbound] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        let params = object["params"] as? [String: Any] ?? [:]
        if let method = object["method"] as? String {
            guard let id = object["id"], !(id is NSNull) else {
                return handle(notification: method, params: params)
            }
            return handle(serverRequest: method, id: PiJSONValue(any: id), params: params)
        }
        guard let rpcID = (object["id"] as? NSNumber)?.intValue, let entry = takePending(rpcID) else { return [] }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex rejected the request."
            return handle(failure: entry, message: message)
        }
        return handle(result: object["result"] as? [String: Any] ?? [:], for: entry)
    }

    // MARK: Responses

    private func handle(result: [String: Any], for entry: Pending) -> [AdapterInbound] {
        switch entry {
        case .initialize:
            enqueue(AdapterEncoding.line(["method": "initialized", "params": [String: Any]()]))
            openThread()
            return []
        case .openThread:
            return threadOpened(result)
        case let .models(appID):
            models = ((result["data"] as? [Any]) ?? [])
                .prefix(Limit.listedItems)
                .map { PiJSONValue(any: $0) }
                .filter { $0["hidden"]?.boolValue != true }
            if modelID == nil {
                modelID = models.first(where: { $0["isDefault"]?.boolValue == true })?["id"]?.stringValue
                    ?? models.first?["id"]?.stringValue
            }
            guard let appID else { return [] }
            return [.response(id: appID, value: AdapterEncoding.response(id: appID, data: modelsValue()))]
        case let .commands(appID):
            return [.response(id: appID, value: AdapterEncoding.response(id: appID, data: commandsValue(result)))]
        case let .turn(appID):
            if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String {
                turnID = id
                settledTurn = nil
            }
            return [.response(id: appID, value: AdapterEncoding.response(id: appID, data: .object([:])))]
        case let .compact(appID):
            isCompacting = true
            return [
                .response(id: appID, value: AdapterEncoding.response(id: appID, data: .object([:]))),
                .event(AdapterEncoding.event("compaction_start"))
            ]
        case let .acknowledge(appID):
            return [.response(id: appID, value: AdapterEncoding.response(id: appID, data: .object([:])))]
        }
    }

    private func handle(failure entry: Pending, message: String) -> [AdapterInbound] {
        switch entry {
        case .initialize:
            return []
        case let .openThread(resume):
            // A rollout whose thread Codex cannot load must still give the user a usable session.
            guard resume, !didRetryThreadStart else { return [] }
            didRetryThreadStart = true
            resumeThreadID = nil
            openThread()
            return []
        case let .models(appID):
            guard let appID else { return [] }
            return [.response(id: appID, value: rejection(id: appID, message: message))]
        case let .commands(appID), let .turn(appID), let .compact(appID), let .acknowledge(appID):
            if case .compact = entry { isCompacting = false }
            return [.response(id: appID, value: rejection(id: appID, message: message))]
        }
    }

    private func openThread() {
        if let resumeThreadID {
            var params: [String: Any] = ["threadId": resumeThreadID]
            if let cwd { params["cwd"] = cwd.standardizedFileURL.path }
            enqueue(request("thread/resume", params: params, as: .openThread(resume: true)))
        } else {
            var params: [String: Any] = [:]
            if let cwd { params["cwd"] = cwd.standardizedFileURL.path }
            enqueue(request("thread/start", params: params, as: .openThread(resume: false)))
        }
        enqueue(request("model/list", params: [:], as: .models(appID: nil)))
    }

    private func threadOpened(_ result: [String: Any]) -> [AdapterInbound] {
        let thread = result["thread"] as? [String: Any] ?? [:]
        guard let id = thread["id"] as? String else { return [] }
        threadID = id
        sessionFile = thread["path"] as? String ?? sessionFile
        sessionName = thread["name"] as? String ?? sessionName
        modelID = result["model"] as? String ?? modelID
        effort = result["reasoningEffort"] as? String ?? effort
        return flushQueuedCommands()
    }

    /// Commands this adapter answers from its own state rather than from the wire. They are held
    /// until the thread exists, then answered with the state the handshake produced.
    static let answeredFromAdapterState: Set<String> = [
        "get_state", "get_session_stats", "get_available_thinking_levels"
    ]

    private func flushQueuedCommands() -> [AdapterInbound] {
        guard threadID != nil else { return [] }
        let commands = queued
        queued.removeAll()
        var inbound: [AdapterInbound] = []
        for entry in commands {
            // Re-encoding now that the thread exists routes each command down whichever path it
            // would have taken had it arrived after the handshake.
            switch encode(command: entry.command, id: entry.id, payload: entry.payload) {
            case let .write(lines):
                for line in lines { enqueue(line) }
            case let .immediate(value):
                inbound.append(.response(id: entry.id, value: AdapterEncoding.response(id: entry.id, data: value)))
            case let .unsupported(what):
                inbound.append(.response(
                    id: entry.id,
                    value: AdapterEncoding.failure(id: entry.id, message: "\(agent.displayName) does not support \(what).")
                ))
            case .deferred:
                // Cannot happen: the thread now exists, so nothing re-queues. Answer rather than
                // strand the caller if it ever does.
                inbound.append(.response(
                    id: entry.id, value: AdapterEncoding.response(id: entry.id, data: .object([:]))
                ))
            }
        }
        return inbound
    }

    // MARK: Notifications

    private func handle(notification method: String, params: [String: Any]) -> [AdapterInbound] {
        switch method {
        case "thread/started":
            let thread = params["thread"] as? [String: Any] ?? [:]
            if threadID == nil { threadID = thread["id"] as? String }
            sessionFile = thread["path"] as? String ?? sessionFile
            return []
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return [] }
            return beginTurn(id)
        case "turn/completed":
            return completeTurn(params["turn"] as? [String: Any] ?? [:])
        case "item/started":
            return startItem(params["item"] as? [String: Any] ?? [:])
        case "item/completed":
            return completeItem(params["item"] as? [String: Any] ?? [:])
        case "item/agentMessage/delta":
            return append(delta: params["delta"] as? String, to: params["itemId"] as? String, thinking: false)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return append(delta: params["delta"] as? String, to: params["itemId"] as? String, thinking: true)
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            return toolUpdate(itemID: params["itemId"] as? String, text: params["delta"] as? String)
        case "item/fileChange/patchUpdated":
            return toolUpdate(itemID: params["itemId"] as? String, text: Self.patchSummary(params))
        case "item/mcpToolCall/progress":
            return toolUpdate(itemID: params["itemId"] as? String, text: params["message"] as? String)
        case "thread/name/updated":
            sessionName = params["threadName"] as? String
            return [.event(AdapterEncoding.event("session_info_changed", [
                "name": .string(sessionName ?? "")
            ]))]
        case "thread/tokenUsage/updated":
            recordUsage(params["tokenUsage"] as? [String: Any] ?? [:])
            return []
        case "thread/compacted":
            isCompacting = false
            return [.event(AdapterEncoding.event("compaction_end"))]
        case "error":
            return handleError(params)
        default:
            // Unknown or unmapped notifications are dropped rather than surfaced as junk events.
            return []
        }
    }

    private func beginTurn(_ id: String) -> [AdapterInbound] {
        guard turnID != id || settledTurn == id else { return [] }
        turnID = id
        settledTurn = nil
        isRetrying = false
        retryAttempt = 0
        return [.event(AdapterEncoding.event("agent_start")), .event(AdapterEncoding.event("turn_start"))]
    }

    /// The one place a turn ends. `agent_settled` unblocks the composer, so it fires exactly once
    /// per turn id no matter how many terminal notifications Codex sends for it.
    private func completeTurn(_ turn: [String: Any]) -> [AdapterInbound] {
        let status = turn["status"] as? String ?? "completed"
        guard status != "inProgress" else { return [] }
        let id = turn["id"] as? String ?? turnID ?? ""
        guard settledTurn != id else { return [] }
        settledTurn = id
        turnID = nil

        var inbound = closeOpenItems()
        if status == "failed", let message = (turn["error"] as? [String: Any])?["message"] as? String {
            inbound.append(.event(AdapterEncoding.event("message_end", [
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
                    "stopReason": .string("error"),
                    "isError": .bool(true)
                ])
            ])))
        }
        if isRetrying {
            isRetrying = false
            var fields: [String: PiJSONValue] = ["success": .bool(status == "completed")]
            if status != "completed",
               let message = (turn["error"] as? [String: Any])?["message"] as? String {
                fields["finalError"] = .string(message)
            }
            inbound.append(.event(AdapterEncoding.event("auto_retry_end", fields)))
        }
        inbound.append(.event(AdapterEncoding.event("turn_end")))
        inbound.append(.event(AdapterEncoding.event("agent_settled")))
        return inbound
    }

    private func startItem(_ item: [String: Any]) -> [AdapterInbound] {
        guard let itemID = item["id"] as? String, let type = item["type"] as? String else { return [] }
        var inbound = resumedAfterRetry()
        switch type {
        case "agentMessage", "reasoning":
            openStream(itemID, thinking: type == "reasoning")
            inbound.append(.event(AdapterEncoding.event("message_start", [
                "message": .object(["role": .string("assistant"), "content": .array([])])
            ])))
        case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch":
            let name = Self.toolName(for: item)
            openTool(itemID, name: name)
            inbound.append(.event(AdapterEncoding.event("tool_execution_start", [
                "toolCallId": .string(itemID),
                "toolName": .string(name),
                "args": Self.toolArguments(for: item)
            ])))
        default:
            break
        }
        return inbound
    }

    private func completeItem(_ item: [String: Any]) -> [AdapterInbound] {
        guard let itemID = item["id"] as? String, let type = item["type"] as? String else { return [] }
        switch type {
        case "agentMessage":
            let text = item["text"] as? String ?? streams[itemID]?.text ?? ""
            closeStream(itemID)
            guard !text.isEmpty else { return [] }
            return [.event(AdapterEncoding.event("message_end", [
                "message": assistantMessage(text: text, thinking: false, stopReason: "stop")
            ]))]
        case "reasoning":
            let parts = ((item["summary"] as? [String]) ?? []) + ((item["content"] as? [String]) ?? [])
            let text = parts.isEmpty ? (streams[itemID]?.text ?? "") : parts.joined(separator: "\n\n")
            closeStream(itemID)
            guard !text.isEmpty else { return [] }
            return [.event(AdapterEncoding.event("message_end", [
                "message": assistantMessage(text: text, thinking: true, stopReason: "toolUse")
            ]))]
        case "userMessage":
            let text = Self.userMessageText(item)
            guard !text.isEmpty else { return [] }
            return [.event(AdapterEncoding.event("message_end", [
                "message": .object([
                    "role": .string("user"),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])])
                ])
            ]))]
        case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch":
            closeTool(itemID)
            return [.event(AdapterEncoding.event("tool_execution_end", [
                "toolCallId": .string(itemID),
                "result": .object(["content": .array([
                    .object(["type": .string("text"), "text": .string(Self.toolResultText(for: item))])
                ])]),
                "isError": .bool(Self.toolFailed(item))
            ]))]
        case "contextCompaction":
            isCompacting = false
            return [.event(AdapterEncoding.event("compaction_end"))]
        default:
            return []
        }
    }

    private func append(delta: String?, to itemID: String?, thinking: Bool) -> [AdapterInbound] {
        guard let delta, !delta.isEmpty, let itemID else { return [] }
        if streams[itemID] == nil { openStream(itemID, thinking: thinking) }
        guard var stream = streams[itemID] else { return [] }
        // Bounded: a runaway stream keeps its head, which is what the reader is looking at.
        if stream.text.count < Limit.streamCharacters {
            stream.text += delta
            if stream.text.count > Limit.streamCharacters {
                stream.text = String(stream.text.prefix(Limit.streamCharacters))
            }
        }
        streams[itemID] = stream
        return [.event(AdapterEncoding.event("message_update", [
            "message": assistantMessage(text: stream.text, thinking: stream.isThinking, stopReason: nil)
        ]))]
    }

    private func toolUpdate(itemID: String?, text: String?) -> [AdapterInbound] {
        guard let itemID, openTools[itemID] != nil, let text, !text.isEmpty else { return [] }
        return [.event(AdapterEncoding.event("tool_execution_update", [
            "toolCallId": .string(itemID),
            "partialResult": .object(["content": .array([
                .object(["type": .string("text"), "text": .string(Self.bounded(text))])
            ])])
        ]))]
    }

    private func handleError(_ params: [String: Any]) -> [AdapterInbound] {
        let message = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex reported an error."
        guard params["willRetry"] as? Bool == true else {
            guard isRetrying else { return [] }
            isRetrying = false
            return [.event(AdapterEncoding.event("auto_retry_end", [
                "success": .bool(false), "finalError": .string(Self.bounded(message, limit: 1_000))
            ]))]
        }
        isRetrying = true
        retryAttempt += 1
        return [.event(AdapterEncoding.event("auto_retry_start", [
            "attempt": .number(Double(retryAttempt)),
            "delayMs": .number(0),
            "errorMessage": .string(Self.bounded(message, limit: 1_000))
        ]))]
    }

    /// Codex never says "the retry worked"; the next piece of turn activity is that signal.
    private func resumedAfterRetry() -> [AdapterInbound] {
        guard isRetrying else { return [] }
        isRetrying = false
        return [.event(AdapterEncoding.event("auto_retry_end", ["success": .bool(true)]))]
    }

    // MARK: Server requests

    private func handle(serverRequest method: String, id: PiJSONValue, params: [String: Any]) -> [AdapterInbound] {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = params["command"] as? String ?? "a command"
            let cwd = params["cwd"] as? String
            return [dialog(
                id: id,
                kind: method == "execCommandApproval" ? .reviewDecision : .commandExecution,
                title: "Codex wants to run a command",
                message: [command, cwd.map { "in \($0)" }, params["reason"] as? String]
                    .compactMap { $0 }.joined(separator: "\n"),
                options: Self.approvalChoices
            )]
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let files = ((params["fileChanges"] as? [String: Any])?.keys).map { Array($0) } ?? []
            return [dialog(
                id: id,
                kind: method == "applyPatchApproval" ? .reviewDecision : .fileChange,
                title: "Codex wants to edit files",
                message: [params["reason"] as? String, files.prefix(20).joined(separator: "\n")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                options: Self.approvalChoices
            )]
        case "item/permissions/requestApproval":
            let requested = PiJSONValue(any: params["permissions"])
            return [dialog(
                id: id,
                kind: .permissions(requested: requested),
                title: "Codex wants more access",
                message: [params["reason"] as? String, params["cwd"] as? String]
                    .compactMap { $0 }.joined(separator: "\n"),
                options: Self.approvalChoices
            )]
        case "mcpServer/elicitation/request":
            return [dialog(
                id: id,
                kind: .elicitation,
                title: "Codex tool request",
                message: params["message"] as? String ?? "",
                options: [Self.approveChoice, Self.declineChoice]
            )]
        case "item/tool/requestUserInput":
            let questions = params["questions"] as? [[String: Any]] ?? []
            guard let question = questions.first, let questionID = question["id"] as? String else { return [] }
            let options = (question["options"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
            return [dialog(
                id: id,
                kind: .userInput(questionID: questionID),
                title: question["header"] as? String ?? "Codex has a question",
                message: question["question"] as? String ?? "",
                options: options
            )]
        default:
            // Requests this adapter does not answer (auth token refresh, attestation, tool calls)
            // are left to Codex's own fallbacks rather than answered wrongly.
            return []
        }
    }

    private static let approveChoice = "Approve"
    private static let approveForSessionChoice = "Approve for the rest of this session"
    private static let declineChoice = "Decline"
    private static let approvalChoices = [approveChoice, approveForSessionChoice, declineChoice]
    private static let decliningChoices: Set<String> = [declineChoice]

    private func dialog(
        id: PiJSONValue, kind: ApprovalKind, title: String, message: String, options: [String]
    ) -> AdapterInbound {
        approvalCounter += 1
        let dialogID = "codex-approval-\(approvalCounter)"
        remember(approval: PendingApproval(requestID: id, kind: kind), as: dialogID)
        var fields: [String: PiJSONValue] = [
            "id": .string(dialogID),
            "method": .string(options.isEmpty ? "input" : "select"),
            "title": .string(title),
            "message": .string(Self.bounded(message, limit: 4_000))
        ]
        if !options.isEmpty {
            fields["options"] = .array(options.prefix(20).map(PiJSONValue.string))
        }
        return .event(AdapterEncoding.event("extension_ui_request", fields))
    }

    // MARK: - Projections the app reads

    private func stateValue() -> PiJSONValue {
        var object: [String: PiJSONValue] = [
            "isStreaming": .bool(turnID != nil),
            "isCompacting": .bool(isCompacting),
            "steeringMode": .string(steeringMode),
            "followUpMode": .string(followUpMode),
            "steeringQueue": .array([]),
            "followUpQueue": .array([]),
            "thinkingLevel": .string(Self.thinkingLevel(forEffort: effort)),
            "model": selectedModelValue()
        ]
        if let threadID { object["sessionId"] = .string(threadID) }
        if let sessionFile { object["sessionFile"] = .string(sessionFile) }
        if let sessionName { object["sessionName"] = .string(sessionName) }
        return .object(object)
    }

    private func statsValue() -> PiJSONValue {
        var object: [String: PiJSONValue] = ["tokens": totalUsage ?? .object([:])]
        if let window = contextWindow, window > 0 {
            let used = totalUsage?["total"]?.intValue ?? 0
            object["contextUsage"] = .object([
                "tokens": .number(Double(used)),
                "contextWindow": .number(Double(window)),
                "percent": .number(Double(used) / Double(window) * 100)
            ])
        }
        return .object(object)
    }

    private func modelsValue() -> PiJSONValue {
        .object(["models": .array(models.compactMap { model in
            guard let id = model["id"]?.stringValue else { return nil }
            return .object([
                "provider": .string(Self.provider),
                "id": .string(id),
                "name": .string(model["displayName"]?.stringValue ?? id),
                "reasoning": .bool(!(model["supportedReasoningEfforts"]?.arrayValue ?? []).isEmpty)
            ])
        })])
    }

    private func selectedModelValue() -> PiJSONValue {
        guard let modelID else { return .object([:]) }
        return .object([
            "id": .string(modelID),
            "name": .string(models.first { $0["id"]?.stringValue == modelID }?["displayName"]?.stringValue ?? modelID),
            "provider": .string(Self.provider)
        ])
    }

    private func commandsValue(_ result: [String: Any]) -> PiJSONValue {
        var commands: [PiJSONValue] = []
        for entry in (result["data"] as? [[String: Any]] ?? []) {
            for skill in (entry["skills"] as? [[String: Any]] ?? []) {
                guard let name = skill["name"] as? String, skill["enabled"] as? Bool != false else { continue }
                var command: [String: PiJSONValue] = [
                    "name": .string(name),
                    "source": .string("skill"),
                    "description": .string(skill["description"] as? String ?? "")
                ]
                if let path = skill["path"] as? String { command["sourceInfo"] = .object(["path": .string(path)]) }
                commands.append(.object(command))
                if commands.count >= Limit.listedItems { break }
            }
        }
        return .object(["commands": .array(commands)])
    }

    /// Codex advertises reasoning efforts per model; the UI speaks Pi's level vocabulary.
    private func thinkingLevels() -> [String] {
        let selected = models.first { $0["id"]?.stringValue == modelID } ?? models.first
        let efforts = (selected?["supportedReasoningEfforts"]?.arrayValue ?? [])
            .compactMap { $0["reasoningEffort"]?.stringValue ?? $0.stringValue }
        let levels = efforts.map(Self.thinkingLevel(forEffort:))
        return levels.isEmpty ? [Self.thinkingLevel(forEffort: effort)] : levels
    }

    private func defaultEffort(for modelID: String) -> String? {
        models.first { $0["id"]?.stringValue == modelID }?["defaultReasoningEffort"]?.stringValue
    }

    private func cycleModel() {
        guard !models.isEmpty else { return }
        let ids = models.compactMap { $0["id"]?.stringValue }
        guard !ids.isEmpty else { return }
        let next = ids[((ids.firstIndex(of: modelID ?? "") ?? -1) + 1) % ids.count]
        modelID = next
        effort = defaultEffort(for: next) ?? effort
    }

    public static func thinkingLevel(forEffort effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return "off" }
        return effort == "none" ? "off" : effort
    }

    public static func codexEffort(forLevel level: String) -> String {
        level == "off" ? "none" : level
    }

    private func recordUsage(_ usage: [String: Any]) {
        lastUsage = Self.usageValue(usage["last"] as? [String: Any])
        totalUsage = Self.usageValue(usage["total"] as? [String: Any])
        contextWindow = (usage["modelContextWindow"] as? NSNumber)?.intValue ?? contextWindow
    }

    /// Codex reports total input including the cached portion; Pi counts them separately.
    private static func usageValue(_ breakdown: [String: Any]?) -> PiJSONValue? {
        guard let breakdown else { return nil }
        let cacheRead = (breakdown["cachedInputTokens"] as? NSNumber)?.intValue ?? 0
        let input = max(0, ((breakdown["inputTokens"] as? NSNumber)?.intValue ?? 0) - cacheRead)
        let output = (breakdown["outputTokens"] as? NSNumber)?.intValue ?? 0
        return .object([
            "input": .number(Double(input)),
            "output": .number(Double(output)),
            "cacheRead": .number(Double(cacheRead)),
            "cacheWrite": .number(Double((breakdown["cacheWriteInputTokens"] as? NSNumber)?.intValue ?? 0)),
            "total": .number(Double((breakdown["totalTokens"] as? NSNumber)?.intValue ?? (input + output)))
        ])
    }

    private func assistantMessage(text: String, thinking: Bool, stopReason: String?) -> PiJSONValue {
        var message: [String: PiJSONValue] = [
            "role": .string("assistant"),
            "content": .array([thinking
                ? .object(["type": .string("thinking"), "thinking": .string(text)])
                : .object(["type": .string("text"), "text": .string(text)])]),
            "provider": .string(Self.provider)
        ]
        if let modelID { message["model"] = .string(modelID) }
        if let stopReason { message["stopReason"] = .string(stopReason) }
        if stopReason != nil, let lastUsage { message["usage"] = lastUsage }
        return .object(message)
    }

    // MARK: - Item helpers

    private static func toolName(for item: [String: Any]) -> String {
        switch item["type"] as? String {
        case "commandExecution": return "bash"
        case "fileChange": return "edit"
        case "webSearch": return "web_search"
        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp"
            return "\(server)_\(item["tool"] as? String ?? "tool")"
        case "dynamicToolCall": return item["tool"] as? String ?? "tool"
        default: return "tool"
        }
    }

    private static func toolArguments(for item: [String: Any]) -> PiJSONValue {
        switch item["type"] as? String {
        case "commandExecution":
            var args: [String: PiJSONValue] = ["command": .string(bounded(item["command"] as? String ?? "", limit: 2_000))]
            if let cwd = item["cwd"] as? String { args["cwd"] = .string(cwd) }
            return .object(args)
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            var args: [String: PiJSONValue] = ["paths": .array(paths.prefix(50).map(PiJSONValue.string))]
            if let first = paths.first { args["path"] = .string(first) }
            return .object(args)
        case "webSearch":
            let query = item["query"] as? String ?? ""
            return .object(["query": .string(query), "title": .string(query)])
        default:
            return PiJSONValue(any: item["arguments"]).boundedProjection()
        }
    }

    private static func toolResultText(for item: [String: Any]) -> String {
        switch item["type"] as? String {
        case "commandExecution":
            return bounded(item["aggregatedOutput"] as? String ?? "", limit: Limit.toolOutputCharacters)
        case "fileChange":
            let changes = (item["changes"] as? [[String: Any]] ?? []).prefix(50).map {
                "\(($0["kind"] as? String ?? "update")) \(($0["path"] as? String ?? ""))"
            }
            return bounded(changes.joined(separator: "\n"), limit: Limit.toolOutputCharacters)
        case "mcpToolCall":
            if let error = (item["error"] as? [String: Any])?["message"] as? String { return bounded(error) }
            let content = ((item["result"] as? [String: Any])?["content"] as? [Any] ?? [])
                .compactMap { ($0 as? [String: Any])?["text"] as? String }
            return bounded(content.joined(separator: "\n"), limit: Limit.toolOutputCharacters)
        case "dynamicToolCall":
            let content = (item["contentItems"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            return bounded(content.joined(separator: "\n"), limit: Limit.toolOutputCharacters)
        case "webSearch":
            return bounded(item["query"] as? String ?? "")
        default:
            return ""
        }
    }

    private static func toolFailed(_ item: [String: Any]) -> Bool {
        let status = item["status"] as? String
        if status == "failed" || status == "declined" { return true }
        if item["success"] as? Bool == false { return true }
        if item["error"] != nil, !(item["error"] is NSNull) { return true }
        if let exitCode = (item["exitCode"] as? NSNumber)?.intValue, exitCode != 0 { return true }
        return false
    }

    private static func userMessageText(_ item: [String: Any]) -> String {
        let parts = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return bounded(parts.joined(separator: "\n"), limit: Limit.toolOutputCharacters)
    }

    private static func patchSummary(_ params: [String: Any]) -> String {
        let changes = (params["changes"] as? [[String: Any]] ?? []).prefix(50).map {
            "\(($0["kind"] as? String ?? "update")) \(($0["path"] as? String ?? ""))"
        }
        return changes.joined(separator: "\n")
    }

    private static func bounded(_ value: String, limit: Int = 2_000) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }

    // MARK: - Bounded bookkeeping

    private func request(_ method: String, params: [String: Any], as entry: Pending) -> Data? {
        requestCounter += 1
        let rpcID = requestCounter
        guard let line = AdapterEncoding.line([
            "id": rpcID, "method": method, "params": params
        ]) else { return nil }
        pending[rpcID] = entry
        pendingOrder.append(rpcID)
        while pendingOrder.count > Limit.inFlightRequests {
            pending.removeValue(forKey: pendingOrder.removeFirst())
        }
        return line
    }

    private func takePending(_ rpcID: Int) -> Pending? {
        pendingOrder.removeAll { $0 == rpcID }
        return pending.removeValue(forKey: rpcID)
    }

    private func enqueue(_ line: Data?) {
        guard let line else { return }
        pendingWrites.append(line)
    }

    private func rejection(id: String, message: String) -> PiJSONValue {
        .object([
            "type": .string("response"),
            "id": .string(id),
            "success": .bool(false),
            "error": .string(Self.bounded(message, limit: 1_000))
        ])
    }

    private func openStream(_ itemID: String, thinking: Bool) {
        if streams[itemID] == nil { streamOrder.append(itemID) }
        streams[itemID] = Stream(isThinking: thinking, text: streams[itemID]?.text ?? "")
        while streamOrder.count > Limit.openItems {
            streams.removeValue(forKey: streamOrder.removeFirst())
        }
    }

    private func closeStream(_ itemID: String) {
        streams.removeValue(forKey: itemID)
        streamOrder.removeAll { $0 == itemID }
    }

    private func openTool(_ itemID: String, name: String) {
        if openTools[itemID] == nil { openToolOrder.append(itemID) }
        openTools[itemID] = name
        while openToolOrder.count > Limit.openItems {
            openTools.removeValue(forKey: openToolOrder.removeFirst())
        }
    }

    private func closeTool(_ itemID: String) {
        openTools.removeValue(forKey: itemID)
        openToolOrder.removeAll { $0 == itemID }
    }

    /// A turn can end with items Codex never completed (an interrupt). Their live rows would
    /// otherwise spin forever, so they are closed here before the turn settles.
    private func closeOpenItems() -> [AdapterInbound] {
        var inbound: [AdapterInbound] = []
        for itemID in openToolOrder {
            inbound.append(.event(AdapterEncoding.event("tool_execution_end", [
                "toolCallId": .string(itemID),
                "result": .object(["content": .array([
                    .object(["type": .string("text"), "text": .string("Interrupted.")])
                ])]),
                "isError": .bool(true)
            ])))
        }
        openTools.removeAll()
        openToolOrder.removeAll()
        for itemID in streamOrder {
            guard let stream = streams[itemID], !stream.text.isEmpty else { continue }
            inbound.append(.event(AdapterEncoding.event("message_end", [
                "message": assistantMessage(
                    text: stream.text, thinking: stream.isThinking, stopReason: "stop"
                )
            ])))
        }
        streams.removeAll()
        streamOrder.removeAll()
        return inbound
    }

    private func remember(approval: PendingApproval, as dialogID: String) {
        approvals[dialogID] = approval
        approvalOrder.append(dialogID)
        while approvalOrder.count > Limit.pendingApprovals {
            approvals.removeValue(forKey: approvalOrder.removeFirst())
        }
    }

    private func takeApproval(_ dialogID: String) -> PendingApproval? {
        approvalOrder.removeAll { $0 == dialogID }
        return approvals.removeValue(forKey: dialogID)
    }
}
