import Foundation

/// Reads a Pi session JSONL into the control API's bounded wire shapes. This stays smaller than
/// the app's full `SessionParser` (`Sources/Patchwork/SessionParser.swift`): it carries only what
/// remote clients render, not active-branch reconstruction or native image payloads. Where the two
/// overlap in spirit (title/preview heuristics) this follows the wire contract, since the app's
/// sidebar preview is the first user prompt while `docs/daemon-api.md` defines `Thread.preview` as
/// the first line of the last assistant message.
public enum SessionThreadParser {
    public static let previewLimit = 160
    public static let titleLimit = 74
    /// Per-block text bound so one huge message cannot make a summary scan retain unbounded text.
    static let blockTextLimit = 4_000
    /// Ceiling on structured blocks projected for one message. Order past this is lost, but the
    /// message itself (and its flattened `text`) is not.
    static let blocksPerMessageLimit = 40
    /// IDs, names, reasons, and future block kinds are structural metadata, not payload text.
    static let blockMetadataLimit = 256
    /// Read recent messages from EOF first. Pathological tails fall back to the full scanner once
    /// this bounded window is exhausted, so speed never comes at the cost of missing history.
    static let initialTailBytes = 4 * 1_024 * 1_024
    static let maxTailBytes = 64 * 1_024 * 1_024
    /// Enough for eight maximum-sized remote images in one JSONL record, while still bounded.
    static let maxImageRecordBytes = 32 * 1_024 * 1_024

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

    public enum ParseError: Error {
        case notASession
        /// A subagent transcript (Codex marks its rollouts `"subsession": true`). Parseable, but
        /// a tool's working notes rather than one of the user's threads.
        case subsession
    }

    /// Single forward pass: every retained value is a scalar accumulator, so memory use does not
    /// grow with session size regardless of how many entries the file contains.
    ///
    /// `transcoder` rewrites one foreign record into the Pi shape before it is read, exactly as
    /// the app's own `SessionParser.summary(at:archivedIDs:transcoder:)` does; `.pi` is identity.
    /// ponytail: `transcoder.chain` is not consulted here because this parser has no parent walk
    /// at all — it reads every record in file order — so `.linear` and `.parentPointer` already
    /// produce the same projection. If a branch-aware summary is ever needed, that is where the
    /// chain style comes in.
    public static func thread(at url: URL, transcoder: AgentSessionTranscoder = .pi) throws -> PatchworkThread {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var sawSessionRecord = false
        var isSubsession = false
        var cwd = url.deletingLastPathComponent()
        var createdAt: Date?
        var explicitName: String?
        var firstUserText: String?
        var lastAssistantText: String?
        var messageCount = 0
        var cost = 0.0
        var sawAnyEntry = false

        try JSONLFileReader.read(url: url) { rawRecord in
            try Task.checkCancellation()
            guard let data = transcoder.transcode(rawRecord) else { return }
            guard let value = try? PiJSONValue.decode(data), let object = value.objectValue else { return }
            let type = object["type"]?.stringValue ?? "unknown"
            sawAnyEntry = true

            // Agents without a session header record (Claude) repeat `cwd`/`sessionId` on every
            // conversation entry, and name a thread with an id-less `session_info`. Both are read
            // before the switch so neither is lost.
            if !sawSessionRecord, type != "session" {
                if let path = object["cwd"]?.stringValue, !path.isEmpty { cwd = URL(fileURLWithPath: path) }
                if let session = object["sessionId"]?.stringValue, !session.isEmpty { sessionID = session }
            }

            switch type {
            case "session":
                sawSessionRecord = true
                sessionID = object["id"]?.stringValue ?? sessionID
                if let path = object["cwd"]?.stringValue, !path.isEmpty { cwd = URL(fileURLWithPath: path) }
                if object["subsession"]?.boolValue == true { isSubsession = true }
                createdAt = object["timestamp"]?.stringValue.flatMap(PatchworkDate.date(from:))
            case "session_info":
                if let name = object["name"]?.stringValue, !name.isEmpty { explicitName = name }
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
        guard !isSubsession else { throw ParseError.subsession }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modifiedAt = resourceValues?.contentModificationDate ?? createdAt ?? .distantPast
        let creation = createdAt ?? resourceValues?.creationDate ?? modifiedAt
        let standardizedURL = url.standardizedFileURL
        let standardizedCwd = cwd.standardizedFileURL
        let folder = standardizedCwd.lastPathComponent.isEmpty ? standardizedCwd.path : standardizedCwd.lastPathComponent

        let title = explicitName?.condensedPatchwork.nonEmptyPatchwork
            ?? firstUserText?.headlinePatchwork(max: titleLimit)
            ?? "Untitled conversation"
        // Per the doc: the last assistant line, not the app's "first user prompt" sidebar preview.
        let preview = lastAssistantText?.headlinePatchwork(max: previewLimit)
            ?? firstUserText?.headlinePatchwork(max: previewLimit)
            ?? ""

        return PatchworkThread(
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
            // Overlaid by the caller, which knows which root the file came from.
            agent: .pi,
            cost: messageCount > 0 ? cost : nil,
            // Only known live, from `get_session_stats`; a static file scan cannot recover it.
            contextPercent: nil
        )
    }

    /// The last `limit` messages in file order. Reads backward from EOF so opening a 120 MB
    /// conversation costs roughly the size of its visible tail, not the size of its history.
    public static func messages(
        at url: URL, limit: Int, transcoder: AgentSessionTranscoder = .pi
    ) throws -> [Message] {
        try messagePage(at: url, limit: limit, offset: 0, conversationOnly: false, transcoder: transcoder).messages
    }

    /// A bounded page from newest toward oldest. `offset` counts messages after applying the role
    /// filter, so an agent can page through dialogue without tool results shifting every page.
    public static func messagePage(
        at url: URL, limit: Int, offset: Int, conversationOnly: Bool,
        transcoder: AgentSessionTranscoder = .pi
    ) throws -> (messages: [Message], nextOffset: Int?) {
        guard limit > 0, offset >= 0 else { return ([], nil) }
        let pageLimit = min(limit, 500)
        let pageOffset = min(offset, 5_000)
        let target = pageLimit + pageOffset + 1
        let retained = try tailMessages(at: url, limit: target, conversationOnly: conversationOnly, transcoder: transcoder)
            ?? forwardMessages(at: url, limit: target, conversationOnly: conversationOnly, transcoder: transcoder)
        let hasMore = retained.count == target
        let withoutNewer = retained.dropLast(min(pageOffset, retained.count))
        let page = applyImageBudget(to: Array(withoutNewer.suffix(pageLimit)))
        return (page, hasMore ? pageOffset + page.count : nil)
    }

    /// `nil` means the bounded reverse window did not contain enough complete records, so the
    /// caller must use the slower full scan rather than silently return incomplete history.
    static func tailMessages(at url: URL, limit: Int, transcoder: AgentSessionTranscoder = .pi) throws -> [Message]? {
        try tailMessages(at: url, limit: limit, conversationOnly: false, transcoder: transcoder)
    }

    private static func tailMessages(
        at url: URL, limit: Int, conversationOnly: Bool, transcoder: AgentSessionTranscoder
    ) throws -> [Message]? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var window = min(end, UInt64(initialTailBytes))

        while true {
            try Task.checkCancellation()
            let start = end - window
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(window)) ?? Data()
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            var messages: [Message] = []
            messages.reserveCapacity(min(limit, 512))

            for line in lines.dropFirst(start > 0 ? 1 : 0).reversed() where !line.isEmpty {
                try Task.checkCancellation()
                var record = Data(line)
                if record.last == 0x0D { record.removeLast() }
                // The offset is into the *raw* file, so an image id minted here still addresses
                // the untranscoded record `image(at:imageId:)` will seek back to.
                let offset = start + UInt64(line.startIndex)
                guard let transcoded = transcoder.transcode(record),
                      let value = try? PiJSONValue.decode(transcoded), let object = value.objectValue,
                      let message = wireMessage(from: object, locator: .offset(offset)),
                      !conversationOnly || message.role == .user || message.role == .assistant else { continue }
                messages.append(message)
                if messages.count == limit { return Array(messages.reversed()) }
            }

            if start == 0 { return Array(messages.reversed()) }
            let ceiling = min(end, UInt64(maxTailBytes))
            guard window < ceiling else { return nil }
            window = min(ceiling, window * 2)
        }
    }

    private static func forwardMessages(
        at url: URL, limit: Int, conversationOnly: Bool, transcoder: AgentSessionTranscoder
    ) throws -> [Message] {
        var buffer: [Message] = []
        buffer.reserveCapacity(min(limit, 512))
        var ordinal = 0
        try JSONLFileReader.read(url: url) { rawRecord in
            try Task.checkCancellation()
            // Counted over raw records, including any the transcoder drops, so a legacy ordinal
            // image id resolves to the same record from both directions.
            let entryOrdinal = ordinal
            ordinal += 1
            guard let data = transcoder.transcode(rawRecord),
                  let value = try? PiJSONValue.decode(data), let object = value.objectValue,
                  let message = wireMessage(from: object, locator: .ordinal(entryOrdinal)),
                  !conversationOnly || message.role == .user || message.role == .assistant else { return }
            buffer.append(message)
            if buffer.count > limit * 2 { buffer.removeFirst(buffer.count - limit) }
        }
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        return buffer
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

    private enum RecordLocator {
        case ordinal(Int)
        case offset(UInt64)

        var imageIDPrefix: String {
            switch self {
            case let .ordinal(value): String(value)
            case let .offset(value): "b\(value)"
            }
        }
    }

    private static func wireMessage(from entry: [String: PiJSONValue], locator: RecordLocator) -> Message? {
        let type = entry["type"]?.stringValue ?? "unknown"
        let id = entry["id"]?.stringValue ?? UUID().uuidString

        switch type {
        case "message":
            guard let message = entry["message"] else { return nil }
            let roleName = boundedMetadata(message["role"]?.stringValue) ?? "unknown"
            // "toolResult" is the closest of the four wire roles to a shell result.
            let role = roleName == "bashExecution" ? MessageRole.toolResult : MessageRole(rawValue: roleName)
            let text = plainText(from: message["content"]) ?? ""
            let isError = message["isError"]?.boolValue ?? (message["stopReason"]?.stringValue == "error")
            let at = timestamp(from: message["timestamp"]) ?? .distantPast
            return Message(
                id: id, role: role, text: text, at: at, isError: isError,
                images: imageRefs(in: message, locator: locator),
                // Only an assistant turn's block order says something `text` cannot: which prose
                // is narration before a tool call and which is the answer after it.
                blocks: role == .assistant ? contentBlocks(from: message["content"]) : nil,
                toolCallId: boundedMetadata(message["toolCallId"]?.stringValue),
                toolName: boundedMetadata(message["toolName"]?.stringValue),
                stopReason: boundedMetadata(message["stopReason"]?.stringValue)
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
        let summary = bounded(
            entry["summary"]?.stringValue ?? fallback,
            max: blockTextLimit - title.count
        )
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
            guard let value, !value.isEmpty, budget > 0 else { return nil }
            let text = bounded(value, max: budget)
            budget -= text.count
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
                    callId: boundedMetadata(block["id"]?.stringValue),
                    name: boundedMetadata(block["name"]?.stringValue) ?? "tool",
                    arguments: take(prettyJSON(block["arguments"]))
                ))
            case "image":
                // Bytes and placement already travel in `Message.images`; the block only marks
                // where the image sat relative to the prose around it.
                result.append(MessageBlock(type: "image"))
            case let other:
                result.append(MessageBlock(type: boundedMetadata(other) ?? "unknown"))
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
        return value?.stringValue.flatMap(PatchworkDate.date(from:))
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
    private static func imageRefs(in message: PiJSONValue, locator: RecordLocator) -> [MessageImage] {
        var refs: [MessageImage] = []
        let prefix = locator.imageIDPrefix
        for (index, block) in (message["content"]?.arrayValue ?? []).enumerated() {
            guard block["type"]?.stringValue == "image" else { continue }
            guard refs.count < imagesPerMessageLimit else { break }
            refs.append(imageRef(id: "\(prefix)-c\(index)", encoded: block["data"]?.stringValue, block: block))
        }
        for (index, block) in (message["attachments"]?.arrayValue ?? []).enumerated() {
            guard block["type"]?.stringValue == "image" else { continue }
            guard refs.count < imagesPerMessageLimit else { break }
            refs.append(imageRef(id: "\(prefix)-a\(index)", encoded: block["content"]?.stringValue, block: block))
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
    /// handed out. New byte-offset ids seek directly to the record; legacy ordinal ids still scan
    /// forward, so an in-memory older client survives a daemon upgrade.
    public static func image(
        at url: URL, imageId: String, transcoder: AgentSessionTranscoder = .pi
    ) throws -> MessageImageResponse? {
        guard let target = ImageRef(id: imageId) else { return nil }
        switch target.location {
        case let .offset(offset):
            guard let raw = try record(at: offset, in: url), let data = transcoder.transcode(raw) else { return nil }
            return decodedImage(from: data, target: target, imageId: imageId)
        case let .ordinal(targetOrdinal):
            var ordinal = 0
            var found: MessageImageResponse?
            do {
                try JSONLFileReader.read(url: url) { rawRecord in
                    try Task.checkCancellation()
                    let current = ordinal
                    ordinal += 1
                    guard current == targetOrdinal else { return }
                    if let data = transcoder.transcode(rawRecord) {
                        found = decodedImage(from: data, target: target, imageId: imageId)
                    }
                    throw ScanFinished()
                }
            } catch is ScanFinished {
                // Expected early exit.
            }
            return found
        }
    }

    private static func record(at offset: UInt64, in url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard offset < end else { return nil }
        try handle.seek(toOffset: offset)

        var record = Data()
        while record.count < maxImageRecordBytes {
            try Task.checkCancellation()
            let remaining = min(256 * 1_024, maxImageRecordBytes - record.count)
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                record.append(chunk[..<newline])
                if record.last == 0x0D { record.removeLast() }
                return record.isEmpty ? nil : record
            }
            record.append(chunk)
        }
        return record.isEmpty || record.count == maxImageRecordBytes ? nil : record
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

    /// `"b<byteOffset>-c<blockIndex>"` for new tail projections; the old
    /// `"<entryOrdinal>-c<blockIndex>"` form remains accepted for compatibility. `a` replaces
    /// `c` for an attachment.
    struct ImageRef {
        enum Location { case ordinal(Int), offset(UInt64) }

        let location: Location
        let isAttachment: Bool
        let blockIndex: Int

        init?(id: String) {
            let parts = id.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            if parts[0].first == "b", let offset = UInt64(parts[0].dropFirst()) {
                location = .offset(offset)
            } else if let ordinal = Int(parts[0]), ordinal >= 0 {
                location = .ordinal(ordinal)
            } else {
                return nil
            }
            let tail = parts[1]
            guard let marker = tail.first, marker == "c" || marker == "a",
                  let blockIndex = Int(tail.dropFirst()), blockIndex >= 0 else { return nil }
            isAttachment = marker == "a"
            self.blockIndex = blockIndex
        }
    }

    private static func boundedMetadata(_ value: String?) -> String? {
        value.map { bounded($0, max: blockMetadataLimit) }
    }

    /// Includes the ellipsis in `max`; every caller can rely on the declared ceiling exactly.
    private static func bounded(_ value: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard value.count > max else { return value }
        guard max > 1 else { return "\u{2026}" }
        return String(value.prefix(max - 1)) + "\u{2026}"
    }
}

private extension String {
    var condensedPatchwork: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmptyPatchwork: String? { isEmpty ? nil : self }

    func headlinePatchwork(max length: Int) -> String {
        let condensed = condensedPatchwork
        guard condensed.count > length else { return condensed }
        return String(condensed.prefix(length - 1)) + "\u{2026}"
    }
}
