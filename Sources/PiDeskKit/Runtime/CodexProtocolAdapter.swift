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
        static let userInputQuestions = 3
        static let listedItems = 500
        static let settledTurns = 64
    }

    private struct QueuedCommand {
        let command: String
        let id: String
        let payload: [String: PiJSONValue]
    }

    /// What a client request was for, so its response can be routed without re-parsing it.
    private enum Pending {
        case initialize
        case openThread(resume: Bool)
        case models(appID: String?)
        case commands(appID: String)
        case turn(
            entry: QueuedCommand,
            startsTurn: Bool,
            startToken: Int?,
            responseExpected: Bool,
            retryCount: Int
        )
        case compact(appID: String)
        case fastMode(appID: String, enabled: Bool)
        /// Answer the caller with an empty object once Codex confirms the request.
        case acknowledge(appID: String)

        var appID: String? {
            switch self {
            case .initialize, .openThread:
                nil
            case let .models(appID):
                appID
            case let .commands(appID), let .compact(appID), let .fastMode(appID, _),
                 let .acknowledge(appID):
                appID
            case let .turn(entry, _, _, _, _):
                entry.id
            }
        }

        var startToken: Int? {
            guard case let .turn(_, startsTurn, token, _, _) = self, startsTurn else { return nil }
            return token
        }
    }

    private struct Stream {
        var isThinking: Bool
        var phase: String?
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
        case userInput(groupID: String, questionID: String)
    }

    private struct PendingApproval {
        let requestID: PiJSONValue
        let kind: ApprovalKind
    }

    private struct PendingUserInputGroup {
        let requestID: PiJSONValue
        let questionIDs: [String]
        var answers: [String: [String]] = [:]
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
    private var userInputGroupCounter = 0
    private var pending: [Int: Pending] = [:]
    private var pendingOrder: [Int] = []
    private var queued: [QueuedCommand] = []
    private var pendingWrites: [Data] = []

    private var models: [PiJSONValue] = []
    private var modelID: String?
    private var effort: String?
    private var serviceTier: String?
    private var steeringMode = "all"
    private var followUpMode = "all"

    private var turnID: String?
    private var activeTurnID: String?
    private var turnStartCounter = 0
    private var pendingTurnStartToken: Int?
    private var turnStartPending: Bool { pendingTurnStartToken != nil }
    private var settledTurns: Set<String> = []
    private var settledTurnOrder: [String] = []
    private var pendingSteers: [QueuedCommand] = []
    private var pendingAborts: [QueuedCommand] = []
    private var followUps: [QueuedCommand] = []
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
    private var userInputGroups: [String: PendingUserInputGroup] = [:]


    // MARK: - Launch

    public func launchArguments(sessionPath: URL?, cwd: URL) -> [String] {
        ["app-server", "--stdio"]
    }

    public func startupLines(sessionPath: URL?, cwd: URL) -> [Data] {
        self.cwd = cwd
        resumeThreadID = Self.threadID(fromRolloutPath: sessionPath)
        sessionFile = sessionPath?.standardizedFileURL.path
        let line = request("initialize", params: [
            "clientInfo": ["name": "pi-desktop", "title": "Pi Desktop", "version": Self.clientVersion]
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
        userInputGroupCounter = 0
        pending.removeAll()
        pendingOrder.removeAll()
        queued.removeAll()
        pendingWrites.removeAll()
        models.removeAll()
        modelID = nil
        effort = nil
        serviceTier = nil
        steeringMode = "all"
        followUpMode = "all"
        turnID = nil
        activeTurnID = nil
        turnStartCounter = 0
        pendingTurnStartToken = nil
        settledTurns.removeAll()
        settledTurnOrder.removeAll()
        pendingSteers.removeAll()
        pendingAborts.removeAll()
        followUps.removeAll()
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
        userInputGroups.removeAll()
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
        case "set_fast_mode":
            return threadScoped(command, id: id, payload: payload)
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
            guard turnID != nil || turnStartPending else { return .immediate(.object([:])) }
            if activeTurnID == nil {
                guard pendingAborts.count < Limit.queuedCommands else {
                    return .unsupported("more stop requests before the turn starts")
                }
                pendingAborts.append(QueuedCommand(command: command, id: id, payload: payload))
                return .deferred
            }
            return threadScoped(command, id: id, payload: payload)
        case "follow_up":
            if turnID != nil || turnStartPending {
                guard followUps.count < Limit.queuedCommands else {
                    return .unsupported("more queued follow-up messages")
                }
                followUps.append(QueuedCommand(command: command, id: id, payload: payload))
                return .immediateWithEvents(.object([:]), [queueUpdateValue()])
            }
            return threadScoped(command, id: id, payload: payload)
        case "prompt", "steer":
            if (turnID != nil || turnStartPending), activeTurnID == nil {
                guard pendingSteers.count < Limit.queuedCommands else {
                    return .unsupported("more steering messages before the turn starts")
                }
                pendingSteers.append(QueuedCommand(command: command, id: id, payload: payload))
                return .deferred
            }
            return threadScoped(command, id: id, payload: payload)
        case "compact", "set_session_name", "get_commands":
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

    public func rollbackRejectedEncoding(
        command: String, id: String, payload: [String: PiJSONValue]
    ) {
        queued.removeAll { $0.id == id }
        pendingSteers.removeAll { $0.id == id }
        pendingAborts.removeAll { $0.id == id }
        followUps.removeAll { $0.id == id }
        let rpcIDs = pending.compactMap { rpcID, entry in entry.appID == id ? rpcID : nil }
        for rpcID in rpcIDs {
            if let token = pending[rpcID]?.startToken, pendingTurnStartToken == token {
                pendingTurnStartToken = nil
            }
            _ = takePending(rpcID)
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
        let entry = QueuedCommand(command: command, id: id, payload: payload)
        switch command {
        case "prompt", "steer", "follow_up":
            let input = Self.userInput(from: payload)
            if command != "follow_up", let activeTurnID {
                return request("turn/steer", params: [
                    "threadId": threadID,
                    "expectedTurnId": activeTurnID,
                    "input": input,
                    "clientUserMessageId": id
                ], as: .turn(
                    entry: entry, startsTurn: false, startToken: nil,
                    responseExpected: true, retryCount: 0
                ))
            }
            return makeTurnStart(entry, threadID: threadID, responseExpected: true, retryCount: 0)
        case "abort":
            guard let activeTurnID else { return nil }
            return request("turn/interrupt", params: [
                "threadId": threadID, "turnId": activeTurnID
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
        case "set_fast_mode":
            let enabled = payload["enabled"]?.boolValue == true
            guard !enabled || models.isEmpty || selectedModelSupportsFastMode else { return nil }
            return request("thread/settings/update", params: [
                "threadId": threadID,
                "serviceTier": enabled ? "priority" : NSNull()
            ], as: .fastMode(appID: id, enabled: enabled))
        default:
            return nil
        }
    }

    private func makeTurnStart(
        _ entry: QueuedCommand,
        threadID: String,
        responseExpected: Bool,
        retryCount: Int
    ) -> Data? {
        let token = turnStartCounter &+ 1
        var params: [String: Any] = [
            "threadId": threadID,
            "input": Self.userInput(from: entry.payload),
            "clientUserMessageId": entry.id
        ]
        if let modelID { params["model"] = modelID }
        if let effort { params["effort"] = effort }
        guard let line = request("turn/start", params: params, as: .turn(
            entry: entry,
            startsTurn: true,
            startToken: token,
            responseExpected: responseExpected,
            retryCount: retryCount
        )) else { return nil }
        turnStartCounter = token
        pendingTurnStartToken = token
        return line
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
        encodeUncorrelatedWithDisposition(value).lines
    }

    public func encodeUncorrelatedWithDisposition(
        _ value: PiJSONValue
    ) -> AdapterUncorrelatedOutbound {
        guard value["type"]?.stringValue == "extension_ui_response",
              let dialogID = value["id"]?.stringValue,
              let approval = takeApproval(dialogID) else { return .unmatched }
        let cancelled = value["cancelled"]?.boolValue == true
        let confirmed = value["confirmed"]?.boolValue
        let choice = value["value"]?.stringValue
        let accepted = !cancelled && (confirmed ?? (choice.map { !Self.decliningChoices.contains($0) } ?? false))
        let forSession = choice == Self.approveForSessionChoice

        if case let .userInput(groupID, questionID) = approval.kind {
            guard var group = userInputGroups[groupID] else { return .unmatched }
            group.answers[questionID] = accepted ? [choice ?? ""] : []
            guard group.answers.count == group.questionIDs.count else {
                userInputGroups[groupID] = group
                return .acceptedWithoutWrite
            }
            userInputGroups.removeValue(forKey: groupID)
            let answers = Dictionary(uniqueKeysWithValues: group.questionIDs.map { id in
                (id, ["answers": group.answers[id] ?? []] as [String: Any])
            })
            guard let line = AdapterEncoding.line([
                "id": Self.rpcIdentifier(group.requestID),
                "result": ["answers": answers]
            ]) else { return .unmatched }
            return .write([line])
        }

        let result = Self.approvalResult(
            for: approval.kind, accepted: accepted, cancelled: cancelled,
            forSession: forSession, choice: choice
        )
        guard let line = AdapterEncoding.line([
            "id": Self.rpcIdentifier(approval.requestID), "result": result
        ]) else { return .unmatched }
        return .write([line])
    }

    private static func approvalResult(
        for kind: ApprovalKind, accepted: Bool, cancelled: Bool,
        forSession: Bool, choice: String?
    ) -> [String: Any] {
        let result: [String: Any]
        switch kind {
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
        case let .userInput(_, questionID):
            result = ["answers": [questionID: ["answers": accepted ? [choice ?? ""] : []]]]
        }
        return result
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
        let inbound: [AdapterInbound]
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex rejected the request."
            inbound = handle(failure: entry, message: message)
        } else {
            inbound = handle(result: object["result"] as? [String: Any] ?? [:], for: entry)
        }
        if let activeTurnID {
            flushPendingSteers(expectedTurnID: activeTurnID)
            flushPendingAborts(expectedTurnID: activeTurnID)
        }
        return inbound
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
        case let .turn(entry, startsTurn, startToken, responseExpected, _):
            let resultTurn = result["turn"] as? [String: Any]
            if startsTurn, resultTurn?["id"] is String, pendingTurnStartToken == startToken {
                pendingTurnStartToken = nil
            }
            var inbound: [AdapterInbound] = []
            if responseExpected {
                inbound.append(.response(
                    id: entry.id,
                    value: AdapterEncoding.response(id: entry.id, data: .object([:]))
                ))
            }
            // The response and `turn/started` notification may arrive in either order. Route both
            // through the same idempotent transition so an early response starts the pulse, while
            // a late response can never resurrect a turn that already completed.
            if let id = resultTurn?["id"] as? String {
                inbound.append(contentsOf: beginTurn(id, confirmed: false))
            }
            return inbound
        case let .compact(appID):
            isCompacting = true
            return [
                .response(id: appID, value: AdapterEncoding.response(id: appID, data: .object([:]))),
                .event(AdapterEncoding.event("compaction_start"))
            ]
        case let .fastMode(appID, enabled):
            serviceTier = enabled ? "priority" : nil
            return [.response(id: appID, value: AdapterEncoding.response(
                id: appID,
                data: fastModeValue()
            ))]
        case let .acknowledge(appID):
            return [.response(id: appID, value: AdapterEncoding.response(id: appID, data: .object([:])))]
        }
    }

    private func handle(failure entry: Pending, message: String) -> [AdapterInbound] {
        switch entry {
        case .initialize:
            return failHandshake(message)
        case let .openThread(resume):
            // A rollout whose thread Codex cannot load must still give the user a usable session.
            guard resume, !didRetryThreadStart else { return failHandshake(message) }
            didRetryThreadStart = true
            resumeThreadID = nil
            openThread()
            return []
        case let .models(appID):
            guard let appID else { return [] }
            return [.response(id: appID, value: rejection(id: appID, message: message))]
        case let .turn(entry, startsTurn, startToken, responseExpected, retryCount):
            if startsTurn {
                let ownsPendingStart = pendingTurnStartToken == startToken
                if !ownsPendingStart {
                    // A confirmed start may complete before its JSON-RPC reply. Its late failure
                    // cannot reject a command the agent already ran or disturb the next pending start.
                    guard responseExpected else { return [] }
                    return [.response(
                        id: entry.id,
                        value: AdapterEncoding.response(id: entry.id, data: .object([:]))
                    )]
                }
                if !responseExpected, retryCount == 0, let threadID {
                    enqueue(makeTurnStart(
                        entry, threadID: threadID,
                        responseExpected: false, retryCount: retryCount + 1
                    ))
                    return []
                }
                pendingTurnStartToken = nil
                if !responseExpected {
                    return completeTurn([
                        "id": "failed-follow-up-\(startToken.map(String.init) ?? entry.id)",
                        "status": "failed",
                        "error": ["message": "The queued follow-up could not start. \(message)"],
                        "items": []
                    ])
                }
                var inbound = rejectPendingSteers(message: message)
                inbound.append(contentsOf: resolvePendingAborts())
                inbound.append(.response(id: entry.id, value: rejection(id: entry.id, message: message)))
                inbound.append(contentsOf: startNextFollowUp())
                return inbound
            }

            if Self.isRecoverableTurnRace(message) {
                if retryCount == 0, enqueueSteer(entry, retryCount: 1) {
                    return []
                }
                if turnID != nil || turnStartPending {
                    followUps.insert(entry, at: 0)
                    return [
                        .response(
                            id: entry.id,
                            value: AdapterEncoding.response(id: entry.id, data: .object([:]))
                        ),
                        queueUpdate()
                    ]
                }
                if let threadID {
                    enqueue(makeTurnStart(
                        entry, threadID: threadID,
                        responseExpected: true, retryCount: 0
                    ))
                    return []
                }
            }
            return [.response(id: entry.id, value: rejection(id: entry.id, message: message))]
        case let .commands(appID), let .compact(appID), let .fastMode(appID, _),
             let .acknowledge(appID):
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
        guard let id = thread["id"] as? String else {
            return failHandshake("The agent did not return a thread identifier.")
        }
        threadID = id
        sessionFile = thread["path"] as? String ?? sessionFile
        sessionName = thread["name"] as? String ?? sessionName
        modelID = result["model"] as? String ?? modelID
        effort = result["reasoningEffort"] as? String ?? effort
        serviceTier = result["serviceTier"] as? String
        return flushQueuedCommands()
    }

    private func failHandshake(_ message: String) -> [AdapterInbound] {
        let stranded = queued
        queued.removeAll()
        pendingTurnStartToken = nil
        return stranded.map { entry in
            .response(id: entry.id, value: rejection(id: entry.id, message: message))
        }
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
            case let .immediateWithEvents(value, events):
                inbound.append(.response(id: entry.id, value: AdapterEncoding.response(id: entry.id, data: value)))
                inbound.append(contentsOf: events.map(AdapterInbound.event))
            case let .unsupported(what):
                inbound.append(.response(
                    id: entry.id,
                    value: AdapterEncoding.failure(id: entry.id, message: "\(agent.displayName) does not support \(what).")
                ))
            case .deferred:
                // A second prompt can now be waiting for the first turn's confirmed start. Its
                // correlation remains reserved until the queued steer reaches the wire.
                break
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
            return beginTurn(id, confirmed: true)
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
        case "thread/settings/updated":
            let settings = params["threadSettings"] as? [String: Any] ?? [:]
            serviceTier = settings["serviceTier"] as? String
            return [.event(AdapterEncoding.event("fast_mode_changed", [
                "enabled": .bool(fastModeEnabled),
                "available": .bool(selectedModelSupportsFastMode)
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

    private func beginTurn(_ id: String, confirmed: Bool) -> [AdapterInbound] {
        guard !settledTurns.contains(id) else { return [] }
        if let turnID, turnID != id { return [] }

        var inbound: [AdapterInbound] = []
        if turnID == nil {
            turnID = id
            isRetrying = false
            retryAttempt = 0
            inbound = [
                .event(AdapterEncoding.event("agent_start")),
                .event(AdapterEncoding.event("turn_start"))
            ]
        }
        if confirmed {
            activeTurnID = id
            pendingTurnStartToken = nil
            flushPendingSteers(expectedTurnID: id)
            flushPendingAborts(expectedTurnID: id)
        }
        return inbound
    }

    /// The one place a turn ends. `agent_settled` unblocks the composer, so it fires exactly once
    /// per turn id no matter how many terminal notifications Codex sends for it.
    private func completeTurn(_ turn: [String: Any]) -> [AdapterInbound] {
        let status = turn["status"] as? String ?? "completed"
        guard status != "inProgress" else { return [] }
        let id = turn["id"] as? String ?? turnID ?? ""
        guard !id.isEmpty, !settledTurns.contains(id) else { return [] }
        if let turnID, turnID != id {
            rememberSettled(id)
            return []
        }
        rememberSettled(id)
        turnID = nil
        activeTurnID = nil
        pendingTurnStartToken = nil

        var inbound = closeOpenItems()
        let restartedPendingSteer = restartFirstPendingSteer()
        if !restartedPendingSteer {
            inbound.append(contentsOf: rejectPendingSteers(
                message: "The turn ended before steering was accepted."
            ))
        }
        inbound.append(contentsOf: resolvePendingAborts())
        if status == "failed", let message = (turn["error"] as? [String: Any])?["message"] as? String {
            inbound.append(.event(AdapterEncoding.event("message_end", [
                "message": .object([
                    "id": .string("codex-turn-error-\(id)"),
                    "role": .string("assistant"),
                    "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
                    "provider": .string(Self.provider),
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
        if !restartedPendingSteer {
            inbound.append(contentsOf: startNextFollowUp())
        }
        return inbound
    }

    private func rememberSettled(_ id: String) {
        guard settledTurns.insert(id).inserted else { return }
        settledTurnOrder.append(id)
        if settledTurnOrder.count > Limit.settledTurns {
            let overflow = settledTurnOrder.count - Limit.settledTurns
            let removed = settledTurnOrder.prefix(overflow)
            settledTurns.subtract(removed)
            settledTurnOrder.removeFirst(overflow)
        }
    }

    private func flushPendingSteers(expectedTurnID: String) {
        guard let threadID, !pendingSteers.isEmpty else { return }
        var remaining: [QueuedCommand] = []
        for entry in pendingSteers {
            let params: [String: Any] = [
                "threadId": threadID,
                "expectedTurnId": expectedTurnID,
                "input": Self.userInput(from: entry.payload),
                "clientUserMessageId": entry.id
            ]
            guard let line = request("turn/steer", params: params, as: .turn(
                entry: entry, startsTurn: false, startToken: nil,
                responseExpected: true, retryCount: 0
            )) else {
                remaining.append(entry)
                continue
            }
            enqueue(line)
        }
        pendingSteers = remaining
    }

    @discardableResult
    private func enqueueSteer(_ entry: QueuedCommand, retryCount: Int) -> Bool {
        guard let threadID, let activeTurnID else { return false }
        guard let line = request("turn/steer", params: [
            "threadId": threadID,
            "expectedTurnId": activeTurnID,
            "input": Self.userInput(from: entry.payload),
            "clientUserMessageId": entry.id
        ], as: .turn(
            entry: entry, startsTurn: false, startToken: nil,
            responseExpected: true, retryCount: retryCount
        )) else { return false }
        enqueue(line)
        return true
    }

    private static func isRecoverableTurnRace(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("no active turn")
            || (message.contains("expected") && message.contains("turn"))
            || message.contains("turn is not active")
    }

    private func flushPendingAborts(expectedTurnID: String) {
        guard let threadID, !pendingAborts.isEmpty else { return }
        var remaining: [QueuedCommand] = []
        for entry in pendingAborts {
            guard let line = request("turn/interrupt", params: [
                "threadId": threadID, "turnId": expectedTurnID
            ], as: .acknowledge(appID: entry.id)) else {
                remaining.append(entry)
                continue
            }
            enqueue(line)
        }
        pendingAborts = remaining
    }

    private func resolvePendingAborts() -> [AdapterInbound] {
        let commands = pendingAborts
        pendingAborts.removeAll()
        return commands.map { entry in
            .response(
                id: entry.id,
                value: AdapterEncoding.response(id: entry.id, data: .object([:]))
            )
        }
    }

    private func rejectPendingSteers(message: String) -> [AdapterInbound] {
        let commands = pendingSteers
        pendingSteers.removeAll()
        return commands.map { entry in
            .response(id: entry.id, value: rejection(id: entry.id, message: message))
        }
    }

    /// A turn can settle after its start response but before its activation notification. Start
    /// the first held steer as the next turn and keep later steers behind its confirmation, so
    /// FIFO and callback acceptance still match the wire.
    @discardableResult
    private func restartFirstPendingSteer() -> Bool {
        guard let threadID, !pendingSteers.isEmpty else { return false }
        let entry = pendingSteers[0]
        guard let line = makeTurnStart(
            entry, threadID: threadID, responseExpected: true, retryCount: 0
        ) else { return false }
        pendingSteers.removeFirst()
        enqueue(line)
        return true
    }

    private func startNextFollowUp() -> [AdapterInbound] {
        guard let threadID, !followUps.isEmpty else { return [] }
        let entry = followUps[0]
        guard let line = makeTurnStart(
            entry, threadID: threadID, responseExpected: false, retryCount: 0
        ) else { return [] }
        followUps.removeFirst()
        enqueue(line)
        return [queueUpdate()]
    }

    private func queueUpdate() -> AdapterInbound {
        .event(queueUpdateValue())
    }

    private func queueUpdateValue() -> PiJSONValue {
        AdapterEncoding.event("queue_update", [
            "steering": .array(pendingSteers.map { .string($0.payload["message"]?.stringValue ?? "") }),
            "followUp": .array(followUps.map { .string($0.payload["message"]?.stringValue ?? "") })
        ])
    }

    private func startItem(_ item: [String: Any]) -> [AdapterInbound] {
        guard let itemID = item["id"] as? String, let type = item["type"] as? String else { return [] }
        var inbound = resumedAfterRetry()
        switch type {
        case "agentMessage", "reasoning":
            openStream(itemID, thinking: type == "reasoning", phase: item["phase"] as? String)
            inbound.append(.event(AdapterEncoding.event("message_start", [
                "message": .object([
                    "id": .string(itemID), "role": .string("assistant"), "content": .array([])
                ])
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
            let phase = item["phase"] as? String ?? streams[itemID]?.phase
            closeStream(itemID)
            guard !text.isEmpty else { return [] }
            return [.event(AdapterEncoding.event("message_end", [
                "message": assistantMessage(
                    id: itemID, text: text, thinking: false,
                    stopReason: phase == "final_answer" ? "stop" : "toolUse"
                )
            ]))]
        case "reasoning":
            let parts = ((item["summary"] as? [String]) ?? []) + ((item["content"] as? [String]) ?? [])
            let text = parts.isEmpty ? (streams[itemID]?.text ?? "") : parts.joined(separator: "\n\n")
            closeStream(itemID)
            guard !text.isEmpty else { return [] }
            return [.event(AdapterEncoding.event("message_end", [
                "message": assistantMessage(id: itemID, text: text, thinking: true, stopReason: "toolUse")
            ]))]
        case "userMessage":
            let text = Self.userMessageText(item)
            guard !text.isEmpty else { return [] }
            return [.event(AdapterEncoding.event("message_end", [
                "message": .object([
                    "role": .string("user"),
                    "id": .string(itemID),
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
        if streams[itemID] == nil { openStream(itemID, thinking: thinking, phase: nil) }
        guard var stream = streams[itemID] else { return [] }
        // Bounded: a runaway stream keeps its head, which is what the reader is looking at.
        if stream.text.count < Limit.streamCharacters {
            stream.text += delta
            if stream.text.count > Limit.streamCharacters {
                stream.text = String(stream.text.prefix(Limit.streamCharacters))
            }
        }
        streams[itemID] = stream
        let isWork = stream.isThinking || (stream.phase != nil && stream.phase != "final_answer")
        return [.event(AdapterEncoding.event("message_update", [
            "message": assistantMessage(
                id: itemID,
                text: stream.text,
                thinking: stream.isThinking,
                stopReason: isWork ? "toolUse" : nil
            )
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
            return dialog(
                id: id,
                kind: method == "execCommandApproval" ? .reviewDecision : .commandExecution,
                title: "Codex wants to run a command",
                message: [command, cwd.map { "in \($0)" }, params["reason"] as? String]
                    .compactMap { $0 }.joined(separator: "\n"),
                options: Self.approvalChoices
            ).map { [$0] } ?? []
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let files = ((params["fileChanges"] as? [String: Any])?.keys).map { Array($0) } ?? []
            return dialog(
                id: id,
                kind: method == "applyPatchApproval" ? .reviewDecision : .fileChange,
                title: "Codex wants to edit files",
                message: [params["reason"] as? String, files.prefix(20).joined(separator: "\n")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                options: Self.approvalChoices
            ).map { [$0] } ?? []
        case "item/permissions/requestApproval":
            let requested = PiJSONValue(any: params["permissions"] ?? NSNull())
            return dialog(
                id: id,
                kind: .permissions(requested: requested),
                title: "Codex wants more access",
                message: [params["reason"] as? String, params["cwd"] as? String]
                    .compactMap { $0 }.joined(separator: "\n"),
                options: Self.approvalChoices
            ).map { [$0] } ?? []
        case "mcpServer/elicitation/request":
            return dialog(
                id: id,
                kind: .elicitation,
                title: "Codex tool request",
                message: params["message"] as? String ?? "",
                options: [Self.approveChoice, Self.declineChoice]
            ).map { [$0] } ?? []
        case "item/tool/requestUserInput":
            let questions = params["questions"] as? [[String: Any]] ?? []
            return userInputDialogs(requestID: id, questions: questions)
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

    private func userInputDialogs(
        requestID: PiJSONValue,
        questions: [[String: Any]]
    ) -> [AdapterInbound] {
        var seen: Set<String> = []
        let valid = questions.prefix(Limit.userInputQuestions).compactMap { question -> (String, [String: Any])? in
            guard let id = question["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, question)
        }
        guard !valid.isEmpty else {
            enqueue(AdapterEncoding.line([
                "id": Self.rpcIdentifier(requestID),
                "result": ["answers": [String: Any]()]
            ]))
            return []
        }
        guard approvals.count <= Limit.pendingApprovals - valid.count else {
            let answers = Dictionary(uniqueKeysWithValues: valid.map { id, _ in
                (id, ["answers": [String]()] as [String: Any])
            })
            enqueue(AdapterEncoding.line([
                "id": Self.rpcIdentifier(requestID),
                "result": ["answers": answers]
            ]))
            return []
        }

        userInputGroupCounter &+= 1
        let groupID = "codex-user-input-\(userInputGroupCounter)"
        userInputGroups[groupID] = PendingUserInputGroup(
            requestID: requestID,
            questionIDs: valid.map(\.0)
        )

        return valid.compactMap { questionID, question in
            let rawOptions = question["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { $0["label"] as? String }
            let descriptions = rawOptions.compactMap { option -> String? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String,
                      !description.isEmpty else { return nil }
                return "\(label): \(description)"
            }
            let prompt = question["question"] as? String ?? ""
            let message = ([prompt] + descriptions).filter { !$0.isEmpty }.joined(separator: "\n\n")
            return dialog(
                id: requestID,
                kind: .userInput(groupID: groupID, questionID: questionID),
                title: question["header"] as? String ?? "Agent question",
                message: message,
                options: options
            )
        }
    }

    private func dialog(
        id: PiJSONValue, kind: ApprovalKind, title: String, message: String, options: [String]
    ) -> AdapterInbound? {
        let approval = PendingApproval(requestID: id, kind: kind)
        guard approvals.count < Limit.pendingApprovals else {
            let result = Self.approvalResult(
                for: kind, accepted: false, cancelled: false,
                forSession: false, choice: Self.declineChoice
            )
            enqueue(AdapterEncoding.line([
                "id": Self.rpcIdentifier(id), "result": result
            ]))
            return nil
        }
        approvalCounter += 1
        let dialogID = "codex-approval-\(approvalCounter)"
        remember(approval: approval, as: dialogID)
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
            "isStreaming": .bool(turnID != nil || turnStartPending),
            "isCompacting": .bool(isCompacting),
            "steeringMode": .string(steeringMode),
            "followUpMode": .string(followUpMode),
            "steeringQueue": .array(pendingSteers.map { .string($0.payload["message"]?.stringValue ?? "") }),
            "followUpQueue": .array(followUps.map { .string($0.payload["message"]?.stringValue ?? "") }),
            "thinkingLevel": .string(Self.thinkingLevel(forEffort: effort)),
            "model": selectedModelValue(),
            "fastModeEnabled": .bool(fastModeEnabled),
            "fastModeAvailable": .bool(selectedModelSupportsFastMode)
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
        .object([
            "models": .array(models.compactMap { model in
            guard let id = model["id"]?.stringValue else { return nil }
            return .object([
                "provider": .string(Self.provider),
                "id": .string(id),
                "name": .string(model["displayName"]?.stringValue ?? id),
                "reasoning": .bool(!(model["supportedReasoningEfforts"]?.arrayValue ?? []).isEmpty),
                "supportsFastMode": .bool(modelSupportsFastMode(model))
            ])
            }),
            "fastModeAvailable": .bool(selectedModelSupportsFastMode),
            "fastModeEnabled": .bool(fastModeEnabled)
        ])
    }

    private func selectedModelValue() -> PiJSONValue {
        guard let modelID else { return .object([:]) }
        return .object([
            "id": .string(modelID),
            "name": .string(models.first { $0["id"]?.stringValue == modelID }?["displayName"]?.stringValue ?? modelID),
            "provider": .string(Self.provider)
        ])
    }

    private var selectedModelSupportsFastMode: Bool {
        guard let selected = models.first(where: { $0["id"]?.stringValue == modelID }) ?? models.first else {
            return false
        }
        return modelSupportsFastMode(selected)
    }

    private var fastModeEnabled: Bool {
        serviceTier == "priority"
    }

    private func fastModeValue() -> PiJSONValue {
        .object([
            "enabled": .bool(fastModeEnabled),
            "available": .bool(selectedModelSupportsFastMode)
        ])
    }

    private func modelSupportsFastMode(_ model: PiJSONValue) -> Bool {
        (model["serviceTiers"]?.arrayValue ?? []).contains { $0["id"]?.stringValue == "priority" }
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

    private func assistantMessage(id: String, text: String, thinking: Bool, stopReason: String?) -> PiJSONValue {
        var message: [String: PiJSONValue] = [
            "id": .string(id),
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
            return PiJSONValue(any: item["arguments"] ?? NSNull()).boundedProjection()
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
        guard pending.count < Limit.inFlightRequests else { return nil }
        requestCounter += 1
        let rpcID = requestCounter
        guard let line = AdapterEncoding.line([
            "id": rpcID, "method": method, "params": params
        ]) else { return nil }
        pending[rpcID] = entry
        pendingOrder.append(rpcID)
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

    private func openStream(_ itemID: String, thinking: Bool, phase: String?) {
        if streams[itemID] == nil { streamOrder.append(itemID) }
        streams[itemID] = Stream(
            isThinking: thinking,
            phase: phase ?? streams[itemID]?.phase,
            text: streams[itemID]?.text ?? ""
        )
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
                    id: itemID, text: stream.text, thinking: stream.isThinking,
                    // An item that never completed is work interrupted at the turn boundary, not
                    // a trustworthy final answer.
                    stopReason: "toolUse"
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
    }

    private func takeApproval(_ dialogID: String) -> PendingApproval? {
        approvalOrder.removeAll { $0 == dialogID }
        return approvals.removeValue(forKey: dialogID)
    }
}
