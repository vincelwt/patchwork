import Foundation

/// Drives Claude Code's own streaming-JSON protocol — `claude -p --input-format stream-json
/// --output-format stream-json --verbose` — and translates it into the app's Pi-shaped
/// command/event vocabulary.
///
/// Claude ships this protocol in the binary, so there is no bridge process and no third-party
/// adapter in the path. Three of its properties shape everything below:
///
/// - Only `control_request` carries a correlation id, and Claude echoes ours back verbatim, so
///   the app's own request id *is* the wire request id for abort/model/permission-mode.
/// - A user turn has no ack of its own, so `--replay-user-messages` is the acknowledgement: the
///   echoed user line resolves the oldest pending prompt in FIFO order.
/// - Reasoning effort is a launch flag (`--effort`); no control request changes it mid-session.
///
/// Every method runs serially on the transport's IO queue, so the mutable state here is
/// unsynchronized on purpose.
public final class ClaudeProtocolAdapter: AgentProtocolAdapter, AdapterWriteback {
    public init() {}

    public let agent: AgentKind = .claude

    /// Everything retained from the wire is bounded; a runaway stream must not become a runaway
    /// heap. These are the only limits in this file, deliberately in one place.
    enum Limit {
        static let blockText = 160_000
        static let blocks = 64
        static let permissions = 16
        static let promptAcks = 16
        static let controlRequests = 32
        static let queue = 20
        static let commands = 200
        static let summary = 2_000
    }

    /// Claude's `--effort` ladder, in the app's thinking-level vocabulary.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Claude has no protocol call that enumerates models in every build, so the picker offers
    /// the documented `--model` aliases plus whatever the running session reports.
    public static let modelAliases: [(id: String, name: String)] = [
        ("default", "Default"),
        ("fable", "Fable"),
        ("opus", "Opus"),
        ("sonnet", "Sonnet"),
        ("haiku", "Haiku")
    ]

    // MARK: - Launch-scoped preferences (survive a relaunch of the same adapter)

    private var modelID: String?
    private var modelName: String?
    private var effort: String?
    private var permissionMode: String?

    // MARK: - Session state (cleared by `reset`)

    private var cwd = FileManager.default.homeDirectoryForCurrentUser
    private var sessionID: String?
    private var sessionPath: String?
    private var slashCommands: [String] = []
    private var isTurnActive = false
    private var isCompacting = false
    private var queuedPrompts: [String] = []
    private var stats = Stats()
    private var stream = StreamAccumulator()
    private var startedMessageID: String?

    /// Correlation ids waiting for their replayed user line, oldest first.
    private var promptAcks: [String] = []
    /// Wire request id -> the app command that produced it, oldest first.
    private var controlRequests: [(id: String, command: String, value: String?)] = []
    /// Permission request id -> the tool input to echo back on allow, oldest first.
    private var permissions: [(id: String, input: [String: Any])] = []
    /// Lines produced while decoding (permission overflow denials).
    private var writeback: [Data] = []

    private struct Stats {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var cost = 0.0
    }

    // MARK: - Launch

    public func launchArguments(sessionPath: URL?, cwd: URL) -> [String] {
        self.cwd = cwd
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages"
        ]

        // A Claude transcript is `<root>/<project slug>/<sessionId>.jsonl`, so resuming is a
        // filename read. With no transcript the id is generated here instead of waiting for
        // `system/init`, which is what lets the app name the file before the first line lands.
        if let sessionPath, sessionPath.pathExtension == "jsonl" {
            let id = sessionPath.deletingPathExtension().lastPathComponent
            if !id.isEmpty {
                sessionID = id
                self.sessionPath = sessionPath.standardizedFileURL.path
                arguments += ["--resume", id]
            }
        }
        if sessionID == nil {
            let id = UUID().uuidString.lowercased()
            sessionID = id
            self.sessionPath = Self.transcriptPath(sessionID: id, cwd: cwd)
            arguments += ["--session-id", id]
        }

        if let modelID, modelID != "default" { arguments += ["--model", modelID] }
        if let effort, Self.effortLevels.contains(effort) { arguments += ["--effort", effort] }
        if let permissionMode { arguments += ["--permission-mode", permissionMode] }
        return arguments
    }

    /// `~/.claude/projects/<cwd with "/" and "." replaced by "-">/<sessionId>.jsonl`.
    public static func transcriptPath(sessionID: String, cwd: URL) -> String {
        let slug = cwd.standardizedFileURL.path
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return AgentCatalog.sessionRoot(for: .claude)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
            .standardizedFileURL.path
    }

    public func reset() {
        sessionID = nil
        sessionPath = nil
        slashCommands = []
        isTurnActive = false
        isCompacting = false
        queuedPrompts = []
        stats = Stats()
        stream = StreamAccumulator()
        startedMessageID = nil
        promptAcks = []
        controlRequests = []
        permissions = []
        writeback = []
    }

    public func drainPendingWrites() -> [Data] {
        defer { writeback = [] }
        return writeback
    }

    // MARK: - Outbound commands

    public func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        switch command {
        // Claude queues a user message sent mid-turn itself, so steering and follow-up are the
        // same wire message as a prompt; only the queue readout below differs.
        case "prompt", "steer", "follow_up":
            return userTurn(text: payload["message"]?.stringValue ?? "", images: payload["images"], id: id)
        case "compact":
            isCompacting = true
            return userTurn(text: "/compact", images: nil, id: id)
        case "abort", "abort_retry":
            return controlRequest(id: id, command: command, request: ["subtype": "interrupt"])
        case "set_model":
            let model = payload["modelId"]?.stringValue ?? payload["model"]?.stringValue ?? "default"
            return controlRequest(
                id: id, command: command, value: model,
                request: ["subtype": "set_model", "model": model == "default" ? NSNull() : model]
            )
        case "set_mode":
            guard let mode = payload["mode"]?.stringValue else { return .unsupported("that permission mode") }
            return controlRequest(
                id: id, command: command, value: mode,
                request: ["subtype": "set_permission_mode", "mode": mode]
            )
        case "set_thinking_level":
            // `--effort` is launch-only: there is no control request for it, and pretending the
            // running session changed would be a lie. The level is still remembered so the next
            // launch of this runtime carries it.
            if let level = payload["level"]?.stringValue, Self.effortLevels.contains(level) { effort = level }
            return .unsupported("changing effort mid-session")
        case "get_state":
            return .immediate(PiJSONValue(any: stateSnapshot()))
        case "get_available_models":
            return .immediate(PiJSONValue(any: ["models": models()]))
        case "get_available_thinking_levels":
            return .immediate(PiJSONValue(any: ["levels": Self.effortLevels]))
        case "get_commands":
            return .immediate(PiJSONValue(any: ["commands": commands()]))
        case "get_session_stats":
            return .immediate(PiJSONValue(any: [
                "tokens": [
                    "input": stats.input, "output": stats.output,
                    "cacheRead": stats.cacheRead, "cacheWrite": stats.cacheWrite
                ],
                "cost": stats.cost
            ]))
        case "set_session_name":
            return .unsupported("renaming a conversation")
        case "export_html":
            return .unsupported("HTML export")
        case "get_fork_messages", "get_entries":
            return .unsupported("editing earlier messages")
        case "cycle_model", "cycle_thinking_level":
            return .unsupported("cycling through options")
        default:
            return .unsupported("the \(command) command")
        }
    }

    public func encodeUncorrelated(_ value: PiJSONValue) -> [Data] {
        // The only uncorrelated message the app sends is a dialog answer, and the only dialog
        // this adapter raises is a tool-permission request.
        guard value["type"]?.stringValue == "extension_ui_response",
              let requestID = value["id"]?.stringValue,
              let index = permissions.firstIndex(where: { $0.id == requestID }) else { return [] }
        let input = permissions.remove(at: index).input
        let allowed = value["confirmed"]?.boolValue == true && value["cancelled"]?.boolValue != true
        return [permissionReply(requestID: requestID, allow: allowed, input: input)].compactMap { $0 }
    }

    private func userTurn(text: String, images: PiJSONValue?, id: String) -> AdapterOutbound {
        var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        for image in images?.arrayValue ?? [] {
            guard let data = image["data"]?.stringValue, !data.isEmpty else { continue }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image["mimeType"]?.stringValue ?? "image/png",
                    "data": data
                ]
            ])
        }
        guard !content.isEmpty, let line = AdapterEncoding.line([
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
            "session_id": sessionID ?? ""
        ]) else { return .write([]) }

        // Claude acknowledges nothing but the replay, so the caller is resolved when its own
        // message comes back. A stale head is dropped rather than growing without bound; the
        // transport still completes it on timeout.
        promptAcks.append(id)
        if promptAcks.count > Limit.promptAcks { promptAcks.removeFirst() }
        if isTurnActive, !text.isEmpty {
            queuedPrompts.append(bounded(text, max: 1_000))
            if queuedPrompts.count > Limit.queue { queuedPrompts.removeFirst() }
        }
        return .write([line])
    }

    private func controlRequest(
        id: String,
        command: String,
        value: String? = nil,
        request: [String: Any]
    ) -> AdapterOutbound {
        guard let line = AdapterEncoding.line([
            "type": "control_request", "request_id": id, "request": request
        ]) else { return .write([]) }
        controlRequests.append((id: id, command: command, value: value))
        if controlRequests.count > Limit.controlRequests { controlRequests.removeFirst() }
        return .write([line])
    }

    private func permissionReply(requestID: String, allow: Bool, input: [String: Any]) -> Data? {
        let payload: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "Denied in Pi Desktop."]
        return AdapterEncoding.line([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": payload]
        ])
    }

    // MARK: - Immediate answers

    private func stateSnapshot() -> [String: Any] {
        var state: [String: Any] = [
            "isStreaming": isTurnActive,
            "isCompacting": isCompacting,
            "steeringMode": "all",
            "followUpMode": "all",
            "steeringQueue": [],
            "followUpQueue": queuedPrompts,
            "model": [
                "id": modelID ?? "default",
                "name": modelName ?? modelID ?? "Default",
                "provider": "anthropic"
            ]
        ]
        if let effort { state["thinkingLevel"] = effort }
        if let sessionID { state["sessionId"] = sessionID }
        if let sessionPath { state["sessionFile"] = sessionPath }
        return state
    }

    private func models() -> [[String: Any]] {
        var models = Self.modelAliases.map {
            ["provider": "anthropic", "id": $0.id, "name": $0.name, "reasoning": true] as [String: Any]
        }
        // Whatever the session actually reported wins a row of its own, so the picker never
        // hides the model the transcript was written with.
        if let modelID, !models.contains(where: { $0["id"] as? String == modelID }) {
            models.append([
                "provider": "anthropic", "id": modelID, "name": modelName ?? modelID, "reasoning": true
            ])
        }
        return models
    }

    private func commands() -> [[String: Any]] {
        slashCommands.prefix(Limit.commands).map { ["name": $0, "source": "claude"] }
    }

    // MARK: - Inbound

    public func decode(line: Data) -> [AdapterInbound] {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = record["type"] as? String else { return [] }
        switch type {
        case "system": return system(record)
        case "assistant": return assistant(record)
        case "user": return user(record)
        case "stream_event": return streamEvent(record)
        case "result": return result(record)
        case "control_request": return permissionRequest(record)
        case "control_response": return controlResponse(record)
        case "control_cancel_request":
            if let id = record["request_id"] as? String { permissions.removeAll { $0.id == id } }
            return []
        default:
            // keep_alive, hook events, prompt suggestions, and anything a newer Claude adds.
            return []
        }
    }

    private func system(_ record: [String: Any]) -> [AdapterInbound] {
        switch record["subtype"] as? String {
        case "init":
            if let id = record["session_id"] as? String, !id.isEmpty {
                // A forked or newly created session renames the transcript, so the path follows.
                if id != sessionID { sessionPath = Self.transcriptPath(sessionID: id, cwd: cwd) }
                sessionID = id
            }
            if let model = record["model"] as? String, !model.isEmpty {
                modelID = model
                modelName = model
            }
            if let mode = record["permissionMode"] as? String { permissionMode = mode }
            if let commands = record["slash_commands"] as? [String] {
                slashCommands = Array(commands.prefix(Limit.commands))
            }
            return []
        case "compact_boundary":
            // The boundary is reported once compaction has already happened; the pair keeps the
            // app's compaction state machine balanced instead of leaving it stuck.
            isCompacting = false
            return [event("compaction_start"), event("compaction_end")]
        default:
            // status, task_started, task_progress, task_notification, notification,
            // permission_denied: no app-side equivalent, so nothing is emitted.
            return []
        }
    }

    private func assistant(_ record: [String: Any]) -> [AdapterInbound] {
        // Subagent output rides the same stream under a parent tool id. The transcript projection
        // drops those sidechains, so the live view drops them too and the two agree.
        guard record["parent_tool_use_id"] is NSNull || record["parent_tool_use_id"] == nil,
              let message = record["message"] as? [String: Any] else { return [] }
        var out: [AdapterInbound] = []
        startTurn(&out)

        let id = message["id"] as? String
        if startedMessageID != id {
            out.append(event("message_start", ["message": ["role": "assistant"]]))
        }
        startedMessageID = nil
        stream = StreamAccumulator()

        let blocks = Self.contentBlocks(message["content"])
        var projected: [String: Any] = [
            "role": "assistant",
            "content": blocks,
            "provider": "anthropic",
            "stopReason": Self.stopReason(message["stop_reason"] as? String, blocks: blocks)
        ]
        if let model = message["model"] as? String { projected["model"] = model }
        if let usage = Self.usage(message["usage"] as? [String: Any]) { projected["usage"] = usage }
        out.append(event("message_end", ["message": projected]))

        for block in blocks where block["type"] as? String == "toolCall" {
            out.append(event("tool_execution_start", [
                "toolCallId": block["id"] as? String ?? "",
                "toolName": block["name"] as? String ?? "tool",
                "args": block["arguments"] ?? [String: Any]()
            ]))
        }
        return out
    }

    private func user(_ record: [String: Any]) -> [AdapterInbound] {
        // Harness-injected context is not the user talking and must not consume a prompt ack.
        guard record["isMeta"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return [] }
        var out: [AdapterInbound] = []
        startTurn(&out)

        let parts = message["content"] as? [[String: Any]] ?? []
        let results = parts.filter { ($0["type"] as? String) == "tool_result" }
        guard !results.isEmpty else {
            // A replayed user message: the only acknowledgement this protocol offers.
            if !promptAcks.isEmpty {
                let id = promptAcks.removeFirst()
                out.append(.response(id: id, value: AdapterEncoding.response(id: id, data: .object([:]))))
            }
            if !queuedPrompts.isEmpty { out.append(queueUpdate()) }
            return out
        }

        for part in results {
            guard let callID = part["tool_use_id"] as? String else { continue }
            let isError = part["is_error"] as? Bool == true
            let blocks = Self.resultBlocks(part["content"])
            out.append(event("tool_execution_end", [
                "toolCallId": callID,
                "result": ["content": blocks],
                "isError": isError
            ]))
            var projected: [String: Any] = [
                "role": "toolResult", "content": blocks, "toolCallId": callID
            ]
            if isError { projected["isError"] = true }
            out.append(event("message_end", ["message": projected]))
        }
        return out
    }

    /// Partial-message deltas, the only source of live streaming text.
    private func streamEvent(_ record: [String: Any]) -> [AdapterInbound] {
        guard record["parent_tool_use_id"] is NSNull || record["parent_tool_use_id"] == nil,
              let inner = record["event"] as? [String: Any],
              let type = inner["type"] as? String else { return [] }
        var out: [AdapterInbound] = []
        startTurn(&out)

        switch type {
        case "message_start":
            stream = StreamAccumulator()
            let message = inner["message"] as? [String: Any]
            startedMessageID = message?["id"] as? String
            stream.model = message?["model"] as? String
            out.append(event("message_start", ["message": ["role": "assistant"]]))
        case "content_block_start":
            guard let index = inner["index"] as? Int else { break }
            stream.start(index: index, block: inner["content_block"] as? [String: Any])
            out.append(event("message_update", ["message": stream.partialMessage()]))
        case "content_block_delta":
            guard let index = inner["index"] as? Int,
                  let delta = inner["delta"] as? [String: Any] else { break }
            guard stream.apply(delta, at: index) else { break }
            out.append(event("message_update", ["message": stream.partialMessage()]))
        case "message_stop", "content_block_stop", "message_delta":
            // The full `assistant` line follows and carries the authoritative content.
            break
        default:
            break
        }
        return out
    }

    private func result(_ record: [String: Any]) -> [AdapterInbound] {
        var out: [AdapterInbound] = []
        if let usage = record["usage"] as? [String: Any] {
            stats.input = usage["input_tokens"] as? Int ?? stats.input
            stats.output = usage["output_tokens"] as? Int ?? stats.output
            stats.cacheRead = usage["cache_read_input_tokens"] as? Int ?? stats.cacheRead
            stats.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? stats.cacheWrite
        }
        if let cost = record["total_cost_usd"] as? Double { stats.cost = cost }

        // An errored turn produces no assistant message of its own, so the reason is surfaced as
        // one rather than disappearing into a silent settle.
        if record["is_error"] as? Bool == true {
            let text = bounded(record["result"] as? String ?? "Claude Code ended the turn with an error.")
            out.append(event("message_end", ["message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
                "provider": "anthropic",
                "stopReason": "error",
                "isError": true,
                "errorMessage": text
            ]]))
        }

        isTurnActive = false
        isCompacting = false
        startedMessageID = nil
        stream = StreamAccumulator()
        if !queuedPrompts.isEmpty {
            queuedPrompts.removeAll()
            out.append(queueUpdate())
        }
        out.append(event("turn_end"))
        out.append(event("agent_settled"))
        return out
    }

    private func permissionRequest(_ record: [String: Any]) -> [AdapterInbound] {
        guard let request = record["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool",
              let requestID = record["request_id"] as? String else { return [] }

        // Never leave Claude blocked on a request this adapter can no longer track: the oldest
        // is denied on the wire instead of being silently forgotten.
        while permissions.count >= Limit.permissions {
            let stale = permissions.removeFirst()
            if let line = permissionReply(requestID: stale.id, allow: false, input: stale.input) {
                writeback.append(line)
            }
        }
        // `updatedInput` has to be the tool's own argument object, so a missing or oddly shaped
        // input degrades to an empty object rather than to something Claude will reject.
        let input = request["input"] as? [String: Any] ?? [:]
        permissions.append((id: requestID, input: input))

        let toolName = request["tool_name"] as? String ?? "tool"
        let title = request["display_name"] as? String ?? toolName
        var message = request["description"] as? String ?? "Allow \(toolName)?"
        if let summary = Self.summary(of: input) { message += "\n\n\(summary)" }
        return [event("extension_ui_request", [
            "method": "confirm",
            "id": requestID,
            "title": bounded(title, max: 200),
            "message": bounded(message, max: Limit.summary)
        ])]
    }

    private func controlResponse(_ record: [String: Any]) -> [AdapterInbound] {
        guard let response = record["response"] as? [String: Any],
              let requestID = response["request_id"] as? String,
              let index = controlRequests.firstIndex(where: { $0.id == requestID }) else { return [] }
        let pending = controlRequests.remove(at: index)

        guard response["subtype"] as? String != "error" else {
            let message = response["error"] as? String ?? "Claude Code rejected the command."
            return [.response(id: requestID, value: .object([
                "type": .string("response"),
                "id": .string(requestID),
                "success": .bool(false),
                "error": .string(bounded(message, max: Limit.summary))
            ]))]
        }

        var data: [String: Any] = [:]
        switch pending.command {
        case "set_model":
            modelID = pending.value
            modelName = pending.value
            data = ["id": modelID ?? "default", "name": modelName ?? "Default", "provider": "anthropic"]
        case "set_mode":
            permissionMode = pending.value
        default:
            break
        }
        return [.response(id: requestID, value: AdapterEncoding.response(id: requestID, data: PiJSONValue(any: data)))]
    }

    // MARK: - Turn bookkeeping

    /// `system/init` arrives at launch, before any prompt, so it deliberately does not start a
    /// turn; conversation traffic does.
    private func startTurn(_ out: inout [AdapterInbound]) {
        guard !isTurnActive else { return }
        isTurnActive = true
        out.append(event("agent_start"))
        out.append(event("turn_start"))
    }

    private func queueUpdate() -> AdapterInbound {
        event("queue_update", ["steering": [], "followUp": queuedPrompts])
    }

    private func event(_ type: String, _ fields: [String: Any] = [:]) -> AdapterInbound {
        var object = fields
        object["type"] = type
        return .event(PiJSONValue(any: object))
    }

    // MARK: - Block translation

    private static func contentBlocks(_ value: Any?) -> [[String: Any]] {
        if let text = value as? String {
            return text.isEmpty ? [] : [["type": "text", "text": boundedText(text)]]
        }
        guard let parts = value as? [[String: Any]] else { return [] }
        var blocks: [[String: Any]] = []
        for part in parts.prefix(Limit.blocks) {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(["type": "text", "text": boundedText(text)])
                }
            case "thinking":
                if let text = part["thinking"] as? String, !text.isEmpty {
                    blocks.append(["type": "thinking", "thinking": boundedText(text)])
                }
            case "tool_use":
                blocks.append([
                    "type": "toolCall",
                    "id": part["id"] as? String ?? "tool",
                    "name": part["name"] as? String ?? "tool",
                    "arguments": part["input"] as? [String: Any] ?? [:]
                ])
            default:
                // redacted_thinking, fallback notices, and anything newer.
                continue
            }
        }
        return blocks
    }

    /// A tool result is either a plain string or Anthropic content blocks.
    private static func resultBlocks(_ value: Any?) -> [[String: Any]] {
        if let text = value as? String {
            return [["type": "text", "text": boundedText(text, max: 80_000)]]
        }
        guard let parts = value as? [[String: Any]] else { return [] }
        var blocks: [[String: Any]] = []
        for part in parts.prefix(Limit.blocks) {
            switch part["type"] as? String {
            case "text":
                blocks.append(["type": "text", "text": boundedText(part["text"] as? String ?? "", max: 80_000)])
            case "image":
                guard let source = part["source"] as? [String: Any],
                      let data = source["data"] as? String, !data.isEmpty else { continue }
                blocks.append([
                    "type": "image",
                    "mimeType": source["media_type"] as? String ?? "image/png",
                    "data": data
                ])
            default:
                continue
            }
        }
        return blocks
    }

    private static func stopReason(_ raw: String?, blocks: [[String: Any]]) -> String {
        switch raw {
        case "tool_use": return "toolUse"
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens": return "length"
        case "refusal": return "error"
        case let value?: return value
        case nil:
            return blocks.contains { ($0["type"] as? String) == "toolCall" } ? "toolUse" : "stop"
        }
    }

    private static func usage(_ value: [String: Any]?) -> [String: Any]? {
        guard let value else { return nil }
        return [
            "input": value["input_tokens"] as? Int ?? 0,
            "output": value["output_tokens"] as? Int ?? 0,
            "cacheRead": value["cache_read_input_tokens"] as? Int ?? 0,
            "cacheWrite": value["cache_creation_input_tokens"] as? Int ?? 0
        ]
    }

    /// A compact, bounded rendering of a tool input for the permission dialog.
    private static func summary(of input: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8), text != "{}" else { return nil }
        return boundedText(text, max: Limit.summary)
    }

    private func bounded(_ text: String, max: Int = Limit.blockText) -> String {
        Self.boundedText(text, max: max)
    }

    private static func boundedText(_ text: String, max: Int = Limit.blockText) -> String {
        text.count <= max ? text : String(text.prefix(max)) + "\n… truncated"
    }

    // MARK: - Streaming accumulator

    /// Rebuilds the in-flight assistant message from `content_block_*` deltas. Bounded by block
    /// count and per-block length so a pathological stream cannot grow without limit.
    private struct StreamAccumulator {
        struct Block {
            var kind = "text"
            var text = ""
            var id = ""
            var name = ""
            var partialJSON = ""
        }

        var model: String?
        private var blocks: [Int: Block] = [:]

        mutating func start(index: Int, block: [String: Any]?) {
            guard blocks.count < Limit.blocks || blocks[index] != nil else { return }
            var value = Block()
            switch block?["type"] as? String {
            case "thinking":
                value.kind = "thinking"
                value.text = block?["thinking"] as? String ?? ""
            case "tool_use":
                value.kind = "toolCall"
                value.id = block?["id"] as? String ?? "tool"
                value.name = block?["name"] as? String ?? "tool"
            default:
                value.kind = "text"
                value.text = block?["text"] as? String ?? ""
            }
            blocks[index] = value
        }

        /// Returns false when the delta carried nothing this projection can show.
        mutating func apply(_ delta: [String: Any], at index: Int) -> Bool {
            guard blocks.count < Limit.blocks || blocks[index] != nil else { return false }
            var block = blocks[index] ?? Block()
            switch delta["type"] as? String {
            case "text_delta":
                block.text = append(block.text, delta["text"] as? String)
            case "thinking_delta":
                block.kind = "thinking"
                block.text = append(block.text, delta["thinking"] as? String)
            case "input_json_delta":
                block.kind = "toolCall"
                block.partialJSON = append(block.partialJSON, delta["partial_json"] as? String, max: 20_000)
            default:
                // signature_delta and anything newer carry nothing renderable.
                return false
            }
            blocks[index] = block
            return true
        }

        func partialMessage() -> [String: Any] {
            var content: [[String: Any]] = []
            for index in blocks.keys.sorted() {
                guard let block = blocks[index] else { continue }
                switch block.kind {
                case "thinking":
                    content.append(["type": "thinking", "thinking": block.text])
                case "toolCall":
                    content.append([
                        "type": "toolCall", "id": block.id, "name": block.name,
                        "arguments": ClaudeProtocolAdapter.partialArguments(block.partialJSON)
                    ])
                default:
                    content.append(["type": "text", "text": block.text])
                }
            }
            var message: [String: Any] = [
                "role": "assistant", "content": content, "provider": "anthropic"
            ]
            if let model { message["model"] = model }
            return message
        }

        private func append(_ existing: String, _ addition: String?, max: Int = Limit.blockText) -> String {
            guard let addition, !addition.isEmpty, existing.count < max else { return existing }
            return existing + addition
        }
    }

    /// Tool arguments only become an object once the streamed JSON is complete; until then the
    /// call renders with empty arguments rather than a half-parsed guess.
    private static func partialArguments(_ json: String) -> [String: Any] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }
}
