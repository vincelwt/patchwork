import Foundation

struct ConversationPageCursor: Hashable, Sendable {
    fileprivate let sourcePath: String
    fileprivate let beforeOffset: UInt64
    fileprivate let expectedID: String?
    fileprivate let leafID: String?
}

struct ConversationPage: Sendable {
    static let defaultMessageTarget = 50

    let messages: [ChatMessage]
    let olderCursor: ConversationPageCursor?
    let leafID: String?
    /// Active-branch JSONL entries traversed while producing this page, including entries that
    /// intentionally do not render (for example model changes).
    let rawEntryCount: Int
    /// Complete JSONL records inspected, including abandoned branches and malformed records.
    let scannedEntryCount: Int
    /// File bytes read for this page. This never exceeds `SessionParser.PageLimits.maxScanBytes`.
    let scannedByteCount: Int
    /// True when a byte, entry, or single-record cap stopped the scan. A non-nil cursor means the
    /// bounded scan can continue; nil means an oversized/unrecoverable record blocked it.
    let isTruncated: Bool

    var hasMoreHistory: Bool { olderCursor != nil }
    var hasNoMoreHistory: Bool { olderCursor == nil && !isTruncated }
}

enum ConversationPagingError: Error {
    case invalidCursor
    case unsupported
}

struct SessionParser {
    private struct EntryHeader: Decodable {
        let type: String?
        let id: String?
        let parentId: String?
    }

    private struct MinimalEntry {
        let id: String
        let parentID: String?
        let type: String
        let userText: String?
    }

    /// A transient view of one active entry. It is projected and released inside the pass-two
    /// record callback; no `[RawEntry]` array is ever accumulated.
    private struct RawEntry {
        let id: String
        let type: String
        let raw: JSONValue
    }

    static func summary(at url: URL, archivedIDs: Set<String> = []) throws -> SessionSummary {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = url.deletingLastPathComponent()
        var createdAt: Date?
        var explicitName: String?
        var entries: [String: MinimalEntry] = [:]
        var lastEntryID: String?
        var messageCount = 0
        var model: String?
        var provider: String?
        var thinkingLevel: String?
        var metrics = TokenMetrics()

        try JSONLFileReader.read(url: url) { data in
            try Task.checkCancellation()
            guard let raw = try? JSONValue.decode(data), let object = raw.objectValue else { return }
            let type = object["type"]?.stringValue ?? "unknown"

            if type == "session" {
                sessionID = object["id"]?.stringValue ?? sessionID
                if let path = object["cwd"]?.stringValue { cwd = URL(fileURLWithPath: path) }
                createdAt = Date.piDate(object["timestamp"]?.stringValue)
                return
            }

            guard let id = object["id"]?.stringValue else { return }
            let parentID = object["parentId"]?.stringValue
            lastEntryID = id
            var userText: String?

            switch type {
            case "session_info":
                explicitName = object["name"]?.stringValue
            case "model_change":
                provider = object["provider"]?.stringValue ?? provider
                model = object["modelId"]?.stringValue ?? model
            case "thinking_level_change":
                thinkingLevel = object["thinkingLevel"]?.stringValue ?? thinkingLevel
            case "message":
                messageCount += 1
                if let message = object["message"] {
                    let role = message["role"]?.stringValue
                    if role == "user" { userText = extractText(from: message["content"]) }
                    if role == "assistant" {
                        model = message["model"]?.stringValue ?? model
                        provider = message["provider"]?.stringValue ?? provider
                    }
                    metrics.addUsage(message["usage"])
                }
            case "compaction", "branch_summary":
                metrics.addUsage(raw["usage"])
            default:
                break
            }

            entries[id] = MinimalEntry(id: id, parentID: parentID, type: type, userText: userText)
        }

        var activePath: [MinimalEntry] = []
        var cursor = lastEntryID
        var visited: Set<String> = []
        while let id = cursor, !visited.contains(id), let entry = entries[id] {
            visited.insert(id)
            activePath.append(entry)
            cursor = entry.parentID
        }
        activePath.reverse()

        let firstPrompt = activePath.compactMap(\.userText).first?.condensed
        let title = explicitName?.condensed.nonEmpty ?? firstPrompt?.headline(max: 74) ?? "Untitled conversation"
        // Previews are retained for every discovered session, so they stay bounded while
        // remaining long enough for sidebar search to be useful.
        let preview = (firstPrompt?.headline(max: PiTheme.sessionPreviewLimit)) ?? "No user message yet"
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modifiedAt = values?.contentModificationDate ?? createdAt ?? .distantPast
        let creation = createdAt ?? values?.creationDate ?? modifiedAt

        var summary = SessionSummary(
            id: sessionID,
            fileURL: url.standardizedFileURL,
            cwd: cwd.standardizedFileURL,
            createdAt: creation,
            modifiedAt: modifiedAt,
            name: title,
            preview: preview,
            messageCount: messageCount,
            model: model,
            provider: provider,
            thinkingLevel: thinkingLevel,
            metrics: metrics,
            isArchived: archivedIDs.contains(sessionID)
        )
        summary.prepareSearchKey()
        return summary
    }

    /// Two-pass projection: pass one retains only id/parent/type, then pass two decodes
    /// full JSON exclusively for entries on the final active parent chain.
    static func conversation(at url: URL) throws -> SessionConversation {
        var parents: [String: String?] = [:]
        var lastEntryID: String?
        var rawEntryCount = 0
        let decoder = JSONDecoder()

        try JSONLFileReader.read(url: url) { data in
            try Task.checkCancellation()
            guard let header = try? decoder.decode(EntryHeader.self, from: data),
                  header.type != "session", let id = header.id else { return }
            parents[id] = header.parentId
            lastEntryID = id
            rawEntryCount += 1
        }

        var activeIDs: Set<String> = []
        var cursor = lastEntryID
        while let id = cursor, activeIDs.insert(id).inserted {
            cursor = parents[id] ?? nil
        }
        parents.removeAll(keepingCapacity: false)
        try Task.checkCancellation()

        // Pass two projects each active entry immediately and releases its raw JSON before
        // reading the next record, so the whole active branch's raw/base64 payloads are never
        // resident at the same time.
        var messages: [ChatMessage] = []
        messages.reserveCapacity(activeIDs.count)
        var budget = ImageBudget()
        try JSONLFileReader.read(url: url) { data in
            try Task.checkCancellation()
            guard let header = try? decoder.decode(EntryHeader.self, from: data),
                  let id = header.id, activeIDs.contains(id), header.type != "session" else { return }
            autoreleasepool {
                guard let raw = try? JSONValue.decode(data) else { return }
                let entry = RawEntry(id: id, type: header.type ?? "unknown", raw: raw)
                if let message = chatMessage(from: entry, budget: &budget) { messages.append(message) }
            }
        }

        return SessionConversation(messages: messages, leafID: lastEntryID, rawEntryCount: rawEntryCount)
    }

    /// Bytes read backward from EOF for the tail-first preview (Task 1). Large enough that a
    /// realistic tail of `AppStore`'s preview limit almost always resolves from one window,
    /// small enough that even a 25 MB session only ever pays for a few MB of it.
    static let tailScanWindowBytes = 4 * 1_024 * 1_024

    struct TailScan {
        let conversation: SessionConversation
        /// True once the backward walk reached the conversation's root: the tail *is* the whole
        /// active conversation, so no further full parse is needed to "fill in the rest".
        let isComplete: Bool
    }

    /// Reconstructs just the tail of the active conversation without reading the rest of the
    /// file, so a cache miss can paint something at the bottom before the full two-pass parse
    /// (which must still touch the whole file) finishes. Reads up to one fixed byte budget from
    /// EOF, then walks the real parent-pointer chain backward exactly like `conversation
    /// (at:)` walks it forward: a line only counts if it is genuinely on the active path, so an
    /// abandoned branch physically adjacent to the tail (left behind by an earlier edit) is
    /// skipped rather than mistaken for recent history.
    ///
    /// The window may cut a large abandoned branch short without ever reaching the root; when
    /// that happens `isComplete` is false and the caller is expected to follow up with a full
    /// `conversation(at:)` parse. Images decode against a budget scoped to just this preview, so
    /// on an image-heavy conversation whose earlier images would have exhausted the aggregate
    /// budget, an image shown here can be replaced by a placeholder once that full parse lands —
    /// an accepted, self-correcting tradeoff for painting instantly.
    /// `windowBytes` defaults to `tailScanWindowBytes`; tests inject a tiny window instead of
    /// allocating real megabytes to exercise truncation deterministically.
    static func conversationTail(at url: URL, limit: Int, windowBytes: Int = SessionParser.tailScanWindowBytes) throws -> TailScan {
        let limits = PageLimits(
            maxScanBytes: windowBytes,
            maxEntries: PageLimits.default.maxEntries,
            maxRecordBytes: min(windowBytes, PageLimits.default.maxRecordBytes),
            chunkBytes: min(windowBytes, PageLimits.default.chunkBytes)
        )
        let page = try conversationPage(at: url, target: limit, limits: limits)
        return TailScan(
            conversation: SessionConversation(messages: page.messages, leafID: page.leafID, rawEntryCount: page.rawEntryCount),
            isComplete: page.hasNoMoreHistory
        )
    }

    struct PageLimits: Sendable {
        static let `default` = PageLimits(
            maxScanBytes: 64 * 1_024 * 1_024,
            maxEntries: 20_000,
            maxRecordBytes: 32 * 1_024 * 1_024,
            chunkBytes: 256 * 1_024
        )

        let maxScanBytes: Int
        let maxEntries: Int
        let maxRecordBytes: Int
        let chunkBytes: Int

        init(maxScanBytes: Int, maxEntries: Int, maxRecordBytes: Int, chunkBytes: Int) {
            self.maxScanBytes = max(1, maxScanBytes)
            self.maxEntries = max(1, maxEntries)
            self.maxRecordBytes = max(1, min(maxRecordBytes, maxScanBytes))
            self.chunkBytes = max(1, min(chunkBytes, maxScanBytes))
        }
    }

    /// Reads one active-branch page backward from JSONL record boundaries. Raw records are
    /// projected one at a time and released; the reverse reader retains at most one bounded
    /// record plus one bounded I/O chunk.
    static func conversationPage(
        at url: URL,
        cursor: ConversationPageCursor? = nil,
        target: Int = ConversationPage.defaultMessageTarget,
        limits: PageLimits = .default
    ) throws -> ConversationPage {
        let sourcePath = url.standardizedFileURL.path
        if let cursor, cursor.sourcePath != sourcePath { throw ConversationPagingError.invalidCursor }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let scanEnd = cursor?.beforeOffset ?? fileSize
        guard scanEnd <= fileSize else { throw ConversationPagingError.invalidCursor }

        var reader = BackwardJSONLReader(handle: handle, endOffset: scanEnd, limits: limits)
        let decoder = JSONDecoder()
        var expectedID = cursor?.expectedID
        var leafID = cursor?.leafID
        var collected: [ChatMessage] = []
        var budget = ImageBudget()
        var rawEntryCount = 0
        var scannedEntryCount = 0
        var oldestScannedOffset: UInt64?

        func result(olderCursor: ConversationPageCursor?, truncated: Bool) -> ConversationPage {
            ConversationPage(
                messages: Array(collected.reversed()),
                olderCursor: olderCursor,
                leafID: leafID,
                rawEntryCount: rawEntryCount,
                scannedEntryCount: scannedEntryCount,
                scannedByteCount: reader.bytesRead,
                isTruncated: truncated
            )
        }

        func continuation(before offset: UInt64) -> ConversationPageCursor? {
            guard offset > 0, expectedID != nil || leafID == nil else { return nil }
            return ConversationPageCursor(
                sourcePath: sourcePath,
                beforeOffset: offset,
                expectedID: expectedID,
                leafID: leafID
            )
        }

        while scannedEntryCount < limits.maxEntries {
            try Task.checkCancellation()
            switch try reader.next() {
            case let .record(record):
                scannedEntryCount += 1
                oldestScannedOffset = record.startOffset
                guard !record.isOversized else { return result(olderCursor: nil, truncated: true) }
                guard !record.data.isEmpty,
                      let header = try? decoder.decode(EntryHeader.self, from: record.data),
                      header.type != "session", let id = header.id else { continue }

                if let expectedID {
                    guard id == expectedID else { continue }
                } else {
                    leafID = id
                }

                rawEntryCount += 1
                autoreleasepool {
                    guard let raw = try? JSONValue.decode(record.data) else { return }
                    let entry = RawEntry(id: id, type: header.type ?? "unknown", raw: raw)
                    if let message = chatMessage(from: entry, budget: &budget) { collected.append(message) }
                }
                expectedID = header.parentId

                if expectedID == nil { return result(olderCursor: nil, truncated: false) }
                if collected.count >= max(1, target) {
                    return result(olderCursor: continuation(before: record.startOffset), truncated: false)
                }

            case .limitReached:
                guard let offset = oldestScannedOffset, let older = continuation(before: offset) else {
                    return result(olderCursor: nil, truncated: true)
                }
                return result(olderCursor: older, truncated: true)

            case .startReached:
                return result(olderCursor: nil, truncated: false)
            }
        }

        guard let offset = oldestScannedOffset, let older = continuation(before: offset) else {
            return result(olderCursor: nil, truncated: true)
        }
        return result(olderCursor: older, truncated: true)
    }

    private struct BackwardRecord {
        let data: Data
        let startOffset: UInt64
        let isOversized: Bool
    }

    private enum BackwardRead {
        case record(BackwardRecord)
        case limitReached
        case startReached
    }

    /// Chunked reverse reader. `fragments` only holds the one line crossing chunk boundaries;
    /// complete lines wait in `pending` for immediate projection and are bounded by one chunk.
    private struct BackwardJSONLReader {
        let handle: FileHandle
        let limits: PageLimits
        var position: UInt64
        var bytesRead = 0
        var sawRightDelimiter = false
        var fragments: [Data] = []
        var fragmentBytes = 0
        var fragmentIsOversized = false
        var pending: [BackwardRecord] = []
        var pendingIndex = 0
        var finished = false

        init(handle: FileHandle, endOffset: UInt64, limits: PageLimits) {
            self.handle = handle
            self.position = endOffset
            self.limits = limits
        }

        mutating func next() throws -> BackwardRead {
            while true {
                if pendingIndex < pending.count {
                    defer { pendingIndex += 1 }
                    return .record(pending[pendingIndex])
                }
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
                if finished || position == 0 { return .startReached }
                guard bytesRead < limits.maxScanBytes else { return .limitReached }

                let count = min(limits.chunkBytes, limits.maxScanBytes - bytesRead, Int(position))
                let start = position - UInt64(count)
                try handle.seek(toOffset: start)
                let chunk = try handle.read(upToCount: count) ?? Data()
                guard chunk.count == count else { return .limitReached }
                bytesRead += chunk.count
                position = start
                process(chunk, at: start)

                if start == 0 {
                    if sawRightDelimiter {
                        let record = makeRecord(prefix: Data(), startOffset: 0)
                        pending.append(record)
                    } else {
                        resetFragments() // The whole file is an unterminated record: ignore it.
                    }
                    finished = true
                }
            }
        }

        private mutating func process(_ chunk: Data, at chunkOffset: UInt64) {
            var upper = chunk.endIndex
            var index = chunk.endIndex
            while index > chunk.startIndex {
                index = chunk.index(before: index)
                guard chunk[index] == 0x0A else { continue }
                let afterNewline = chunk.index(after: index)
                let part = chunk[afterNewline..<upper]
                let startOffset = chunkOffset + UInt64(afterNewline - chunk.startIndex)
                if sawRightDelimiter {
                    let record = makeRecord(prefix: part, startOffset: startOffset)
                    pending.append(record)
                } else {
                    // Bytes after the file's last LF are a torn record and remain invisible until
                    // a later retry sees their terminating LF.
                    sawRightDelimiter = true
                    resetFragments()
                }
                upper = index
            }
            appendFragment(chunk[chunk.startIndex..<upper])
        }

        private mutating func appendFragment(_ fragment: Data.SubSequence) {
            guard !fragment.isEmpty, !fragmentIsOversized else { return }
            guard fragmentBytes + fragment.count <= limits.maxRecordBytes else {
                fragments.removeAll(keepingCapacity: false)
                fragmentBytes = 0
                fragmentIsOversized = true
                return
            }
            fragments.append(Data(fragment))
            fragmentBytes += fragment.count
        }

        private mutating func makeRecord(prefix: Data.SubSequence, startOffset: UInt64) -> BackwardRecord {
            let oversized = fragmentIsOversized || prefix.count + fragmentBytes > limits.maxRecordBytes
            var data = Data()
            if !oversized {
                data.reserveCapacity(prefix.count + fragmentBytes)
                data.append(contentsOf: prefix)
                for fragment in fragments.reversed() { data.append(fragment) }
                if data.last == 0x0D { data.removeLast() }
            }
            resetFragments()
            return BackwardRecord(data: data, startOffset: startOffset, isOversized: oversized)
        }

        private mutating func resetFragments() {
            fragments.removeAll(keepingCapacity: false)
            fragmentBytes = 0
            fragmentIsOversized = false
        }
    }

    static func chatMessages(fromRPCMessages value: JSONValue?) -> [ChatMessage] {
        // One shared budget across the whole hydration, not per message.
        var budget = ImageBudget()
        return (value?.arrayValue ?? []).enumerated().compactMap { index, message in
            chatMessage(
                fromAgentMessage: message,
                id: "rpc-\(index)-\(message["timestamp"]?.intValue ?? index)",
                budget: &budget
            )
        }
    }

    /// Convenience for single live events (streaming updates), which get their own budget.
    static func chatMessage(fromAgentMessage message: JSONValue, id: String? = nil) -> ChatMessage? {
        var budget = ImageBudget()
        return chatMessage(fromAgentMessage: message, id: id, budget: &budget)
    }

    static func chatMessage(fromAgentMessage message: JSONValue, id: String? = nil, budget: inout ImageBudget) -> ChatMessage? {
        guard let roleName = message["role"]?.stringValue else { return nil }
        let timestamp = date(from: message["timestamp"])
        let stableID = id ?? "rpc-\(roleName)-\(message["timestamp"]?.intValue ?? Int(Date().timeIntervalSince1970 * 1_000))"

        if roleName == "branchSummary" || roleName == "compactionSummary" {
            let title = roleName == "branchSummary" ? "Branch summary" : "Context compacted"
            let summary = message["summary"]?.stringValue ?? title
            return ChatMessage(
                id: stableID, role: .system,
                blocks: [
                    MessageBlock(id: "\(stableID)-title", kind: .text(title)),
                    MessageBlock(id: "\(stableID)-summary", kind: .text(summary))
                ],
                timestamp: timestamp,
                usage: message["usage"]?.boundedProjection(),
                raw: .null
            )
        }

        let role = MessageRole(rawValue: roleName) ?? .unknown
        if role == .bash {
            let command = message["command"]?.stringValue ?? "Shell command"
            let output = bounded(message["output"]?.stringValue ?? "", max: 80_000)
            return ChatMessage(
                id: stableID, role: .bash,
                blocks: [
                    MessageBlock(id: "\(stableID)-command", kind: .text("$ \(command)")),
                    MessageBlock(id: "\(stableID)-output", kind: .text(output))
                ],
                timestamp: timestamp,
                isError: (message["exitCode"]?.intValue ?? 0) != 0,
                raw: .null
            )
        }

        var blocks = contentBlocks(from: message["content"], baseID: stableID, budget: &budget)
        if let attachments = message["attachments"]?.arrayValue {
            blocks.append(contentsOf: attachmentBlocks(attachments, baseID: stableID, budget: &budget))
        }
        if let error = message["errorMessage"]?.stringValue,
           !blocks.contains(where: { if case .text = $0.kind { return true }; return false }) {
            blocks.append(MessageBlock(id: "\(stableID)-error", kind: .text(bounded(error, max: 8_000))))
        }
        return ChatMessage(
            id: stableID,
            role: role,
            blocks: blocks,
            timestamp: timestamp,
            toolCallID: message["toolCallId"]?.stringValue,
            toolName: message["toolName"]?.stringValue,
            isError: message["isError"]?.boolValue ?? (message["stopReason"]?.stringValue == "error"),
            customType: message["customType"]?.stringValue,
            details: message["details"]?.boundedProjection(),
            usage: message["usage"]?.boundedProjection(),
            modelName: message["model"]?.stringValue,
            raw: role == .unknown ? message.boundedFallback(maxLength: PiTheme.unknownPayloadLimit) : .null
        )
    }

    private static func chatMessage(from entry: RawEntry, budget: inout ImageBudget) -> ChatMessage? {
        switch entry.type {
        case "message":
            guard let message = entry.raw["message"] else { return nil }
            return chatMessage(fromAgentMessage: message, id: entry.id, budget: &budget)
        case "custom_message":
            return ChatMessage(
                id: entry.id,
                role: .custom,
                blocks: contentBlocks(from: entry.raw["content"], baseID: entry.id, budget: &budget),
                timestamp: Date.piDate(entry.raw["timestamp"]?.stringValue),
                customType: entry.raw["customType"]?.stringValue,
                details: entry.raw["details"]?.boundedProjection(),
                raw: .null
            )
        case "compaction":
            return systemMessage(id: entry.id, title: "Context compacted", text: entry.raw["summary"]?.stringValue ?? "Earlier context was compacted.", raw: entry.raw)
        case "branch_summary":
            return systemMessage(id: entry.id, title: "Branch summary", text: entry.raw["summary"]?.stringValue ?? "Branch context summary", raw: entry.raw)
        case "model_change", "thinking_level_change", "session_info", "label", "custom":
            return nil
        default:
            let fallback = entry.raw.boundedFallback(maxLength: PiTheme.unknownPayloadLimit)
            return ChatMessage(
                id: entry.id,
                role: .unknown,
                blocks: [MessageBlock(id: "\(entry.id)-unknown", kind: .unknown(type: entry.type, raw: fallback))],
                timestamp: Date.piDate(entry.raw["timestamp"]?.stringValue),
                raw: fallback
            )
        }
    }

    private static func systemMessage(id: String, title: String, text: String, raw: JSONValue) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .system,
            blocks: [
                MessageBlock(id: "\(id)-title", kind: .text(title)),
                MessageBlock(id: "\(id)-text", kind: .text(bounded(text, max: 80_000)))
            ],
            timestamp: Date.piDate(raw["timestamp"]?.stringValue),
            raw: .null
        )
    }

    static func contentBlocks(from content: JSONValue?, baseID: String) -> [MessageBlock] {
        var budget = ImageBudget()
        return contentBlocks(from: content, baseID: baseID, budget: &budget)
    }

    static func contentBlocks(from content: JSONValue?, baseID: String, budget: inout ImageBudget) -> [MessageBlock] {
        guard let content else { return [] }
        if let text = content.stringValue {
            return [MessageBlock(id: "\(baseID)-text-0", kind: .text(bounded(text, max: 160_000)))]
        }

        var admitted: [MessageBlock] = []
        for (index, raw) in (content.arrayValue ?? []).enumerated() {
            let type = raw["type"]?.stringValue ?? "unknown"
            let id = raw["id"]?.stringValue ?? "\(baseID)-\(type)-\(index)"
            switch type {
            case "text":
                admitted.append(MessageBlock(id: id, kind: .text(bounded(raw["text"]?.stringValue ?? "", max: 160_000))))
            case "thinking":
                admitted.append(MessageBlock(id: id, kind: .thinking(bounded(raw["thinking"]?.stringValue ?? "", max: 160_000))))
            case "image":
                admitted.append(imageBlock(
                    id: id,
                    encoded: raw["data"]?.stringValue,
                    mimeType: raw["mimeType"]?.stringValue ?? "image/png",
                    fileName: raw["fileName"]?.stringValue,
                    budget: &budget
                ))
            case "toolCall":
                let call = ToolCallPayload(
                    id: raw["id"]?.stringValue ?? id,
                    name: raw["name"]?.stringValue ?? "tool",
                    arguments: (raw["arguments"] ?? .object([:])).boundedProjection(stringLimit: 20_000, itemLimit: 100)
                )
                admitted.append(MessageBlock(id: id, kind: .toolCall(call)))
            default:
                admitted.append(MessageBlock(id: id, kind: .unknown(type: type, raw: raw.boundedFallback(maxLength: PiTheme.unknownPayloadLimit))))
            }
        }
        return admitted
    }

    private static func attachmentBlocks(_ attachments: [JSONValue], baseID: String, budget: inout ImageBudget) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        for (index, raw) in attachments.prefix(PiTheme.imageCountLimit).enumerated() {
            guard raw["type"]?.stringValue == "image" else { continue }
            let id = raw["id"]?.stringValue ?? "\(baseID)-attachment-\(index)"
            blocks.append(imageBlock(
                id: id,
                encoded: raw["content"]?.stringValue,
                mimeType: raw["mimeType"]?.stringValue ?? "image/png",
                fileName: raw["fileName"]?.stringValue,
                budget: &budget
            ))
        }
        return blocks
    }

    /// Consults the aggregate budget with the *encoded* length so oversized or excess images
    /// never reach `Data(base64Encoded:)`, and replaces them with an explicit placeholder.
    private static func imageBlock(
        id: String,
        encoded: String?,
        mimeType: String,
        fileName: String?,
        budget: inout ImageBudget
    ) -> MessageBlock {
        guard let encoded, !encoded.isEmpty else {
            return MessageBlock(id: id, kind: .unknown(type: "image", raw: .string(ImageBudget.invalidPlaceholder)))
        }
        let encodedLength = encoded.count
        guard budget.admitEncoded(length: encodedLength) else {
            let reason = encodedLength > PiTheme.imageByteLimit * 2
                ? ImageBudget.invalidPlaceholder
                : ImageBudget.omittedPlaceholder
            return MessageBlock(id: id, kind: .unknown(type: "image", raw: .string(reason)))
        }
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              data.count <= PiTheme.imageByteLimit else {
            budget.reconcile(estimatedFrom: encodedLength, actual: nil)
            return MessageBlock(id: id, kind: .unknown(type: "image", raw: .string(ImageBudget.invalidPlaceholder)))
        }
        budget.reconcile(estimatedFrom: encodedLength, actual: data.count)
        return MessageBlock(id: id, kind: .image(ImagePayload(
            id: id, data: data, mimeType: mimeType, fileName: fileName
        )))
    }

    private static func extractText(from content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let string = content.stringValue { return string }
        return (content.arrayValue?.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        } ?? []).joined(separator: "\n").nonEmpty
    }

    private static func date(from value: JSONValue?) -> Date? {
        if let milliseconds = value?.doubleValue { return Date(timeIntervalSince1970: milliseconds / 1_000) }
        return Date.piDate(value?.stringValue)
    }

    private static func bounded(_ value: String, max: Int) -> String {
        value.count <= max ? value : String(value.prefix(max)) + "\n…"
    }
}

private extension String {
    var condensed: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var nonEmpty: String? { isEmpty ? nil : self }
    func headline(max length: Int) -> String {
        guard count > length else { return self }
        return String(prefix(length - 1)) + "…"
    }
}
