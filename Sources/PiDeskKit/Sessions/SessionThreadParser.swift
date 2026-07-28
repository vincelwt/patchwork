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
    /// Ceiling on structured blocks projected for one message. Order past this is lost, but the
    /// message itself (and its flattened `text`) is not.
    static let blocksPerMessageLimit = 40

    /// Largest decoded image `GET /v1/threads/{id}/images/{imageId}` will ever return. Chosen so
    /// one image plus its base64 expansion (~4/3) and JSON envelope still fits inside the hosted
    /// relay's 1.5 MB encrypted-plaintext ceiling; anything bigger is reported as `tooLarge`
    /// rather than truncated into a corrupt picture.
    public static let imageByteLimit = 1_000_000
    /// Per-message ceiling on how many image references one projected message may carry.
    public static let imagesPerMessageLimit = 8
    /// Ceiling across one `messages(at:limit:)` projection. Newest images win; the rest are
    /// still listed, as `omitted`, so nothing silently disappears from the transcript.
    public static let imagesPerRequestLimit = 40

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
        var ordinal = 0

        try JSONLFileReader.read(url: url) { data in
            try Task.checkCancellation()
            let entryOrdinal = ordinal
            ordinal += 1
            guard let value = try? PiJSONValue.decode(data), let object = value.objectValue,
                  let message = Self.wireMessage(from: object, ordinal: entryOrdinal) else { return }
            buffer.append(message)
            if buffer.count > limit * 2 { buffer.removeFirst(buffer.count - limit) }
        }
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        return applyImageBudget(to: buffer)
    }

    /// The per-request image ceiling is applied *after* trimming, walking newest first, so the
    /// newest images are the ones a client loads without being asked. `omitted` bounds automatic
    /// loading, not availability: the id stays valid, and a client may still fetch it on demand.
    static func applyImageBudget(to messages: [Message]) -> [Message] {
        var remaining = imagesPerRequestLimit
        var result = messages
        for index in result.indices.reversed() {
            guard !result[index].images.isEmpty else { continue }
            for imageIndex in result[index].images.indices where result[index].images[imageIndex].status == .ok {
                if remaining > 0 {
                    remaining -= 1
                } else {
                    result[index].images[imageIndex].status = .omitted
                    result[index].images[imageIndex].note = "Not loaded automatically — this view reached its image limit."
                }
            }
        }
        return result
    }

    private static func wireMessage(from entry: [String: PiJSONValue], ordinal: Int) -> Message? {
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
            return Message(
                id: id, role: role, text: text, at: at, isError: isError,
                images: imageRefs(in: message, ordinal: ordinal),
                // Only an assistant turn's block order says something `text` cannot: which prose
                // is narration before a tool call and which is the answer after it.
                blocks: role == .assistant ? contentBlocks(from: message["content"]) : nil,
                toolCallId: message["toolCallId"]?.stringValue,
                toolName: message["toolName"]?.stringValue,
                stopReason: message["stopReason"]?.stringValue
            )
        case "compaction":
            return summaryMessage(id: id, title: "Context compacted", entry: entry, fallback: "Earlier context was compacted.")
        case "branch_summary":
            return summaryMessage(id: id, title: "Branch summary", entry: entry, fallback: "Branch context summary.")
        default:
            return nil
        }
    }

    /// Compaction and branch summaries keep their single flattened `text` for older clients, and
    /// split title from summary in `blocks` so a client can show the title and reveal the rest.
    private static func summaryMessage(id: String, title: String, entry: [String: PiJSONValue], fallback: String) -> Message {
        let summary = bounded(entry["summary"]?.stringValue ?? fallback, max: blockTextLimit)
        return Message(
            id: id,
            role: .system,
            text: "\(title): \(summary)",
            at: timestamp(from: entry["timestamp"]) ?? .distantPast,
            blocks: [MessageBlock(type: "text", text: title), MessageBlock(type: "text", text: summary)]
        )
    }

    /// Ordered structured blocks for one message's content, sharing a single text budget so a
    /// transcript carrying blocks stays the same order of magnitude as one carrying only `text`.
    /// Tool calls are always admitted even once the budget is spent — their identity is what lets
    /// a client attach results — but their arguments shrink with everything else.
    static func contentBlocks(from content: PiJSONValue?) -> [MessageBlock]? {
        guard let blocks = content?.arrayValue else { return nil }
        var budget = blockTextLimit
        var result: [MessageBlock] = []

        func take(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            let text = bounded(value, max: max(budget, 0))
            budget -= min(value.count, max(budget, 0))
            return text
        }

        for block in blocks.prefix(blocksPerMessageLimit) {
            switch block["type"]?.stringValue {
            case "text":
                if let text = take(block["text"]?.stringValue) { result.append(MessageBlock(type: "text", text: text)) }
            case "thinking":
                if let text = take(block["thinking"]?.stringValue) { result.append(MessageBlock(type: "thinking", text: text)) }
            case "toolCall":
                result.append(MessageBlock(
                    type: "toolCall",
                    callId: block["id"]?.stringValue,
                    name: block["name"]?.stringValue ?? "tool",
                    arguments: take(prettyJSON(block["arguments"]))
                ))
            case "image":
                // Bytes and placement already travel in `Message.images`; the block only marks
                // where the image sat relative to the prose around it.
                result.append(MessageBlock(type: "image"))
            case let other:
                result.append(MessageBlock(type: other ?? "unknown"))
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Display text for a tool call's arguments. Pretty-printed and key-sorted so the same call
    /// always reads the same way, and truncated by the caller's budget like any other block text.
    private static func prettyJSON(_ value: PiJSONValue?) -> String? {
        guard let value, value != .object([:]) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
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

    // MARK: - Inline images

    /// The two shapes Pi actually writes, matching the app's own transcript parser: a `content`
    /// block `{"type":"image","data":"<base64>","mimeType":…}` and an `attachments` entry
    /// `{"type":"image","content":"<base64>","mimeType":…}`. Only lengths are read here; the
    /// base64 itself is never retained, so a transcript scan stays flat in memory no matter how
    /// many screenshots a conversation contains.
    static func imageRefs(in message: PiJSONValue, ordinal: Int) -> [MessageImage] {
        var refs: [MessageImage] = []
        for (index, block) in (message["content"]?.arrayValue ?? []).enumerated() {
            guard block["type"]?.stringValue == "image" else { continue }
            guard refs.count < imagesPerMessageLimit else { break }
            refs.append(imageRef(id: "\(ordinal)-c\(index)", encoded: block["data"]?.stringValue, block: block))
        }
        for (index, block) in (message["attachments"]?.arrayValue ?? []).enumerated() {
            guard block["type"]?.stringValue == "image" else { continue }
            guard refs.count < imagesPerMessageLimit else { break }
            refs.append(imageRef(id: "\(ordinal)-a\(index)", encoded: block["content"]?.stringValue, block: block))
        }
        return refs
    }

    private static func imageRef(id: String, encoded: String?, block: PiJSONValue) -> MessageImage {
        let mimeType = block["mimeType"]?.stringValue ?? "image/png"
        let fileName = block["fileName"]?.stringValue.map { bounded($0, max: 200) }
        guard let encoded, !encoded.isEmpty else {
            return MessageImage(
                id: id, mimeType: mimeType, byteCount: 0, fileName: fileName,
                status: .invalid, note: "Image omitted because it was empty or unreadable."
            )
        }
        let byteCount = decodedByteEstimate(encodedLength: encoded.count)
        guard byteCount <= imageByteLimit else {
            return MessageImage(
                id: id, mimeType: mimeType, byteCount: byteCount, fileName: fileName,
                status: .tooLarge, note: "Image is too large to open remotely; view it on the Mac."
            )
        }
        // `ok` is a promise that fetching this id will return bytes. Validating the encoding here
        // — without allocating the decoded image — keeps that promise honest instead of handing a
        // client a thumbnail that can only ever fail to load.
        guard isWellFormedBase64(encoded) else {
            return MessageImage(
                id: id, mimeType: mimeType, byteCount: byteCount, fileName: fileName,
                status: .invalid, note: "Image omitted because it was empty or unreadable."
            )
        }
        return MessageImage(id: id, mimeType: mimeType, byteCount: byteCount, fileName: fileName)
    }

    /// Standard base64: a multiple of four characters from the base64 alphabet, with at most two
    /// `=` and only at the very end. One allocation-free pass, so validating every image in a
    /// transcript scan costs no memory beyond the string already decoded from the JSONL record.
    static func isWellFormedBase64(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count % 4 == 0 else { return false }
        var padding = 0
        for scalar in scalars {
            switch scalar {
            case "A"..<"[", "a"..<"{", "0"..<":", "+", "/":
                // A payload character after padding has started is malformed.
                if padding > 0 { return false }
            case "=":
                padding += 1
                if padding > 2 { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Decoded size of a base64 payload, ignoring padding subtleties (over-estimates by <=2 bytes).
    static func decodedByteEstimate(encodedLength: Int) -> Int { encodedLength / 4 * 3 }

    /// Reads exactly one image back out of the session file by the id `messages(at:limit:)`
    /// handed out. Stops scanning at the target record, and refuses anything that does not decode
    /// or exceeds `imageByteLimit`, so an unbounded or corrupt payload can never reach a response.
    public static func image(at url: URL, imageId: String) throws -> MessageImageResponse? {
        guard let target = ImageRef(id: imageId) else { return nil }
        var ordinal = 0
        var found: MessageImageResponse?

        do {
            try JSONLFileReader.read(url: url) { data in
                try Task.checkCancellation()
                let current = ordinal
                ordinal += 1
                guard current == target.ordinal else { return }
                found = decodedImage(from: data, target: target, imageId: imageId)
                // The record the id names has been handled either way; reading the rest of a
                // multi-megabyte session file would be pure waste.
                throw ScanFinished()
            }
        } catch is ScanFinished {
            // Expected early exit.
        }
        return found
    }

    private struct ScanFinished: Error {}

    private static func decodedImage(from data: Data, target: ImageRef, imageId: String) -> MessageImageResponse? {
        guard let value = try? PiJSONValue.decode(data), let message = value["message"],
              let blocks = (target.isAttachment ? message["attachments"] : message["content"])?.arrayValue,
              blocks.indices.contains(target.blockIndex) else { return nil }
        let block = blocks[target.blockIndex]
        guard block["type"]?.stringValue == "image",
              let encoded = (target.isAttachment ? block["content"] : block["data"])?.stringValue,
              !encoded.isEmpty,
              decodedByteEstimate(encodedLength: encoded.count) <= imageByteLimit,
              let decoded = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !decoded.isEmpty, decoded.count <= imageByteLimit else { return nil }
        return MessageImageResponse(
            id: imageId,
            mimeType: block["mimeType"]?.stringValue ?? "image/png",
            byteCount: decoded.count,
            fileName: block["fileName"]?.stringValue.map { bounded($0, max: 200) },
            data: decoded.base64EncodedString()
        )
    }

    /// `"<entryOrdinal>-c<blockIndex>"` (a `content` block) or `"<entryOrdinal>-a<blockIndex>"`
    /// (an `attachments` entry). Ordinals are JSONL record positions, and Pi only ever appends,
    /// so an id stays valid for the life of the session file.
    struct ImageRef {
        let ordinal: Int
        let isAttachment: Bool
        let blockIndex: Int

        init?(id: String) {
            let parts = id.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let ordinal = Int(parts[0]), ordinal >= 0 else { return nil }
            let tail = parts[1]
            guard let marker = tail.first, marker == "c" || marker == "a",
                  let blockIndex = Int(tail.dropFirst()), blockIndex >= 0 else { return nil }
            self.ordinal = ordinal
            isAttachment = marker == "a"
            self.blockIndex = blockIndex
        }
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
