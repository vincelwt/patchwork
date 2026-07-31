import Foundation

/// Rewrites one Codex rollout record (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) into the
/// Pi session-record shape.
///
/// A rollout is a flat append-only log with two overlapping views of the same turn:
/// `response_item` (what the model saw) and `event_msg` (what the UI showed). Content comes
/// exclusively from `response_item` so nothing is rendered twice; `event_msg` is consulted only
/// for the facts `response_item` does not carry, namely token usage and compaction.
enum CodexSessionTranscoder {
    static let transcode: @Sendable (Data) -> Data? = { data in
        if let decided = Prefilter.decide(data) { return decided.record }
        guard let record = TranscodeSupport.decode(data),
              let type = record["type"] as? String else { return nil }
        let payload = record["payload"] as? [String: Any] ?? [:]
        let timestamp = record["timestamp"] as? String
        let id = TranscodeSupport.contentID("cdx", data)

        let projected: [String: Any]?
        switch type {
        case "session_meta":
            projected = session(payload: payload, timestamp: timestamp)
        case "turn_context":
            projected = modelChange(id: id, payload: payload)
        case "response_item":
            projected = responseItem(id: id, payload: payload, timestamp: timestamp)
        case "event_msg":
            projected = eventMessage(id: id, payload: payload, timestamp: timestamp)
        case "compacted":
            projected = Prefilter.compaction(id: id, timestamp: timestamp)
        default:
            // world_state, inter_agent_communication_metadata, and anything a newer Codex adds.
            projected = nil
        }
        guard let projected else { return nil }
        return TranscodeSupport.encode(projected)
    }

    // MARK: - Session

    private static func session(payload: [String: Any], timestamp: String?) -> [String: Any] {
        // A subagent rollout is a real file in the same date folder as a user thread. It is
        // marked here and dropped by the repository rather than promoted into the sidebar,
        // exactly like Pi's own nested subagent session files.
        let isSubsession = (payload["thread_source"] as? String) == "subagent"
            || (payload["source"] as? [String: Any])?["subagent"] != nil
        var record: [String: Any] = [
            "type": "session",
            "id": payload["session_id"] as? String ?? payload["id"] as? String ?? "codex",
            "timestamp": payload["timestamp"] as? String ?? timestamp as Any
        ]
        if let cwd = payload["cwd"] as? String { record["cwd"] = cwd }
        if isSubsession { record["subsession"] = true }
        return record
    }

    private static func modelChange(id: String, payload: [String: Any]) -> [String: Any]? {
        guard let model = payload["model"] as? String else { return nil }
        var record: [String: Any] = [
            "type": "model_change", "id": id,
            "provider": payload["model_provider_id"] as? String ?? "openai",
            "modelId": model
        ]
        let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
        if let effort = payload["reasoning_effort"] as? String ?? settings?["reasoning_effort"] as? String {
            record["thinkingLevel"] = effort
        }
        return record
    }

    // MARK: - Response items (the conversation itself)

    private static func responseItem(id: String, payload: [String: Any], timestamp: String?) -> [String: Any]? {
        guard let itemType = payload["type"] as? String else { return nil }
        switch itemType {
        case "message":
            return message(id: id, payload: payload, timestamp: timestamp)
        case "reasoning":
            return reasoning(id: id, payload: payload, timestamp: timestamp)
        case "function_call":
            return toolCall(
                id: id, timestamp: timestamp,
                callID: payload["call_id"] as? String ?? id,
                name: payload["name"] as? String ?? "tool",
                arguments: payload["arguments"]
            )
        case "custom_tool_call":
            return toolCall(
                id: id, timestamp: timestamp,
                callID: payload["call_id"] as? String ?? id,
                name: payload["name"] as? String ?? "tool",
                arguments: payload["input"]
            )
        case "tool_search_call":
            return toolCall(
                id: id, timestamp: timestamp,
                callID: payload["call_id"] as? String ?? id,
                name: "tool_search",
                arguments: payload["arguments"]
            )
        case "web_search_call":
            return toolCall(
                id: id, timestamp: timestamp,
                callID: payload["call_id"] as? String ?? id,
                name: "web_search",
                arguments: payload["action"]
            )
        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            return toolResult(id: id, payload: payload, timestamp: timestamp)
        default:
            // `agent_message` carries encrypted inter-agent payloads with nothing to render.
            return nil
        }
    }

    private static func message(id: String, payload: [String: Any], timestamp: String?) -> [String: Any]? {
        guard let role = payload["role"] as? String else { return nil }
        // Developer/system turns are Codex's own injected harness context, not conversation.
        guard role == "user" || role == "assistant" else { return nil }
        let blocks = contentBlocks(payload["content"])
        guard !blocks.isEmpty else { return nil }
        var message: [String: Any] = ["role": role, "content": blocks]
        if role == "assistant" { message["stopReason"] = "stop" }
        return entry(id: id, timestamp: timestamp, message: message)
    }

    private static func reasoning(id: String, payload: [String: Any], timestamp: String?) -> [String: Any]? {
        var blocks: [[String: Any]] = []
        for part in (payload["summary"] as? [[String: Any]] ?? []) {
            if let text = part["text"] as? String, !text.isEmpty {
                blocks.append(TranscodeSupport.thinkingBlock(text))
            }
        }
        for part in (payload["content"] as? [[String: Any]] ?? []) {
            if let text = part["text"] as? String, !text.isEmpty {
                blocks.append(TranscodeSupport.thinkingBlock(text))
            }
        }
        guard !blocks.isEmpty else { return nil }
        return entry(
            id: id, timestamp: timestamp,
            message: ["role": "assistant", "content": blocks, "stopReason": "toolUse"]
        )
    }

    private static func toolCall(
        id: String, timestamp: String?, callID: String, name: String, arguments: Any?
    ) -> [String: Any] {
        entry(id: id, timestamp: timestamp, message: [
            "role": "assistant",
            "stopReason": "toolUse",
            "content": [TranscodeSupport.toolCallBlock(
                id: callID, name: name, arguments: TranscodeSupport.normalizedArguments(arguments)
            )]
        ])
    }

    private static func toolResult(id: String, payload: [String: Any], timestamp: String?) -> [String: Any] {
        let text: String
        if let output = payload["output"] as? String {
            text = output
        } else if let parts = payload["output"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else if let tools = payload["tools"] {
            text = String(describing: tools)
        } else {
            text = ""
        }
        var message: [String: Any] = [
            "role": "toolResult",
            "content": [TranscodeSupport.textBlock(text)],
            "toolCallId": payload["call_id"] as? String ?? id
        ]
        if (payload["status"] as? String) == "failed" { message["isError"] = true }
        return entry(id: id, timestamp: timestamp, message: message)
    }

    // MARK: - Event messages (usage and compaction only)

    private static func eventMessage(id: String, payload: [String: Any], timestamp: String?) -> [String: Any]? {
        switch payload["type"] as? String {
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return nil }
            let cacheRead = last["cached_input_tokens"] as? Int ?? 0
            // Codex reports total input including the cached portion; Pi counts them separately.
            let input = max(0, (last["input_tokens"] as? Int ?? 0) - cacheRead)
            return [
                "type": "usage", "id": id, "timestamp": timestamp as Any,
                "usage": [
                    "input": input,
                    "output": last["output_tokens"] as? Int ?? 0,
                    "cacheRead": cacheRead,
                    "cacheWrite": last["cache_write_input_tokens"] as? Int ?? 0
                ]
            ]
        case "context_compacted":
            return [
                "type": "compaction", "id": id, "timestamp": timestamp as Any,
                "summary": "Earlier context was compacted."
            ]
        case "thread_settings_applied":
            guard let settings = payload["thread_settings"] as? [String: Any] else { return nil }
            return modelChange(id: id, payload: settings)
        default:
            return nil
        }
    }

    // MARK: - Blocks

    private static func contentBlocks(_ value: Any?) -> [[String: Any]] {
        guard let parts = value as? [[String: Any]] else {
            if let text = value as? String, !text.isEmpty { return [TranscodeSupport.textBlock(text)] }
            return []
        }
        var blocks: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "output_text", "summary_text", "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(TranscodeSupport.textBlock(text))
                }
            case "input_image":
                if let block = imageBlock(part["image_url"] as? String) { blocks.append(block) }
            case "encrypted_content", "reasoning_text":
                continue
            default:
                continue
            }
        }
        return blocks
    }

    /// Codex embeds images as `data:<mime>;base64,<payload>` URLs; Pi stores mime and payload
    /// separately. A non-data URL has nothing decodable, so it is dropped rather than guessed at.
    private static func imageBlock(_ url: String?) -> [String: Any]? {
        guard let url, url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mime = String(header.dropLast(";base64".count))
        return [
            "type": "image",
            "mimeType": mime.isEmpty ? "image/png" : mime,
            "data": String(url[url.index(after: comma)...])
        ]
    }

    private static func entry(id: String, timestamp: String?, message: [String: Any]) -> [String: Any] {
        var record: [String: Any] = ["type": "message", "id": id, "message": message]
        if let timestamp { record["timestamp"] = timestamp }
        return record
    }
}

// MARK: - Prefilter

extension CodexSessionTranscoder {
    /// A bounded byte scan that decides some records without parsing them.
    ///
    /// Codex rollouts are dominated by records this transcoder throws away or reduces to a
    /// constant: on a real machine, `compacted` (which embeds an entire replaced history),
    /// `image_generation_end`, and `mcp_tool_call_end` accounted for ~78% of all rollout bytes,
    /// and every one of them was being fully deserialized only to be dropped. Deciding them from
    /// a short prefix keeps opening a Codex conversation proportional to what is actually
    /// rendered rather than to what the agent happened to store.
    ///
    /// The rule that keeps this safe: the prefilter may only reach a decision it is certain the
    /// full transcoder would reach. Anything it cannot settle within the prefix returns nil and
    /// falls through to the ordinary decode.
    enum Prefilter {
        /// Long enough to contain `{"timestamp":"…","type":"…","payload":{"type":"…"` for every
        /// record Codex writes, short enough that scanning it is free next to a full parse.
        static let prefixBytes = 320

        enum Decision {
            case drop
            case emit(Data?)

            var record: Data? {
                switch self {
                case .drop: nil
                case let .emit(data): data
                }
            }
        }

        /// Record types with nothing to render, whatever their payload contains.
        static let droppedRecordTypes = ["world_state", "inter_agent_communication_metadata"]

        /// The only `event_msg` payloads the transcoder keeps. An `event_msg` whose payload type
        /// is visible in the prefix and is not one of these cannot produce anything.
        static let keptEventPayloads = ["token_count", "context_compacted", "thread_settings_applied"]

        static func decide(_ data: Data) -> Decision? {
            let prefix = data.prefix(prefixBytes)
            guard let type = value(of: "type", in: prefix) else { return nil }

            if droppedRecordTypes.contains(type) { return .drop }

            // `compacted` carries the whole replaced history and contributes exactly one constant
            // line, so there is never a reason to parse the payload.
            if type == "compacted" {
                let timestamp = value(of: "timestamp", in: prefix)
                let id = TranscodeSupport.contentID("cdx", data)
                return .emit(TranscodeSupport.encode(compaction(id: id, timestamp: timestamp)))
            }

            if type == "event_msg" {
                // The payload's own type follows the record's. Only decide when it is actually
                // visible in the prefix; a truncated prefix must fall through, not guess.
                guard let payloadType = value(of: "type", in: prefix, occurrence: 2) else { return nil }
                return keptEventPayloads.contains(payloadType) ? nil : .drop
            }

            return nil
        }

        static func compaction(id: String, timestamp: String?) -> [String: Any] {
            var record: [String: Any] = [
                "type": "compaction", "id": id, "summary": "Earlier context was compacted."
            ]
            if let timestamp { record["timestamp"] = timestamp }
            return record
        }

        /// Finds `"<key>":"<value>"` in a byte slice without allocating a string for the whole
        /// slice. `occurrence` selects the nth match, so a record's own `type` and its payload's
        /// `type` can be told apart by position.
        static func value<Bytes: Collection>(
            of key: String, in bytes: Bytes, occurrence: Int = 1
        ) -> String? where Bytes.Element == UInt8 {
            let needle = Array("\"\(key)\":\"".utf8)
            var found = 0
            var index = bytes.startIndex
            while index < bytes.endIndex {
                guard matches(needle, in: bytes, at: index) else {
                    index = bytes.index(after: index)
                    continue
                }
                found += 1
                var cursor = bytes.index(index, offsetBy: needle.count, limitedBy: bytes.endIndex) ?? bytes.endIndex
                var value: [UInt8] = []
                while cursor < bytes.endIndex, bytes[cursor] != UInt8(ascii: "\"") {
                    // A quoted value with an escape is not a bare identifier; leave it to the parser.
                    if bytes[cursor] == UInt8(ascii: "\\") { return nil }
                    value.append(bytes[cursor])
                    cursor = bytes.index(after: cursor)
                }
                // Reaching the end without a closing quote means the prefix cut the value short.
                guard cursor < bytes.endIndex else { return nil }
                if found == occurrence { return String(decoding: value, as: UTF8.self) }
                index = cursor
            }
            return nil
        }

        private static func matches<Bytes: Collection>(
            _ needle: [UInt8], in bytes: Bytes, at start: Bytes.Index
        ) -> Bool where Bytes.Element == UInt8 {
            var cursor = start
            for byte in needle {
                guard cursor < bytes.endIndex, bytes[cursor] == byte else { return false }
                cursor = bytes.index(after: cursor)
            }
            return true
        }
    }
}
