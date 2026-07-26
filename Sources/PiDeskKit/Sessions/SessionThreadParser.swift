import Foundation

/// Reads a Pi session JSONL into the control API's wire shapes. Deliberately not a port of the
/// app's full `SessionParser` (`Sources/PiDesktop/SessionParser.swift`): the daemon never renders
/// a transcript, so there is no need for content blocks, images, tool-call payloads, or active-
/// branch reconstruction — only the scalar fields `PiThread`/`Message` actually carry. Where the
/// two overlap in spirit (title/preview heuristics) this intentionally follows the doc's wire
/// contract rather than the app's own field semantics, since the two differ: the app's sidebar
/// preview is the first user prompt, but `docs/daemon-api.md` defines `Thread.preview` as "first
/// line of the last assistant message".
public enum SessionThreadParser {
    public static let previewLimit = 160
    public static let titleLimit = 74
    /// Per-block text bound so one huge message cannot make a summary scan retain unbounded text.
    static let blockTextLimit = 4_000

    public enum ParseError: Error { case notASession }

    /// Single forward pass: every retained value is a scalar accumulator, so memory use does not
    /// grow with session size regardless of how many entries the file contains.
    public static func thread(at url: URL) throws -> PiThread {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = url.deletingLastPathComponent()
        var createdAt: Date?
        var explicitName: String?
        var firstUserText: String?
        var lastAssistantText: String?
        var messageCount = 0
        var cost = 0.0
        var sawAnyEntry = false

        try JSONLFileReader.read(url: url) { data in
            try Task.checkCancellation()
            guard let value = try? PiJSONValue.decode(data), let object = value.objectValue else { return }
            let type = object["type"]?.stringValue ?? "unknown"
            sawAnyEntry = true

            switch type {
            case "session":
                sessionID = object["id"]?.stringValue ?? sessionID
                if let path = object["cwd"]?.stringValue, !path.isEmpty { cwd = URL(fileURLWithPath: path) }
                createdAt = object["timestamp"]?.stringValue.flatMap(PiDeskDate.date(from:))
            case "session_info":
                explicitName = object["name"]?.stringValue
            case "message":
                messageCount += 1
                guard let message = object["message"] else { return }
                cost += message["usage"]?["cost"]?["total"]?.doubleValue ?? 0
                switch message["role"]?.stringValue {
                case "user":
                    if firstUserText == nil, let text = plainText(from: message["content"]), !text.isEmpty { firstUserText = text }
                case "assistant":
                    // A preview is what Pi *said*. Reasoning and tool chatter are real content
                    // but they read as noise in a one-line summary, so prose wins when present.
                    if let prose = plainText(from: message["content"], proseOnly: true), !prose.isEmpty {
                        lastAssistantText = prose
                    } else if lastAssistantText == nil, let text = plainText(from: message["content"]), !text.isEmpty {
                        lastAssistantText = text
                    }
                default:
                    break
                }
            case "compaction", "branch_summary":
                cost += object["usage"]?["cost"]?["total"]?.doubleValue ?? 0
            default:
                break
            }
        }

        guard sawAnyEntry else { throw ParseError.notASession }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modifiedAt = resourceValues?.contentModificationDate ?? createdAt ?? .distantPast
        let creation = createdAt ?? resourceValues?.creationDate ?? modifiedAt
        let standardizedURL = url.standardizedFileURL
        let standardizedCwd = cwd.standardizedFileURL
        let folder = standardizedCwd.lastPathComponent.isEmpty ? standardizedCwd.path : standardizedCwd.lastPathComponent

        let title = explicitName?.condensedPiDesk.nonEmptyPiDesk
            ?? firstUserText?.headlinePiDesk(max: titleLimit)
            ?? "Untitled conversation"
        // Per the doc: the last assistant line, not the app's "first user prompt" sidebar preview.
        let preview = lastAssistantText?.headlinePiDesk(max: previewLimit)
            ?? firstUserText?.headlinePiDesk(max: previewLimit)
            ?? ""

        return PiThread(
            id: sessionID,
            path: standardizedURL.path,
            name: title,
            cwd: standardizedCwd.path,
            folder: folder,
            createdAt: creation,
            updatedAt: modifiedAt,
            running: false, // overlaid by the caller from heartbeat state
            unread: false, // overlaid by the caller from app state, best-effort
            archived: false, // overlaid by the caller from app state, best-effort
            preview: preview,
            cost: messageCount > 0 ? cost : nil,
            // Only known live, from `get_session_stats`; a static file scan cannot recover it.
            contextPercent: nil
        )
    }

    /// The last `limit` messages in file order. Bounded to roughly `2 * limit` transient entries
    /// at any moment (periodic trims, not one per append) so scanning a huge session for a small
    /// tail stays cheap and never retains the whole file.
    public static func messages(at url: URL, limit: Int) throws -> [Message] {
        guard limit > 0 else { return [] }
        var buffer: [Message] = []
        buffer.reserveCapacity(min(limit, 512))

        try JSONLFileReader.read(url: url) { data in
            try Task.checkCancellation()
            guard let value = try? PiJSONValue.decode(data), let object = value.objectValue,
                  let message = Self.wireMessage(from: object) else { return }
            buffer.append(message)
            if buffer.count > limit * 2 { buffer.removeFirst(buffer.count - limit) }
        }
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        return buffer
    }

    private static func wireMessage(from entry: [String: PiJSONValue]) -> Message? {
        let type = entry["type"]?.stringValue ?? "unknown"
        let id = entry["id"]?.stringValue ?? UUID().uuidString

        switch type {
        case "message":
            guard let message = entry["message"] else { return nil }
            let roleName = message["role"]?.stringValue ?? "unknown"
            // "toolResult" is the closest of the four wire roles to a shell result.
            let role = roleName == "bashExecution" ? MessageRole.toolResult : MessageRole(rawValue: roleName)
            let text = plainText(from: message["content"]) ?? ""
            let isError = message["isError"]?.boolValue ?? (message["stopReason"]?.stringValue == "error")
            let at = timestamp(from: message["timestamp"]) ?? .distantPast
            return Message(id: id, role: role, text: text, at: at, isError: isError)
        case "compaction":
            let summary = entry["summary"]?.stringValue ?? "Earlier context was compacted."
            return Message(id: id, role: .system, text: "Context compacted: \(bounded(summary, max: blockTextLimit))", at: timestamp(from: entry["timestamp"]) ?? .distantPast)
        case "branch_summary":
            let summary = entry["summary"]?.stringValue ?? "Branch context summary."
            return Message(id: id, role: .system, text: "Branch summary: \(bounded(summary, max: blockTextLimit))", at: timestamp(from: entry["timestamp"]) ?? .distantPast)
        default:
            return nil
        }
    }

    /// Milliseconds-since-epoch (Pi's own JSONL convention) or an ISO 8601 string.
    private static func timestamp(from value: PiJSONValue?) -> Date? {
        if let milliseconds = value?.doubleValue { return Date(timeIntervalSince1970: milliseconds / 1_000) }
        return value?.stringValue.flatMap(PiDeskDate.date(from:))
    }

    /// Text-only projection of a message's content: a plain string, or the `text` blocks of a
    /// content array joined by newlines, with lightweight markers for the block kinds this
    /// simplified reader does not carry (images, tool calls, thinking).
    private static func plainText(from content: PiJSONValue?, proseOnly: Bool = false) -> String? {
        guard let content else { return nil }
        if let text = content.stringValue { return bounded(text, max: blockTextLimit) }
        guard let blocks = content.arrayValue else { return nil }

        var parts: [String] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { parts.append(text) }
            case "thinking":
                if proseOnly { break }
                if let text = block["thinking"]?.stringValue, !text.isEmpty { parts.append("[thinking] \(text)") }
            case "image":
                if proseOnly { break }
                parts.append("[image]")
            case "toolCall":
                if proseOnly { break }
                parts.append("[tool: \(block["name"]?.stringValue ?? "unknown")]")
            default:
                break
            }
        }
        guard !parts.isEmpty else { return nil }
        return bounded(parts.joined(separator: "\n"), max: blockTextLimit)
    }

    private static func bounded(_ value: String, max: Int) -> String {
        value.count <= max ? value : String(value.prefix(max)) + "\u{2026}"
    }
}

private extension String {
    var condensedPiDesk: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmptyPiDesk: String? { isEmpty ? nil : self }

    func headlinePiDesk(max length: Int) -> String {
        let condensed = condensedPiDesk
        guard condensed.count > length else { return condensed }
        return String(condensed.prefix(length - 1)) + "\u{2026}"
    }
}
