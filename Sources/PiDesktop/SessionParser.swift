import Foundation

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
    /// (which must still touch the whole file) finishes. Reads one fixed-size window from EOF,
    /// then walks the real parent-pointer chain backward through it exactly like `conversation
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else {
            return TailScan(conversation: SessionConversation(messages: [], leafID: nil, rawEntryCount: 0), isComplete: true)
        }

        let windowSize = min(fileSize, UInt64(windowBytes))
        let readEntireFile = windowSize == fileSize
        try handle.seek(toOffset: fileSize - windowSize)
        let window = try handle.read(upToCount: Int(windowSize)) ?? Data()

        // Split into complete lines. When the window does not start at byte 0, its leading
        // fragment (before the first newline) is a truncated record and must be discarded.
        var lines = window.split(separator: 0x0A, omittingEmptySubsequences: true)
        if !readEntireFile, !lines.isEmpty { lines.removeFirst() }

        let decoder = JSONDecoder()
        var expectedID: String?
        var leafID: String?
        var sawAnyEntry = false
        var reachedRoot = false
        var collected: [ChatMessage] = []
        var budget = ImageBudget()

        for line in lines.reversed() {
            try Task.checkCancellation()
            let record = Data(line)
            guard let header = try? decoder.decode(EntryHeader.self, from: record) else { continue }
            if header.type == "session" { reachedRoot = true; break }
            guard let id = header.id else { continue }
            if sawAnyEntry {
                guard id == expectedID else { continue } // An abandoned branch, not our path.
            } else {
                sawAnyEntry = true
                leafID = id
            }
            if let raw = try? JSONValue.decode(record) {
                let entry = RawEntry(id: id, type: header.type ?? "unknown", raw: raw)
                if let message = chatMessage(from: entry, budget: &budget) { collected.append(message) }
            }
            expectedID = header.parentId
            guard expectedID != nil else { reachedRoot = true; break }
            if collected.count >= limit { break }
        }

        collected.reverse()
        return TailScan(
            conversation: SessionConversation(messages: collected, leafID: leafID, rawEntryCount: collected.count),
            isComplete: reachedRoot
        )
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
