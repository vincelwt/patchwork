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
        // Response items already carry the app-server item id. Keeping it makes the live event
        // and its durable rollout projection the same message instead of two lookalikes. Older
        // records without an id retain the deterministic content hash fallback.
        let id = (type == "response_item" ? payload["id"] as? String : nil)
            ?? TranscodeSupport.contentID("cdx", data)

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
        var blocks = contentBlocks(payload["content"])
        guard !blocks.isEmpty else { return nil }

        guard let cleaned = HarnessText.blocks(blocks, role: role) else { return nil }
        blocks = cleaned

        var message: [String: Any] = ["role": role, "content": blocks]
        if role == "assistant" {
            // Codex narrates continuously while it works and marks which of those messages is
            // actually the answer. Treating every one as a completed answer made each mid-turn
            // remark close a turn: the transcript never collapsed its reasoning, and the sidebar
            // flipped between running and done on every write.
            message["stopReason"] = (payload["phase"] as? String) == "final_answer" ? "stop" : "toolUse"
        }
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
            return tokenCount(id: id, payload: payload, timestamp: timestamp)
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

    /// Codex reports *cumulative* totals for the whole thread on every turn, so the newest
    /// record is the complete answer and earlier ones are superseded rather than added. Marking
    /// it as such is what lets a summary read the usage from the file's tail instead of summing
    /// its way through every record.
    private static func tokenCount(id: String, payload: [String: Any], timestamp: String?) -> [String: Any]? {
        guard let info = payload["info"] as? [String: Any] else { return nil }
        guard let total = info["total_token_usage"] as? [String: Any] else { return nil }
        let cacheRead = total["cached_input_tokens"] as? Int ?? 0
        // Codex counts the cached portion inside its input total; Pi counts them separately.
        let input = max(0, (total["input_tokens"] as? Int ?? 0) - cacheRead)
        var record: [String: Any] = [
            "type": "usage", "id": id, "cumulative": true,
            "usage": [
                "input": input,
                "output": total["output_tokens"] as? Int ?? 0,
                "cacheRead": cacheRead,
                "cacheWrite": total["cache_write_input_tokens"] as? Int ?? 0
            ]
        ]
        if let timestamp { record["timestamp"] = timestamp }
        if let window = info["model_context_window"] as? Int { record["contextWindow"] = window }
        if let used = total["total_tokens"] as? Int { record["contextTokens"] = used }
        return record
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

// MARK: - Harness text

extension CodexSessionTranscoder {
    /// Codex delivers its own scaffolding as `user`-role turns: the plugin catalogue, the
    /// environment block, project instructions, review guidelines. None of it is the user
    /// talking, and because a conversation's name comes from its first user message, every
    /// Codex thread was being titled after the plugin catalogue.
    ///
    /// One turn can also *wrap* a real message ("Files mentioned by the user" puts attachments
    /// above the actual request), so a wrapper is unwrapped rather than dropped.
    enum HarnessText {
        /// A structured section Codex wraps in its own tag, and how it should read as a card.
        /// Everything here was observed in this machine's own rollouts.
        struct Section {
            let tag: String
            let symbol: String
            let title: String
        }

        /// Blocks Codex wraps in an XML-ish tag. Rendered as a titled, collapsed card rather
        /// than as pages of raw markup in the middle of the conversation.
        static let sections = [
            Section(tag: "environment_context", symbol: "desktopcomputer", title: "Environment"),
            Section(tag: "recommended_plugins", symbol: "puzzlepiece.extension", title: "Recommended plugins"),
            Section(tag: "heartbeat", symbol: "clock.arrow.circlepath", title: "Automation trigger"),
            Section(tag: "oai-mem-citation", symbol: "brain", title: "Memory"),
            Section(tag: "user_instructions", symbol: "doc.text", title: "Instructions"),
            Section(tag: "project_doc", symbol: "doc.text", title: "Project notes"),
            Section(tag: "skills_instructions", symbol: "wrench.and.screwdriver", title: "Skills"),
            Section(tag: "apps_instructions", symbol: "app.badge", title: "Apps"),
            Section(tag: "plugins_instructions", symbol: "puzzlepiece.extension", title: "Plugins"),
            Section(tag: "collaboration_mode", symbol: "person.2", title: "Collaboration mode"),
            Section(tag: "multi_agent_mode", symbol: "person.3", title: "Multi-agent mode")
        ]

        /// Markdown headings Codex uses for the same purpose, with no tag to match on.
        static let headingSections = [
            (prefix: "# AGENTS.md instructions", symbol: "doc.text", title: "Project instructions"),
            (prefix: "## Code review guidelines:", symbol: "checklist", title: "Review guidelines"),
            (prefix: "# Review Guidelines", symbol: "checklist", title: "Review guidelines")
        ]

        /// Everything after this marker is the real request; everything before it is attachment
        /// bookkeeping Codex prepended.
        static let requestMarkers = ["## My request for Codex:", "# My request for Codex:"]

        /// Rewrites one message's blocks: scaffolding becomes cards, the user's own words stay
        /// prose. Returns nil when nothing at all would render.
        static func blocks(_ blocks: [[String: Any]], role: String) -> [[String: Any]]? {
            var out: [[String: Any]] = []
            for block in blocks {
                guard (block["type"] as? String) == "text", let text = block["text"] as? String else {
                    out.append(block)
                    continue
                }
                out.append(contentsOf: split(text: text, role: role))
            }
            return out.isEmpty ? nil : out
        }

        /// Splits one text block into prose and cards, preserving their original order so a
        /// citation that trailed an answer still trails it.
        static func split(text raw: String, role: String) -> [[String: Any]] {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }

            // An attachment wrapper carries the real request below its file list.
            for marker in requestMarkers {
                guard let range = text.range(of: marker) else { continue }
                let files = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let request = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                var out: [[String: Any]] = []
                if !files.isEmpty {
                    out.append(note(symbol: "paperclip", title: "Attachments", body: files))
                }
                if !request.isEmpty { out.append(TranscodeSupport.textBlock(request)) }
                return out
            }

            var out: [[String: Any]] = []
            var guardRail = 0
            while guardRail < 32 {
                guardRail += 1
                guard let found = firstSection(in: text) else { break }
                let before = String(text[text.startIndex..<found.range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { out.append(TranscodeSupport.textBlock(before)) }
                out.append(note(
                    symbol: found.section.symbol, title: found.section.title,
                    body: String(text[found.range])
                ))
                text = String(text[found.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            for heading in headingSections where text.hasPrefix(heading.prefix) {
                out.append(note(symbol: heading.symbol, title: heading.title, body: text))
                return out
            }
            if !text.isEmpty { out.append(TranscodeSupport.textBlock(text)) }
            return out
        }

        /// The earliest complete `<tag>…</tag>` span this build recognises. An unterminated tag
        /// is left as prose rather than swallowing the rest of the message.
        private static func firstSection(in text: String) -> (section: Section, range: Range<String.Index>)? {
            var best: (Section, Range<String.Index>)?
            for section in sections {
                guard let open = text.range(of: "<\(section.tag)>"),
                      let close = text.range(of: "</\(section.tag)>", range: open.upperBound..<text.endIndex)
                else { continue }
                let span = open.lowerBound..<close.upperBound
                if best == nil || span.lowerBound < best!.1.lowerBound { best = (section, span) }
            }
            return best.map { (section: $0.0, range: $0.1) }
        }

        private static func note(symbol: String, title: String, body: String) -> [String: Any] {
            // The card's collapsed line shows the first meaningful line of its content, which is
            // what makes a wall of markup scannable without expanding it.
            let inner = body
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("#") } ?? ""
            return [
                "type": "note", "symbol": symbol, "title": title,
                "summary": TranscodeSupport.bounded(String(inner.prefix(120)), max: 120),
                "body": TranscodeSupport.bounded(body, max: 40_000)
            ]
        }
    }
}
