import Foundation
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

    func testInstalledSessionDirectorySmokeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PI_DESKTOP_REAL_SESSION_SMOKE"] == "1" else {
            throw XCTSkip("Set PI_DESKTOP_REAL_SESSION_SMOKE=1 to scan the installed Pi session directory")
        }
        let repository = FileSessionRepository()
        guard FileManager.default.fileExists(atPath: repository.rootURL.path) else {
            throw XCTSkip("No installed Pi session directory")
        }
        let sessions = try await repository.discoverSessions(archivedIDs: [])
        XCTAssertFalse(sessions.isEmpty)
        XCTAssertTrue(sessions.allSatisfy { $0.fileURL.deletingLastPathComponent().deletingLastPathComponent() == repository.rootURL })
    }

    /// Task 1 measurement: actual load latency on the largest real session on this machine,
    /// never a synthetic fixture — `PI_DESKTOP_REAL_SESSION_SMOKE=1` opts in explicitly since
    /// this depends on whatever happens to be installed. Reading local JSONL is free; nothing
    /// here starts Pi or talks to a provider. Reports the three numbers that matter for "instant
    /// open": a warm `TranscriptCache` hit (what a recent/prefetched selection pays), the
    /// tail-first scan (what a cold selection paints immediately), and the full two-pass parse
    /// (what eventually replaces the tail on a cold selection).
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
        let fullParseDuration = clock.measure { _ = try? SessionParser.conversation(at: largest.url) }
        let tailScanDuration = clock.measure { _ = try? SessionParser.conversationTail(at: largest.url, limit: 40) }

        let cache = TranscriptCache()
        guard let values = try? largest.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let conversation = try? SessionParser.conversation(at: largest.url) else {
            throw XCTSkip("Could not fingerprint/parse the largest session")
        }
        let fingerprint = SessionFileFingerprint(url: largest.url, values: values)
        cache.store(conversation, for: largest.url.standardizedFileURL.path, fingerprint: fingerprint)
        let cacheHitDuration = clock.measure {
            _ = cache.conversation(for: largest.url.standardizedFileURL.path, fingerprint: fingerprint)
        }

        print("""
        [perf] \(largest.url.lastPathComponent) size=\(largest.size / 1_024)KB messages=\(conversation.messages.count) \
        cacheHit=\(cacheHitDuration) tailScan(cold)=\(tailScanDuration) fullParse(cold)=\(fullParseDuration)
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
