import Foundation

/// Rewrites one Claude Code transcript record (`~/.claude/projects/<slug>/<uuid>.jsonl`) into
/// the Pi session-record shape.
///
/// Claude's transcript is the closest of the three to Pi's: every conversation record carries
/// `uuid`/`parentUuid`, so the real branch structure survives and the app's existing
/// active-branch walk, paging, and edit history all keep working untouched.
enum ClaudeSessionTranscoder {
    static let transcode: @Sendable (Data) -> Data? = { data in
        guard let record = TranscodeSupport.decode(data),
              let type = record["type"] as? String else { return nil }

        // Subagent turns are interleaved into the same file on their own parent chains. They are
        // a separate transcript, not part of this conversation.
        if record["isSidechain"] as? Bool == true { return nil }

        let projected: [String: Any]?
        switch type {
        case "assistant":
            projected = assistant(record)
        case "user":
            projected = user(record)
        case "system":
            projected = system(record)
        case "custom-title":
            projected = title(record["customTitle"])
        case "ai-title":
            projected = title(record["aiTitle"])
        default:
            // attachment, queue-operation, last-prompt, mode, permission-mode, pr-link,
            // file-history-snapshot, frame-link, and anything a newer Claude adds.
            projected = nil
        }
        guard let projected else { return nil }
        return TranscodeSupport.encode(projected)
    }

    // MARK: - Conversation

    private static func assistant(_ record: [String: Any]) -> [String: Any]? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        let blocks = contentBlocks(message["content"])
        guard !blocks.isEmpty else { return nil }

        var projected: [String: Any] = ["role": "assistant", "content": blocks]
        if let model = message["model"] as? String {
            projected["model"] = model
            projected["provider"] = "anthropic"
        }
        let resolvedStopReason = stopReason(message["stop_reason"] as? String, blocks: blocks)
        projected["stopReason"] = resolvedStopReason
        if let usage = usage(message["usage"] as? [String: Any]) { projected["usage"] = usage }
        if record["isApiErrorMessage"] as? Bool == true { projected["isError"] = true }
        // Claude reuses one provider message id across the thinking, narration, and tool-call
        // records of a response. Those records need their transcript UUIDs so SwiftUI and the
        // live overlay do not overwrite one another. The terminal answer keeps the provider id
        // to reconcile the streamed answer with its durable copy without a visible duplicate.
        let hydrationID = ClaudeMessageIdentity.preferredID(
            providerID: message["id"] as? String,
            recordID: record["uuid"] as? String,
            stopReason: resolvedStopReason,
            blocks: blocks
        )
        return entry(record, id: hydrationID, message: projected)
    }

    private static func user(_ record: [String: Any]) -> [String: Any]? {
        // Claude injects harness context as synthetic user turns; they are not the user talking.
        if record["isMeta"] as? Bool == true { return nil }
        guard let message = record["message"] as? [String: Any] else { return nil }

        if record["isCompactSummary"] as? Bool == true {
            var projected: [String: Any] = [
                "type": "compaction",
                "id": record["uuid"] as? String ?? "claude-compaction",
                "summary": firstText(message["content"]) ?? "Earlier context was compacted."
            ]
            if let parent = record["parentUuid"] as? String { projected["parentId"] = parent }
            if let timestamp = record["timestamp"] as? String { projected["timestamp"] = timestamp }
            return projected
        }

        let blocks = contentBlocks(message["content"])
        guard !blocks.isEmpty else { return nil }

        // A Claude user turn that carries tool results is the transport for those results, not a
        // user message. Pi models one result per entry while Claude batches parallel results into
        // one record; a 1:1 record transform cannot split them, so they are joined under the
        // first call id.
        // ponytail: parallel results share one row. Split them if per-call collapsing matters.
        if let toolCallID = firstToolResultID(message["content"]) {
            var projected: [String: Any] = [
                "role": "toolResult", "content": blocks, "toolCallId": toolCallID
            ]
            if anyToolResultIsError(message["content"]) { projected["isError"] = true }
            return entry(record, message: projected)
        }
        return entry(record, message: ["role": "user", "content": blocks])
    }

    /// Only system records that actually carry prose become visible; hook bookkeeping does not.
    private static func system(_ record: [String: Any]) -> [String: Any]? {
        guard let content = record["content"] as? String, !content.isEmpty else { return nil }
        var message: [String: Any] = ["role": "system", "content": [TranscodeSupport.textBlock(content)]]
        if (record["level"] as? String) == "error" { message["isError"] = true }
        return entry(record, message: message)
    }

    /// Title records carry no uuid and must not enter the parent chain, so they are emitted
    /// without an id: the summary pass reads the name and the transcript pass ignores them.
    private static func title(_ value: Any?) -> [String: Any]? {
        guard let name = value as? String, !name.isEmpty else { return nil }
        return ["type": "session_info", "name": TranscodeSupport.bounded(name, max: 500)]
    }

    // MARK: - Blocks

    private static func contentBlocks(_ value: Any?) -> [[String: Any]] {
        if let text = value as? String {
            return text.isEmpty ? [] : [TranscodeSupport.textBlock(text)]
        }
        guard let parts = value as? [[String: Any]] else { return [] }

        var blocks: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(TranscodeSupport.textBlock(text))
                }
            case "thinking":
                if let text = part["thinking"] as? String, !text.isEmpty {
                    blocks.append(TranscodeSupport.thinkingBlock(text))
                }
            case "tool_use":
                blocks.append(TranscodeSupport.toolCallBlock(
                    id: part["id"] as? String ?? "tool",
                    name: part["name"] as? String ?? "tool",
                    arguments: TranscodeSupport.normalizedArguments(part["input"])
                ))
            case "tool_result":
                if let text = resultText(part["content"]), !text.isEmpty {
                    blocks.append(TranscodeSupport.textBlock(text))
                }
                blocks.append(contentsOf: resultImages(part["content"]))
            case "image":
                if let block = imageBlock(part["source"] as? [String: Any]) { blocks.append(block) }
            default:
                // `fallback` (model downgrade notices) and any newer block type.
                continue
            }
        }
        return blocks
    }

    /// A tool result is either a plain string or Anthropic content blocks.
    private static func resultText(_ value: Any?) -> String? {
        if let text = value as? String { return TranscodeSupport.bounded(text, max: 80_000) }
        guard let parts = value as? [[String: Any]] else { return nil }
        let joined = parts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : TranscodeSupport.bounded(joined, max: 80_000)
    }

    private static func resultImages(_ value: Any?) -> [[String: Any]] {
        guard let parts = value as? [[String: Any]] else { return [] }
        return parts
            .filter { ($0["type"] as? String) == "image" }
            .compactMap { imageBlock($0["source"] as? [String: Any]) }
    }

    private static func imageBlock(_ source: [String: Any]?) -> [String: Any]? {
        guard let source, (source["type"] as? String) == "base64",
              let data = source["data"] as? String, !data.isEmpty else { return nil }
        return [
            "type": "image",
            "mimeType": source["media_type"] as? String ?? "image/png",
            "data": data
        ]
    }

    private static func firstText(_ value: Any?) -> String? {
        if let text = value as? String { return TranscodeSupport.bounded(text, max: 80_000) }
        guard let parts = value as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.first.map { TranscodeSupport.bounded($0, max: 80_000) }
    }

    private static func firstToolResultID(_ value: Any?) -> String? {
        guard let parts = value as? [[String: Any]] else { return nil }
        return parts.first { ($0["type"] as? String) == "tool_result" }?["tool_use_id"] as? String
    }

    private static func anyToolResultIsError(_ value: Any?) -> Bool {
        guard let parts = value as? [[String: Any]] else { return false }
        return parts.contains { ($0["type"] as? String) == "tool_result" && ($0["is_error"] as? Bool) == true }
    }

    // MARK: - Shape

    private static func stopReason(_ raw: String?, blocks: [[String: Any]]) -> String {
        switch raw {
        case "tool_use": return "toolUse"
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens": return "length"
        case "refusal": return "error"
        case let value?: return value
        case nil:
            // Progressive Claude narration records commonly omit a stop reason. A later record
            // with the same provider id carries the explicit tool or terminal boundary.
            return "toolUse"
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

    /// Claude has no session header record, so cwd and session id ride on every conversation
    /// entry and the summary pass takes them from the first entry that carries them.
    private static func entry(
        _ record: [String: Any], id preferredID: String? = nil, message: [String: Any]
    ) -> [String: Any]? {
        guard let uuid = record["uuid"] as? String else { return nil }
        var projected: [String: Any] = ["type": "message", "id": preferredID ?? uuid, "message": message]
        if let parent = record["parentUuid"] as? String { projected["parentId"] = parent }
        if let timestamp = record["timestamp"] as? String { projected["timestamp"] = timestamp }
        if let cwd = record["cwd"] as? String { projected["cwd"] = cwd }
        if let session = record["sessionId"] as? String { projected["sessionId"] = session }
        return projected
    }
}

/// Claude writes one provider response as multiple transcript records. Only the answer-bearing
/// terminal record shares the live stream's provider id; thinking and tool records retain their
/// transcript UUIDs so every projected row stays unique.
enum ClaudeMessageIdentity {
    static func preferredID(
        providerID: String?, recordID: String?, stopReason: String, blocks: [[String: Any]]
    ) -> String? {
        let isTerminal = ["stop", "length", "error", "aborted"].contains(stopReason)
        let carriesAnswer = blocks.contains {
            let type = $0["type"] as? String
            return type == "text" || type == "image"
        }
        return isTerminal && carriesAnswer
            ? (providerID ?? recordID)
            : (recordID ?? providerID)
    }
}
