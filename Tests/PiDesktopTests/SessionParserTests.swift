import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

final class SessionParserTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testParsesActiveBranchImagesUnknownEntriesAndSummary() throws {
        let file = temporaryDirectory.appendingPathComponent("session.jsonl")
        try writeFixture(to: file)

        let summary = try SessionParser.summary(at: file)
        XCTAssertEqual(summary.id, "session-id")
        XCTAssertEqual(summary.cwd.path, temporaryDirectory.path)
        XCTAssertEqual(summary.displayName, "Root prompt with image")
        XCTAssertEqual(summary.messageCount, 5, "Summary metrics intentionally include the full append-only tree")
        XCTAssertEqual(summary.model, "test-model")
        XCTAssertEqual(summary.provider, "test-provider")
        XCTAssertEqual(summary.metrics.input, 12, "Usage includes both active and abandoned branches, matching Pi stats")

        let conversation = try SessionParser.conversation(at: file)
        XCTAssertEqual(conversation.leafID, "unknown1")
        XCTAssertEqual(conversation.rawEntryCount, 7)
        XCTAssertTrue(conversation.messages.contains { $0.textContent.contains("Root prompt") })
        XCTAssertTrue(conversation.messages.contains { $0.textContent.contains("Active branch") })
        XCTAssertFalse(conversation.messages.contains { $0.textContent.contains("Abandoned branch") })
        XCTAssertEqual(conversation.messages.first(where: { $0.role == .user })?.images.count, 1)
        XCTAssertEqual(conversation.messages.last?.role, .unknown)
    }

    func testWindowedSummaryKeepsFirstUserTitleAcrossSkippedParentChain() throws {
        let file = temporaryDirectory.appendingPathComponent("sparse-summary.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }

        func append(_ object: [String: Any]) throws {
            try writer.write(contentsOf: JSONSerialization.data(withJSONObject: object))
            try writer.write(contentsOf: Data([0x0A]))
        }

        try append(["type": "session", "version": 3, "id": "sparse", "cwd": temporaryDirectory.path])
        try append([
            "type": "message", "id": "root", "parentId": NSNull(),
            "message": ["role": "user", "content": "Keep this exact title"]
        ])
        try writer.seek(toOffset: UInt64(2 * 1_024 * 1_024))
        try append([
            "type": "message", "id": "middle", "parentId": "root",
            "message": ["role": "assistant", "content": "middle"]
        ])
        try writer.seek(toOffset: UInt64(4 * 1_024 * 1_024))
        try append([
            "type": "message", "id": "tail", "parentId": "middle",
            "message": ["role": "assistant", "content": "tail"]
        ])
        try writer.synchronize()

        let summary = try SessionParser.summary(at: file)
        XCTAssertEqual(summary.displayName, "Keep this exact title")
        XCTAssertEqual(summary.preview, "Keep this exact title")
        XCTAssertTrue(summary.hasPartialCounts)
    }

    func testSummaryTracksOnlyPullRequestsCreatedOnTheActiveBranch() throws {
        let file = temporaryDirectory.appendingPathComponent("pull-request.jsonl")
        try write(lines: [
            ["type": "session", "version": 3, "id": "pr-session", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(),
             "message": ["role": "user", "content": "open a pull request"]],
            ["type": "message", "id": "abandoned-call", "parentId": "root", "message": [
                "role": "assistant", "content": [[
                    "type": "toolCall", "id": "old", "name": "bash",
                    "arguments": ["command": "gh pr create --title old"]
                ]]
            ]],
            ["type": "message", "id": "abandoned-result", "parentId": "abandoned-call", "message": [
                "role": "toolResult", "toolCallId": "old", "toolName": "bash",
                "content": [["type": "text", "text": "https://github.com/acme/widgets/pull/1"]]
            ]],
            ["type": "message", "id": "active-call", "parentId": "root", "message": [
                "role": "assistant", "content": [
                    ["type": "toolCall", "id": "noop", "name": "read", "arguments": ["path": "/tmp/x"]],
                    ["type": "toolCall", "id": "new", "name": "bash",
                     "arguments": ["command": "gh pr create --title new"]]
                ]
            ]],
            ["type": "message", "id": "noop-result", "parentId": "active-call", "message": [
                "role": "toolResult", "toolCallId": "noop", "toolName": "read", "content": "ok"
            ]],
            ["type": "message", "id": "active-result", "parentId": "noop-result",
             "timestamp": "2026-07-30T12:00:00.000Z", "message": [
                "role": "toolResult", "toolCallId": "new", "toolName": "bash",
                "content": [["type": "text", "text": "https://github.com/acme/widgets/pull/2"]]
            ]],
            ["type": "message", "id": "view-call", "parentId": "active-result", "message": [
                "role": "assistant", "content": [[
                    "type": "toolCall", "id": "view", "name": "bash",
                    "arguments": ["command": "python3 -c \"print('gh pr create')\""]
                ]]
            ]],
            ["type": "message", "id": "view-result", "parentId": "view-call", "message": [
                "role": "toolResult", "toolCallId": "view", "toolName": "bash",
                "content": [["type": "text", "text": "https://github.com/acme/widgets/pull/999"]]
            ]],
            ["type": "message", "id": "done", "parentId": "view-result",
             "message": ["role": "assistant", "content": "done"]]
        ], to: file)

        let summary = try SessionParser.summary(at: file)
        XCTAssertEqual(summary.pullRequestURL?.absoluteString, "https://github.com/acme/widgets/pull/2")
        XCTAssertEqual(summary.pullRequestCreatedAt, Date.piDate("2026-07-30T12:00:00.000Z"))
    }

    func testUserImagePromptHidesThePathFooter() throws {
        let imageData = Data("pixels".utf8)
        let message = SessionParser.chatMessage(fromAgentMessage: .object([
            "role": .string("user"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("Build this\n\nAttached image file paths:\n- /tmp/image.png")]),
                .object(["type": .string("image"), "data": .string(imageData.base64EncodedString()), "mimeType": .string("image/png")])
            ])
        ]))

        XCTAssertEqual(message?.textContent, "Build this")
        XCTAssertEqual(message?.images.map(\.data), [imageData])
    }

    func testTwoPassParserSkipsLargeAbandonedPayloadAndDiscardsKnownRawTrees() throws {
        let file = temporaryDirectory.appendingPathComponent("large-branch.jsonl")
        let smallImage = Data("active-image".utf8).base64EncodedString()
        let largeAbandonedImage = Data(repeating: 0x41, count: 3 * 1_024 * 1_024).base64EncodedString()
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "large", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(), "message": [
                "role": "user", "content": [["type": "text", "text": "active root"], ["type": "image", "data": smallImage, "mimeType": "image/png"]]
            ]],
            ["type": "message", "id": "abandoned", "parentId": "root", "message": [
                "role": "assistant", "content": [["type": "image", "data": largeAbandonedImage, "mimeType": "image/png"], ["type": "text", "text": String(repeating: "x", count: 500_000)]]
            ]],
            ["type": "message", "id": "active", "parentId": "root", "message": [
                "role": "assistant", "content": [["type": "text", "text": "active answer"]]
            ]]
        ]
        let data = try lines.reduce(into: Data()) { output, line in
            output.append(try JSONSerialization.data(withJSONObject: line))
            output.append(0x0A)
        }
        try data.write(to: file)

        let conversation = try SessionParser.conversation(at: file)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertFalse(conversation.messages.contains { $0.textContent.contains(String(repeating: "x", count: 100)) })
        XCTAssertEqual(conversation.messages.first?.images.count, 1)
        XCTAssertTrue(conversation.messages.allSatisfy { $0.raw == .null }, "Known messages must not retain duplicate raw/base64 trees")
    }

    func testExplicitlyHiddenCustomMessagesStayOutOfTheTranscript() throws {
        XCTAssertNil(SessionParser.chatMessage(fromAgentMessage: .object([
            "role": .string("custom"),
            "customType": .string("pi-desktop-connectivity-resume"),
            "content": .string("continue"),
            "display": .bool(false)
        ])))

        let file = temporaryDirectory.appendingPathComponent("hidden-custom.jsonl")
        try write(lines: [
            ["type": "session", "version": 3, "id": "hidden", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "user", "parentId": NSNull(),
             "message": ["role": "user", "content": "start"]],
            ["type": "custom_message", "id": "resume", "parentId": "user",
             "customType": "pi-desktop-connectivity-resume", "content": "continue", "display": false],
            ["type": "message", "id": "answer", "parentId": "resume",
             "message": ["role": "assistant", "content": "done"]]
        ], to: file)

        let conversation = try SessionParser.conversation(at: file)
        XCTAssertEqual(conversation.messages.map(\.textContent), ["start", "done"])
        XCTAssertEqual(conversation.leafID, "answer", "The hidden context entry stays on Pi's active branch")
    }

    func testAggregateImageBudgetReplacesExcessImagesWithPlaceholders() throws {
        let file = temporaryDirectory.appendingPathComponent("many-images.jsonl")
        let imageCount = ImageBudget.defaultCountLimit + 16
        let encoded = Data(repeating: 0x42, count: 900).base64EncodedString()
        var content: [[String: Any]] = [["type": "text", "text": "lots of screenshots"]]
        for index in 0..<imageCount {
            content.append(["type": "image", "id": "img-\(index)", "data": encoded, "mimeType": "image/png"])
        }
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "budget", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(),
             "message": ["role": "user", "content": content]]
        ]
        try write(lines: lines, to: file)

        let conversation = try SessionParser.conversation(at: file)
        let message = try XCTUnwrap(conversation.messages.first)
        XCTAssertEqual(message.images.count, ImageBudget.defaultCountLimit,
                       "The aggregate budget caps how many images one conversation decodes")

        let omitted = message.blocks.filter { block in
            guard case let .unknown(type, raw) = block.kind else { return false }
            return type == "image" && raw.stringValue == ImageBudget.omittedPlaceholder
        }
        XCTAssertEqual(omitted.count, imageCount - ImageBudget.defaultCountLimit,
                       "Excess images become an explicit placeholder instead of being decoded")
    }

    func testRPCHydrationSharesOneImageBudgetAcrossMessages() throws {
        let encoded = Data(repeating: 0x42, count: 900).base64EncodedString()
        let messages: [JSONValue] = (0..<40).map { index in
            .object([
                "role": .string("user"),
                "timestamp": .number(Double(index)),
                "content": .array([
                    .object(["type": .string("image"), "id": .string("m\(index)-a"), "data": .string(encoded)]),
                    .object(["type": .string("image"), "id": .string("m\(index)-b"), "data": .string(encoded)])
                ])
            ])
        }
        let hydrated = SessionParser.chatMessages(fromRPCMessages: .array(messages))
        let decoded = hydrated.reduce(0) { $0 + $1.images.count }
        XCTAssertEqual(hydrated.count, 40)
        XCTAssertEqual(decoded, ImageBudget.defaultCountLimit,
                       "The budget is aggregate for the hydration, not per message")
    }

    func testActiveBranchIsProjectedWithoutRetainingRawEntries() throws {
        let file = temporaryDirectory.appendingPathComponent("projected.jsonl")
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "proj", "cwd": temporaryDirectory.path]]
        var parent: Any = NSNull()
        for index in 0..<40 {
            let id = "entry-\(index)"
            lines.append([
                "type": "message", "id": id, "parentId": parent,
                "message": [
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": [["type": "text", "text": String(repeating: "payload ", count: 500)]]
                ]
            ])
            parent = id
        }
        try write(lines: lines, to: file)

        let conversation = try SessionParser.conversation(at: file)
        XCTAssertEqual(conversation.messages.count, 40)
        XCTAssertEqual(conversation.leafID, "entry-39")
        XCTAssertEqual(conversation.rawEntryCount, 40)
        // Direct projection means no entry keeps its raw JSON/base64 tree alive.
        XCTAssertTrue(conversation.messages.allSatisfy { $0.raw == .null })
        XCTAssertTrue(conversation.messages.allSatisfy { message in
            message.blocks.allSatisfy { block in
                if case .unknown = block.kind { return false }
                return true
            }
        })
    }

    func testRetainedPreviewIsBounded() throws {
        let file = temporaryDirectory.appendingPathComponent("long-preview.jsonl")
        let prompt = String(repeating: "searchable words ", count: 400)
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "preview", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(),
             "message": ["role": "user", "content": prompt]]
        ]
        try write(lines: lines, to: file)

        var summary = try SessionParser.summary(at: file)
        XCTAssertLessThanOrEqual(summary.preview.count, PiTheme.sessionPreviewLimit)
        XCTAssertTrue(summary.preview.hasPrefix("searchable words"))
        summary.prepareSearchKey()
        XCTAssertTrue(summary.searchKey.contains("searchable words"), "Search stays useful")
    }

    // MARK: - Completion tail scan

    func testTerminalAssistantStopReasonsProduceStableCompletionEntryIDs() {
        for reason in ["stop", "length", "error", "aborted"] {
            let tail = Data("{\"type\":\"message\",\"id\":\"\(reason)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"\(reason)\"}}\n".utf8)
            XCTAssertEqual(
                SessionParser.latestTerminalAssistantCompletion(inTail: tail),
                SessionParser.AssistantCompletion(id: reason, stopReason: reason)
            )
        }
    }

    func testToolUseIsNotACompletionAndDoesNotHideThePreviousCompletedAnswer() {
        let tail = Data("""
        {"type":"message","id":"done","message":{"role":"assistant","stopReason":"stop"}}
        {"type":"message","id":"tools","message":{"role":"assistant","stopReason":"toolUse"}}
        """.utf8)
        XCTAssertEqual(SessionParser.latestTerminalAssistantCompletion(inTail: tail)?.id, "done")
    }

    func testCompletionTailIgnoresAnUnterminatedTornLastLine() {
        let tail = Data("{\"type\":\"message\",\"id\":\"done\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n{\"type\":\"message\",\"id\":\"torn\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"error\"}}".utf8)
        XCTAssertEqual(SessionParser.latestTerminalAssistantCompletion(inTail: tail)?.id, "done")
    }

    // MARK: - Task 1: tail-first scan

    func testConversationTailReturnsLastMessagesInOrderAndReportsIncomplete() throws {
        let file = temporaryDirectory.appendingPathComponent("tail-basic.jsonl")
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "tail", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(), "message": ["role": "user", "content": "first"]],
            ["type": "message", "id": "a", "parentId": "root", "message": ["role": "assistant", "content": [["type": "text", "text": "second"]]]],
            ["type": "message", "id": "b", "parentId": "a", "message": ["role": "user", "content": "third"]],
            ["type": "message", "id": "c", "parentId": "b", "message": ["role": "assistant", "content": [["type": "text", "text": "fourth"]]]]
        ]
        try write(lines: lines, to: file)

        let tail = try SessionParser.conversationTail(at: file, limit: 2)
        XCTAssertEqual(tail.conversation.messages.map(\.textContent), ["third", "fourth"])
        XCTAssertFalse(tail.isComplete, "Two of four messages were collected: earlier history remains")
    }

    func testConversationTailIsCompleteWhenTheLimitCoversTheWholeConversation() throws {
        let file = temporaryDirectory.appendingPathComponent("tail-complete.jsonl")
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "tail", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(), "message": ["role": "user", "content": "first"]],
            ["type": "message", "id": "a", "parentId": "root", "message": ["role": "assistant", "content": [["type": "text", "text": "second"]]]]
        ]
        try write(lines: lines, to: file)

        let tail = try SessionParser.conversationTail(at: file, limit: 40)
        XCTAssertEqual(tail.conversation.messages.map(\.textContent), ["first", "second"])
        XCTAssertTrue(tail.isComplete, "The backward walk reached the root, so this already is the whole conversation")

        let full = try SessionParser.conversation(at: file)
        XCTAssertEqual(tail.conversation.messages.map(\.id), full.messages.map(\.id))
    }

    func testConversationTailSkipsAnAbandonedBranchPhysicallyAdjacentToTheActiveTail() throws {
        // root -> a -> b (abandoned, written first) -> c (the edit that replaced b, active) -> d -> e (leaf).
        // b's id is never referenced by anything after it, so it is not on the path from the leaf.
        let file = temporaryDirectory.appendingPathComponent("tail-abandoned.jsonl")
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "tail", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(), "message": ["role": "user", "content": "root prompt"]],
            ["type": "message", "id": "a", "parentId": "root", "message": ["role": "assistant", "content": [["type": "text", "text": "reply a"]]]],
            ["type": "message", "id": "b", "parentId": "a", "message": ["role": "user", "content": "abandoned follow-up"]],
            ["type": "message", "id": "c", "parentId": "a", "message": ["role": "user", "content": "edited follow-up"]],
            ["type": "message", "id": "d", "parentId": "c", "message": ["role": "assistant", "content": [["type": "text", "text": "reply d"]]]]
        ]
        try write(lines: lines, to: file)

        let tail = try SessionParser.conversationTail(at: file, limit: 40)
        XCTAssertTrue(tail.isComplete)
        XCTAssertEqual(tail.conversation.messages.map(\.id), ["root", "a", "c", "d"], "The abandoned sibling (b) must never appear")

        let full = try SessionParser.conversation(at: file)
        XCTAssertEqual(tail.conversation.messages.map(\.id), full.messages.map(\.id))
    }

    func testConversationTailOnAnEmptyFileIsCompleteAndEmpty() throws {
        let file = temporaryDirectory.appendingPathComponent("tail-empty.jsonl")
        try Data().write(to: file)

        let tail = try SessionParser.conversationTail(at: file, limit: 10)
        XCTAssertTrue(tail.conversation.messages.isEmpty)
        XCTAssertTrue(tail.isComplete)
    }

    /// A window too small to reach the root must never be mistaken for a complete conversation,
    /// and the leading (truncated) line inside that window must never leak a corrupt message —
    /// this is what makes it safe to bound the backward read on a real multi-megabyte session.
    func testConversationTailWithATinyWindowStaysCorrectAndReportsIncomplete() throws {
        let file = temporaryDirectory.appendingPathComponent("tail-window.jsonl")
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "tail", "cwd": temporaryDirectory.path]]
        var parent: Any = NSNull()
        for index in 0..<30 {
            let id = "entry-\(index)"
            lines.append([
                "type": "message", "id": id, "parentId": parent,
                "message": ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": "padding text for entry \(index)"]
            ])
            parent = id
        }
        try write(lines: lines, to: file)

        let full = try SessionParser.conversation(at: file)
        let tail = try SessionParser.conversationTail(at: file, limit: 100, windowBytes: 300)

        XCTAssertFalse(tail.isComplete, "300 bytes cannot reach a 30-message chain's root")
        XCTAssertFalse(tail.conversation.messages.isEmpty, "Some trailing messages must still fit in the window")
        XCTAssertLessThan(tail.conversation.messages.count, full.messages.count)
        XCTAssertEqual(
            tail.conversation.messages.map(\.id),
            full.messages.suffix(tail.conversation.messages.count).map(\.id),
            "The partial tail must be an exact suffix of the authoritative parse, not a reordering or a skip"
        )
    }

    // MARK: - Bounded conversation paging

    func testRepositoryPagesTheActiveBranchWithoutDuplicates() async throws {
        let file = temporaryDirectory.appendingPathComponent("paged-branch.jsonl")
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "paged", "cwd": temporaryDirectory.path]]
        var parent: Any = NSNull()
        var activeIDs: [String] = []
        for index in 0..<125 {
            if index == 60 {
                lines.append(["type": "message", "id": "abandoned-1", "parentId": parent,
                              "message": ["role": "user", "content": "abandoned one"]])
                lines.append(["type": "message", "id": "abandoned-2", "parentId": "abandoned-1",
                              "message": ["role": "assistant", "content": "abandoned two"]])
            }
            let id = "entry-\(index)"
            lines.append(["type": "message", "id": id, "parentId": parent,
                          "message": ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": "active \(index)"]])
            activeIDs.append(id)
            parent = id
        }
        try write(lines: lines, to: file)

        let repository = FileSessionRepository(rootURL: temporaryDirectory)
        var pages = [try await repository.loadNewestConversationPage(from: file)]
        while let cursor = pages.last?.olderCursor {
            pages.append(try await repository.loadOlderConversationPage(from: file, cursor: cursor))
        }

        XCTAssertEqual(pages.map(\.messages.count), [51, 50, 24],
                       "Pages meet the soft target, then stop on a user-turn boundary")
        XCTAssertTrue(pages.last?.hasNoMoreHistory == true)
        XCTAssertTrue(pages.allSatisfy { $0.leafID == "entry-124" })
        let pagedIDs = pages.reversed().flatMap { $0.messages.map(\.id) }
        XCTAssertEqual(pagedIDs, activeIDs)
        XCTAssertEqual(Set(pagedIDs).count, pagedIDs.count)
        XCTAssertFalse(pagedIDs.contains("abandoned-1"))
        XCTAssertGreaterThan(pages[1].scannedEntryCount, pages[1].rawEntryCount,
                             "The bounded scan may inspect abandoned records without projecting them")
    }

    func testFocusedHistoryCarriesAnswerSelectionAcrossScanLimits() throws {
        let file = temporaryDirectory.appendingPathComponent("focused-split.jsonl")
        try write(lines: [
            ["type": "session", "version": 3, "id": "focused"],
            ["type": "message", "id": "user", "parentId": NSNull(),
             "message": ["role": "user", "content": "Question"]],
            ["type": "message", "id": "narration", "parentId": "user",
             "message": ["role": "assistant", "content": "Let me inspect it."]],
            ["type": "message", "id": "call", "parentId": "narration",
             "message": ["role": "assistant", "stopReason": "toolUse", "content": [[
                "type": "toolCall", "id": "tool", "name": "read", "arguments": [String: Any]()
             ]]]],
            ["type": "message", "id": "result", "parentId": "call",
             "message": ["role": "toolResult", "toolCallId": "tool", "content": "contents"]],
            ["type": "message", "id": "answer", "parentId": "result",
             "message": ["role": "assistant", "content": "Final answer", "stopReason": "stop"]]
        ], to: file)
        let limits = SessionParser.PageLimits(
            maxScanBytes: 1_024 * 1_024, maxEntries: 2,
            maxRecordBytes: 512 * 1_024, chunkBytes: 4 * 1_024
        )

        var pages = [try SessionParser.conversationPage(
            at: file, projection: .focusedHistory, limits: limits
        )]
        while let cursor = pages.last?.olderCursor {
            pages.append(try SessionParser.conversationPage(
                at: file, cursor: cursor, projection: .focusedHistory, limits: limits
            ))
        }

        XCTAssertEqual(pages.reversed().flatMap { $0.messages.map(\.id) }, ["user", "answer"])
        XCTAssertFalse(pages.flatMap(\.messages).contains { $0.id == "narration" })
    }

    func testNewestPageIncludesTheStartOfALongActiveTurn() throws {
        let file = temporaryDirectory.appendingPathComponent("paged-active-turn.jsonl")
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "active", "cwd": temporaryDirectory.path]]
        var parent: Any = NSNull()

        for (id, role) in [("older-user", "user"), ("older-answer", "assistant"), ("current-user", "user")] {
            lines.append(["type": "message", "id": id, "parentId": parent,
                          "message": ["role": role, "content": id]])
            parent = id
        }
        for index in 0..<80 {
            let callID = "call-\(index)"
            let assistantID = "assistant-\(index)"
            lines.append([
                "type": "message", "id": assistantID, "parentId": parent,
                "message": [
                    "role": "assistant", "stopReason": "toolUse",
                    "content": [["type": "toolCall", "id": callID, "name": "read",
                                 "arguments": [String: Any]()]]
                ]
            ])
            lines.append([
                "type": "message", "id": "result-\(index)", "parentId": assistantID,
                "message": [
                    "role": "toolResult", "toolCallId": callID, "toolName": "read",
                    "content": [["type": "text", "text": "ok"]]
                ]
            ])
            parent = "result-\(index)"
        }
        try write(lines: lines, to: file)

        let page = try SessionParser.conversationPage(at: file)

        XCTAssertEqual(page.messages.first?.id, "current-user")
        XCTAssertEqual(page.messages.count, 161)
        XCTAssertNotNil(page.olderCursor)
        let items = TranscriptPresenter.items(messages: page.messages, streaming: nil, isRunning: true)
        XCTAssertEqual(items.count, 2, "The opening page shows the prompt and one collapsed work row")
        guard let last = items.last, case let .work(block) = last else {
            return XCTFail("Expected active work")
        }
        XCTAssertEqual(block.stepCount, 80)
    }

    func testOlderPageCrossesCompactionAndKeepsPreCompactionHistory() async throws {
        let file = temporaryDirectory.appendingPathComponent("paged-compaction.jsonl")
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "compact", "cwd": temporaryDirectory.path]]
        var parent: Any = NSNull()
        for index in 0..<20 {
            let id = "before-\(index)"
            lines.append(["type": "message", "id": id, "parentId": parent,
                          "message": ["role": "user", "content": "before \(index)"]])
            parent = id
        }
        lines.append(["type": "compaction", "id": "compact-1", "parentId": parent, "summary": "bounded summary"])
        parent = "compact-1"
        for index in 0..<50 {
            let id = "after-\(index)"
            lines.append(["type": "message", "id": id, "parentId": parent,
                          "message": ["role": "assistant", "content": "after \(index)"]])
            parent = id
        }
        try write(lines: lines, to: file)

        let repository = FileSessionRepository(rootURL: temporaryDirectory)
        let newest = try await repository.loadNewestConversationPage(from: file)
        XCTAssertEqual(newest.messages.first?.id, "compact-1")
        XCTAssertEqual(newest.messages.dropFirst().map(\.id), (0..<50).map { "after-\($0)" })
        XCTAssertTrue(newest.messages.first?.textContent.contains("bounded summary") == true)
        let cursor = try XCTUnwrap(newest.olderCursor)
        let older = try await repository.loadOlderConversationPage(from: file, cursor: cursor)

        XCTAssertEqual(older.messages.first?.id, "before-0")
        XCTAssertEqual(older.messages.last?.id, "before-19")
        XCTAssertTrue(older.hasNoMoreHistory)
        XCTAssertEqual(older.leafID, "after-49")
    }

    func testTornFinalLineIsIgnoredThenAppearsAfterRepair() async throws {
        let file = temporaryDirectory.appendingPathComponent("torn.jsonl")
        try write(lines: [
            ["type": "session", "version": 3, "id": "torn", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "root", "parentId": NSNull(),
             "message": ["role": "user", "content": "complete root"]]
        ], to: file)
        let tail = try JSONSerialization.data(withJSONObject: [
            "type": "message", "id": "tail", "parentId": "root",
            "message": ["role": "assistant", "content": "repaired tail"]
        ])
        let split = tail.count / 2
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: tail.prefix(split))
        try writer.close()

        let repository = FileSessionRepository(rootURL: temporaryDirectory)
        let torn = try await repository.loadNewestConversationPage(from: file)
        XCTAssertEqual(torn.messages.map(\.id), ["root"])
        XCTAssertEqual(torn.leafID, "root")
        XCTAssertEqual(try SessionParser.conversation(at: file).messages.map(\.id), ["root"])

        let repair = try FileHandle(forWritingTo: file)
        try repair.seekToEnd()
        try repair.write(contentsOf: tail.suffix(from: split))
        try repair.write(contentsOf: Data([0x0A]))
        try repair.close()

        let repaired = try await repository.loadNewestConversationPage(from: file)
        XCTAssertEqual(repaired.messages.map(\.id), ["root", "tail"])
        XCTAssertEqual(repaired.leafID, "tail")
        XCTAssertEqual(try SessionParser.conversation(at: file).messages.map(\.id), ["root", "tail"])
    }

    func testPagingProjectsHugeKnownAndUnknownPayloadsWithinExplicitBounds() throws {
        let file = temporaryDirectory.appendingPathComponent("paged-huge.jsonl")
        let huge = String(repeating: "payload", count: 300_000)
        try write(lines: [
            ["type": "session", "version": 3, "id": "huge", "cwd": temporaryDirectory.path],
            ["type": "message", "id": "known", "parentId": NSNull(),
             "message": ["role": "user", "content": huge]],
            ["type": "future_entry", "id": "unknown", "parentId": "known", "futurePayload": huge]
        ], to: file)

        let page = try SessionParser.conversationPage(at: file)
        XCTAssertEqual(page.messages.map(\.id), ["known", "unknown"])
        XCTAssertLessThanOrEqual(page.messages[0].textContent.count, 160_002)
        XCTAssertEqual(page.messages[0].raw, .null)
        XCTAssertLessThanOrEqual(page.messages[1].raw.stringValue?.count ?? .max, PiTheme.unknownPayloadLimit + 2)
        XCTAssertLessThanOrEqual(page.scannedByteCount, SessionParser.PageLimits.default.maxScanBytes)

        let tinyLimits = SessionParser.PageLimits(
            maxScanBytes: 64 * 1_024,
            maxEntries: 20,
            maxRecordBytes: 32 * 1_024,
            chunkBytes: 8 * 1_024
        )
        let capped = try SessionParser.conversationPage(at: file, limits: tinyLimits)
        XCTAssertTrue(capped.isTruncated)
        XCTAssertFalse(capped.hasNoMoreHistory)
        XCTAssertLessThanOrEqual(capped.scannedByteCount, tinyLimits.maxScanBytes)
        XCTAssertLessThanOrEqual(capped.scannedEntryCount, tinyLimits.maxEntries)
    }

    func testInstalledSessionDirectorySmokeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PI_DESKTOP_REAL_SESSION_SMOKE"] == "1" else {
            throw XCTSkip("Set PI_DESKTOP_REAL_SESSION_SMOKE=1 to scan the installed Pi session directory")
        }
        let repository = FileSessionRepository()
        guard FileManager.default.fileExists(atPath: repository.rootURL.path) else {
            throw XCTSkip("No installed Pi session directory")
        }
        let sessions = try await repository.discoverSessions(archivedIDs: [], agents: [.pi])
        XCTAssertFalse(sessions.isEmpty)
        XCTAssertTrue(sessions.allSatisfy { $0.agent == .pi })
        XCTAssertTrue(sessions.allSatisfy { $0.fileURL.deletingLastPathComponent().deletingLastPathComponent() == repository.rootURL })
    }

    /// Measures the production open path on the largest real session on this machine. This is
    /// local JSONL only: it never starts Pi or contacts a provider. The legacy full parse remains
    /// in the report solely as the measured gate for whether a sidecar index is ever warranted.
    func testMeasuresParseLatencyOnTheLargestInstalledSession() async throws {
        guard ProcessInfo.processInfo.environment["PI_DESKTOP_REAL_SESSION_SMOKE"] == "1" else {
            throw XCTSkip("Set PI_DESKTOP_REAL_SESSION_SMOKE=1 to scan the installed Pi session directory")
        }
        let repository = FileSessionRepository()
        guard FileManager.default.fileExists(atPath: repository.rootURL.path) else {
            throw XCTSkip("No installed Pi session directory")
        }
        let enumerator = FileManager.default.enumerator(at: repository.rootURL, includingPropertiesForKeys: [.fileSizeKey])
        var largest: (url: URL, size: Int)?
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > (largest?.size ?? 0) { largest = (url, size) }
        }
        guard let largest else { throw XCTSkip("No session files found") }

        let clock = ContinuousClock()
        var newestPage: ConversationPage?
        let newestPageDuration = clock.measure {
            newestPage = try? SessionParser.conversationPage(at: largest.url)
        }
        let fullParseDuration = clock.measure { _ = try? SessionParser.conversation(at: largest.url) }

        let cache = TranscriptCache()
        guard let values = try? largest.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let newestPage else {
            throw XCTSkip("Could not fingerprint/page the largest session")
        }
        let fingerprint = SessionFileFingerprint(url: largest.url, values: values)
        cache.store(newestPage, for: largest.url.standardizedFileURL.path, fingerprint: fingerprint)
        let cacheHitDuration = clock.measure {
            _ = cache.page(for: largest.url.standardizedFileURL.path, fingerprint: fingerprint)
        }

        print("""
        [perf] \(largest.url.lastPathComponent) size=\(largest.size / 1_024)KB \
        newestPage=\(newestPageDuration) messages=\(newestPage.messages.count) \
        scanned=\(newestPage.scannedByteCount / 1_024)KB cacheHit=\(cacheHitDuration) \
        legacyFullParse=\(fullParseDuration)
        """)
    }

    func testRepositoryOnlyFindsDirectSessionFiles() async throws {
        let encodedFolder = temporaryDirectory.appendingPathComponent("--tmp-project--", isDirectory: true)
        try FileManager.default.createDirectory(at: encodedFolder, withIntermediateDirectories: true)
        let main = encodedFolder.appendingPathComponent("main.jsonl")
        try writeFixture(to: main)

        let nested = encodedFolder
            .appendingPathComponent("main", isDirectory: true)
            .appendingPathComponent("child", isDirectory: true)
            .appendingPathComponent("run-0", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFixture(to: nested.appendingPathComponent("session.jsonl"))

        let repository = FileSessionRepository(rootURL: temporaryDirectory)
        let sessions = try await repository.discoverSessions(archivedIDs: ["session-id"])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.fileURL.lastPathComponent, "main.jsonl")
        XCTAssertEqual(sessions.first?.isArchived, true)
    }

    private func write(lines: [[String: Any]], to url: URL) throws {
        let data = try lines.reduce(into: Data()) { output, line in
            output.append(try JSONSerialization.data(withJSONObject: line))
            output.append(0x0A)
        }
        try data.write(to: url)
    }

    private func writeFixture(to url: URL) throws {
        let image = Data("image-bytes".utf8).base64EncodedString()
        let lines: [[String: Any]] = [
            [
                "type": "session", "version": 3, "id": "session-id",
                "timestamp": "2026-01-01T12:00:00.000Z", "cwd": temporaryDirectory.path
            ],
            [
                "type": "model_change", "id": "model0", "parentId": NSNull(),
                "timestamp": "2026-01-01T12:00:00.100Z", "provider": "test-provider", "modelId": "test-model"
            ],
            [
                "type": "message", "id": "user1", "parentId": "model0",
                "timestamp": "2026-01-01T12:00:01.000Z",
                "message": [
                    "role": "user", "timestamp": 1_767_268_801_000 as NSNumber,
                    "content": [
                        ["type": "text", "text": "Root prompt with image"],
                        ["type": "image", "data": image, "mimeType": "image/png"]
                    ]
                ]
            ],
            [
                "type": "message", "id": "assistant1", "parentId": "user1",
                "timestamp": "2026-01-01T12:00:02.000Z",
                "message": [
                    "role": "assistant", "timestamp": 1_767_268_802_000 as NSNumber,
                    "provider": "test-provider", "model": "test-model", "stopReason": "stop",
                    "content": [["type": "text", "text": "Base answer"]],
                    "usage": usage(input: 10)
                ]
            ],
            [
                "type": "message", "id": "abandonedUser", "parentId": "assistant1",
                "timestamp": "2026-01-01T12:00:03.000Z",
                "message": ["role": "user", "content": "Abandoned branch", "timestamp": 1_767_268_803_000 as NSNumber]
            ],
            [
                "type": "message", "id": "abandonedAssistant", "parentId": "abandonedUser",
                "timestamp": "2026-01-01T12:00:04.000Z",
                "message": [
                    "role": "assistant", "content": [["type": "text", "text": "Abandoned answer"]],
                    "timestamp": 1_767_268_804_000 as NSNumber, "provider": "test-provider", "model": "test-model",
                    "stopReason": "stop", "usage": usage(input: 2)
                ]
            ],
            [
                "type": "message", "id": "activeUser", "parentId": "assistant1",
                "timestamp": "2026-01-01T12:00:05.000Z",
                "message": ["role": "user", "content": "Active branch", "timestamp": 1_767_268_805_000 as NSNumber]
            ],
            [
                "type": "future_entry", "id": "unknown1", "parentId": "activeUser",
                "timestamp": "2026-01-01T12:00:06.000Z", "futurePayload": ["kept": true]
            ]
        ]

        let data = try lines.reduce(into: Data()) { output, line in
            output.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            output.append(0x0A)
        }
        try data.write(to: url)
    }

    private func usage(input: Int) -> [String: Any] {
        [
            "input": input, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": input,
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]
        ]
    }
}
