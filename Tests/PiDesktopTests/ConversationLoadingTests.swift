import PiDeskKit
import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Fakes

private final class FakeRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionFile = ""
    var sessionID = ""

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }
    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        guard type == "get_state" else { return }
        completion?(.success(.object([
            "success": .bool(true),
            "data": .object(["isStreaming": .bool(false), "sessionFile": .string(sessionFile), "sessionId": .string(sessionID)])
        ])))
    }
    func sendUncorrelated(_ value: JSONValue) {}
}

private struct FakeGitService: GitStatusProviding {
    var worktree: GitWorktreeInfo?
    func snapshot(for directory: URL) async -> GitSnapshot { GitSnapshot(isRepository: true) }
    func worktreeInfo(for directory: URL) async -> GitWorktreeInfo? {
        guard let worktree else { return nil }
        let target = directory.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: worktree.path, isDirectory: true).resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root + "/") ? worktree : nil
    }
}

private actor MutableGitService: GitStatusProviding {
    private var value: GitSnapshot

    init(_ value: GitSnapshot) { self.value = value }
    func set(_ value: GitSnapshot) { self.value = value }
    func snapshot(for directory: URL) async -> GitSnapshot { value }
}

/// Wraps a real `FileSessionRepository` and adds a fixed delay before every load, so a test can
/// deterministically overlap two selections instead of racing against however fast a tiny
/// fixture file happens to parse.
private struct DelayedRepository: SessionRepositoryProtocol {
    let base: FileSessionRepository
    let delayNanoseconds: UInt64
    var rootURL: URL { base.rootURL }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        try await base.discoverSessions(archivedIDs: archivedIDs)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        try await base.refreshSummary(at: fileURL, archivedIDs: archivedIDs)
    }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return try await base.loadConversation(from: fileURL)
    }
    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return try await base.loadConversationTail(from: fileURL, limit: limit)
    }
}

/// Returns scripted newest pages so the refresh-merge path can be exercised with page flags
/// (like a scan-budget truncation) that a tiny fixture file can never produce through the real
/// parser's default limits.
private struct DelayedPagingRepository: SessionRepositoryProtocol {
    let base: FileSessionRepository
    let newestDelay: UInt64
    let focusedDelay: UInt64
    var rootURL: URL { base.rootURL }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        try await base.discoverSessions(archivedIDs: archivedIDs)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        try await base.refreshSummary(at: fileURL, archivedIDs: archivedIDs)
    }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        try await base.loadConversation(from: fileURL)
    }
    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan {
        try await base.loadConversationTail(from: fileURL, limit: limit)
    }
    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage {
        try await Task.sleep(nanoseconds: newestDelay)
        return try await base.loadNewestConversationPage(from: fileURL)
    }
    func loadOlderConversationPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        try await base.loadOlderConversationPage(from: fileURL, cursor: cursor)
    }
    func loadFocusedHistoryPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        try await Task.sleep(nanoseconds: focusedDelay)
        return try await base.loadFocusedHistoryPage(from: fileURL, cursor: cursor)
    }
}

private final class ScriptedPagingRepository: SessionRepositoryProtocol, @unchecked Sendable {
    let rootURL = FileManager.default.temporaryDirectory
    private let lock = NSLock()
    private var newestQueue: [ConversationPage]

    init(newestPages: [ConversationPage]) { newestQueue = newestPages }

    private func nextNewestPage() -> ConversationPage {
        lock.lock()
        defer { lock.unlock() }
        return newestQueue.count > 1 ? newestQueue.removeFirst() : newestQueue[0]
    }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw ConversationPagingError.unsupported
    }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        let page = nextNewestPage()
        return SessionConversation(messages: page.messages, leafID: page.leafID, rawEntryCount: page.rawEntryCount)
    }
    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage {
        nextNewestPage()
    }
}

// MARK: - Tests



/// End-to-end coverage for Task 1 ("opening a thread must be instant, with no layout shift"),
/// exercised through the real `FileSessionRepository`/`SessionParser`/`TranscriptCache` rather
/// than fakes, since the whole point is the interaction between them.
@MainActor
final class ConversationLoadingTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopConversationLoading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testHistoryStaysConnectedToLatestAndNavigatesBackToLive() async throws {
        let file = temporaryDirectory.appendingPathComponent("big.jsonl")
        try writeLinearConversation(prefix: "big", messageCount: 80, to: file)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let session = try makeSummary(id: "big", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.messages.count == ConversationPage.defaultMessageTarget }
        XCTAssertEqual(store.messages.first?.textContent, "big-30")
        XCTAssertEqual(store.messages.last?.textContent, "big-79")
        XCTAssertTrue(store.hasEarlierMessages)

        store.loadEarlierMessages()
        try await waitUntil { store.isBrowsingEarlierHistory && !store.isLoadingEarlierMessages }
        XCTAssertEqual(store.messages.first?.textContent, "big-0")
        XCTAssertEqual(store.messages.last?.textContent, "big-79",
                       "The latest page must remain visibly connected below history")
        XCTAssertEqual(store.messages.count, 80)
        XCTAssertFalse(store.hasEarlierMessages)
        XCTAssertTrue(store.hasNewerMessages)

        store.loadNewerMessages()
        XCTAssertFalse(store.isBrowsingEarlierHistory)
        XCTAssertEqual(store.messages.first?.textContent, "big-30")
        XCTAssertEqual(store.messages.last?.textContent, "big-79")
    }

    func testConversationFocusedPagingCrossesThousandsOfToolRecords() async throws {
        let file = temporaryDirectory.appendingPathComponent("tool-heavy.jsonl")
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "tool-heavy"]]
        var parent: Any = NSNull()
        for turn in 0..<30 {
            let userID = "user-\(turn)"
            lines.append([
                "type": "message", "id": userID, "parentId": parent,
                "message": ["role": "user", "content": "prompt \(turn)"]
            ])
            parent = userID
            for step in 0..<40 {
                let callID = "call-\(turn)-\(step)"
                let assistantID = "assistant-\(turn)-\(step)"
                lines.append([
                    "type": "message", "id": assistantID, "parentId": parent,
                    "message": [
                        "role": "assistant", "stopReason": "toolUse",
                        "content": [["type": "toolCall", "id": callID, "name": "read", "arguments": [String: Any]()]]
                    ]
                ])
                lines.append([
                    "type": "message", "id": "result-\(turn)-\(step)", "parentId": assistantID,
                    "message": ["role": "toolResult", "toolCallId": callID, "content": "large tool output"]
                ])
                parent = "result-\(turn)-\(step)"
            }
            let answerID = "answer-\(turn)"
            lines.append([
                "type": "message", "id": answerID, "parentId": parent,
                "message": ["role": "assistant", "content": "answer \(turn)", "stopReason": "stop"]
            ])
            parent = answerID
        }
        try writeJSONL(lines, to: file)

        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let session = try makeSummary(id: "tool-heavy", fileURL: file)
        store.sessions = [session]
        store.selectSession(session)
        try await waitUntil { !store.isConversationLoading && store.messages.last?.id == "answer-29" }
        XCTAssertGreaterThan(store.messages.count, ConversationPage.defaultMessageTarget,
                             "The detailed newest page finishes its active turn")

        while store.hasEarlierMessages {
            store.loadEarlierMessages()
            try await waitUntil { !store.isLoadingEarlierMessages }
            XCTAssertEqual(store.messages.last?.textContent, "answer 29",
                           "The detailed latest turn stays below every focused history page")
            XCTAssertFalse(store.messages.flatMap(\.blocks).contains { block in
                guard case let .toolCall(call) = block.kind else { return false }
                return call.id.hasPrefix("call-28-")
            }, "Historical tool work stays omitted")
            XCTAssertTrue(store.messages.flatMap(\.blocks).contains { block in
                guard case let .toolCall(call) = block.kind else { return false }
                return call.id.hasPrefix("call-29-")
            }, "The connected latest turn keeps its detailed work")
        }

        XCTAssertEqual(store.messages.first?.textContent, "prompt 0")
        XCTAssertTrue(store.hasNewerMessages)
        store.loadNewerMessages()
        try await waitUntil { !store.isLoadingNewerMessages }
        XCTAssertTrue(store.isBrowsingEarlierHistory)
        store.jumpToLatestMessages()
        XCTAssertEqual(store.messages.last?.textContent, "answer 29")
    }

    func testLiveMessagesStayOnLatestWhileBrowsingOlderHistory() async throws {
        let file = temporaryDirectory.appendingPathComponent("live.jsonl")
        try writeLinearConversation(prefix: "disk", messageCount: 60, to: file)
        let runtime = FakeRuntime()
        runtime.sessionFile = file.path
        runtime.sessionID = "live"
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory), runtime: runtime)
        let session = try makeSummary(id: "live", fileURL: file)
        store.sessions = [session]
        store.selectSession(session)
        try await waitUntil { store.messages.count == 50 }
        store.prepareComposerOptions()

        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"), "content": .string("Live narration"),
                "stopReason": .string("toolUse"), "timestamp": .number(2_000)
            ])
        ]))
        XCTAssertEqual(store.messages.last?.textContent, "Live narration")

        store.loadEarlierMessages()
        try await waitUntil { store.isBrowsingEarlierHistory && !store.isLoadingEarlierMessages }
        XCTAssertTrue(store.messages.contains { $0.textContent == "Live narration" },
                      "The frozen latest window stays visible below history")

        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"), "content": .string("Buffered answer"),
                "stopReason": .string("stop"), "timestamp": .number(3_000)
            ])
        ]))
        XCTAssertFalse(store.messages.contains { $0.textContent == "Buffered answer" })

        store.jumpToLatestMessages()
        XCTAssertEqual(store.messages.last?.textContent, "Buffered answer")
        XCTAssertEqual(store.messages.filter { $0.textContent == "Live narration" }.count, 1)
        XCTAssertEqual(store.messages.filter { $0.textContent == "Buffered answer" }.count, 1)

        store.selectSession(session)
        XCTAssertEqual(store.messages.last?.textContent, "Buffered answer",
                       "Returning from history must not misclassify an RPC answer as durable")
    }

    func testASmallConversationsTailScanIsAlreadyCompleteSoNoBackfillIsNeeded() async throws {
        // Fewer messages than the tail preview limit: the backward scan reaches the root on its
        // own, so the very first publish is already final.
        let file = temporaryDirectory.appendingPathComponent("small.jsonl")
        try writeLinearConversation(prefix: "small", messageCount: 3, to: file)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let session = try makeSummary(id: "small", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.messages.count == 3 }
        XCTAssertFalse(store.isConversationLoading)
        XCTAssertEqual(store.messages.map(\.textContent), ["small-0", "small-1", "small-2"])
    }

    func testEachHistoryPageKeepsABoundedImageBudget() async throws {
        let file = temporaryDirectory.appendingPathComponent("paged-images.jsonl")
        let encoded = Data("pixel".utf8).base64EncodedString()
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": "images"]]
        var parent: Any = NSNull()
        for index in 0..<60 {
            let id = "image-\(index)"
            lines.append([
                "type": "message", "id": id, "parentId": parent,
                "message": [
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": [["type": "image", "data": encoded, "mimeType": "image/png"]]
                ]
            ])
            parent = id
        }
        let data = try lines.reduce(into: Data()) { output, line in
            output.append(try JSONSerialization.data(withJSONObject: line))
            output.append(0x0A)
        }
        try data.write(to: file)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let session = try makeSummary(id: "images", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.messages.count == 50 }
        XCTAssertEqual(store.messages.flatMap(\.images).count, PiTheme.imageCountLimit)

        store.loadEarlierMessages()
        try await waitUntil { store.isBrowsingEarlierHistory && !store.isLoadingEarlierMessages }
        XCTAssertLessThanOrEqual(store.messages.flatMap(\.images).count, PiTheme.imageCountLimit)
        XCTAssertEqual(store.messages.count, 60)
        XCTAssertEqual(store.messages.last?.id, "image-59")

        store.jumpToLatestMessages()
        XCTAssertEqual(store.messages.flatMap(\.images).count, PiTheme.imageCountLimit)
        XCTAssertEqual(store.messages.last?.images.count, 1, "Returning restores the newest page")
    }

    func testUnreadConversationTargetsTheFirstLoadedCompletionAfterLastSeen() async throws {
        let file = temporaryDirectory.appendingPathComponent("unread.jsonl")
        try Data("""
        {"type":"session","version":3,"id":"unread"}
        {"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"one"}}
        {"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":"one","stopReason":"stop"}}
        {"type":"message","id":"u2","parentId":"a1","message":{"role":"user","content":"two"}}
        {"type":"message","id":"a2","parentId":"u2","message":{"role":"assistant","content":"two","stopReason":"stop"}}
        {"type":"message","id":"u3","parentId":"a2","message":{"role":"user","content":"three"}}
        {"type":"message","id":"a3","parentId":"u3","message":{"role":"assistant","content":"three","stopReason":"stop"}}

        """.utf8).write(to: file)
        let persistence = AppPersistence(baseURL: temporaryDirectory.appendingPathComponent("state"))
        _ = persistence.observeCompletedEntry(path: file.path, completionID: "a1", modifiedAt: Date(), markSeen: true)
        _ = persistence.observeCompletedEntry(path: file.path, completionID: "a3", modifiedAt: Date(), markSeen: false)
        let store = makeStore(
            repository: FileSessionRepository(rootURL: temporaryDirectory),
            persistence: persistence
        )
        let session = try makeSummary(id: "unread", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.messages.last?.id == "a3" }

        XCTAssertEqual(store.initialScrollTargetMessageID, "a2")
    }

    func testReselectingAnAlreadyLoadedSessionHitsTheCacheWithNoLoadingStateEver() async throws {
        let fileA = temporaryDirectory.appendingPathComponent("a.jsonl")
        let fileB = temporaryDirectory.appendingPathComponent("b.jsonl")
        try writeLinearConversation(prefix: "a", messageCount: 4, to: fileA)
        try writeLinearConversation(prefix: "b", messageCount: 4, to: fileB)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let a = try makeSummary(id: "a", fileURL: fileA)
        let b = try makeSummary(id: "b", fileURL: fileB)
        store.sessions = [a, b]

        store.selectSession(a)
        try await waitUntil { store.messages.count == 4 }
        store.selectSession(b)
        try await waitUntil { store.messages.first?.textContent == "b-0" }

        // `a` is already warm in the transcript cache: reselecting it must be a synchronous hit,
        // so `isConversationLoading` is `false` and `messages` is already correct the instant
        // `selectSession` returns \u2014 nothing about this can be observed "a moment later".
        store.selectSession(a)
        XCTAssertFalse(store.isConversationLoading, "A cache hit must never show a loading state, even transiently")
        XCTAssertEqual(store.messages.map(\.textContent), ["a-0", "a-1", "a-2", "a-3"])
    }

    func testOptimisticMessageStaysInOwningSessionAcrossCachedNavigation() async throws {
        let fileA = temporaryDirectory.appendingPathComponent("a.jsonl")
        let fileB = temporaryDirectory.appendingPathComponent("b.jsonl")
        try writeLinearConversation(prefix: "a", messageCount: 2, to: fileA)
        try writeLinearConversation(prefix: "b", messageCount: 2, to: fileB)
        let runtime = FakeRuntime()
        runtime.sessionFile = fileA.path
        runtime.sessionID = "a"
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory), runtime: runtime)
        let a = try makeSummary(id: "a", fileURL: fileA)
        let b = try makeSummary(id: "b", fileURL: fileB)
        store.sessions = [a, b]

        store.selectSession(b)
        try await waitUntil { store.messages.first?.textContent == "b-0" }
        store.selectSession(a)
        try await waitUntil { store.messages.first?.textContent == "a-0" }
        store.draft = "only A"
        store.submitDraft()
        XCTAssertTrue(store.messages.contains { $0.id.hasPrefix("local-") && $0.textContent == "only A" })

        store.selectSession(b)
        XCTAssertFalse(store.isConversationLoading, "B should use its warm transcript cache")
        XCTAssertEqual(store.messages.map(\.textContent), ["b-0", "b-1"])

        store.selectSession(a)
        XCTAssertFalse(store.isConversationLoading, "A should use its warm transcript cache")
        XCTAssertEqual(store.messages.map(\.textContent), ["a-0", "a-1", "only A"])
    }

    func testSelectingAnotherSessionMidLoadDiscardsTheStaleLoad() async throws {
        let fileA = temporaryDirectory.appendingPathComponent("a.jsonl")
        let fileB = temporaryDirectory.appendingPathComponent("b.jsonl")
        try writeLinearConversation(prefix: "a", messageCount: 5, to: fileA)
        try writeLinearConversation(prefix: "b", messageCount: 5, to: fileB)
        let delayed = DelayedRepository(base: FileSessionRepository(rootURL: temporaryDirectory), delayNanoseconds: 150_000_000)
        let store = makeStore(repository: delayed)
        let a = try makeSummary(id: "a", fileURL: fileA)
        let b = try makeSummary(id: "b", fileURL: fileB)
        store.sessions = [a, b]

        store.selectSession(a)
        store.selectSession(b) // Supersedes A well before A's delayed load can resolve.

        try await waitUntil { store.messages.contains { $0.textContent == "b-4" } }
        // Give A's now-stale load every chance to finish and (incorrectly) publish over B.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(store.messages.allSatisfy { !$0.textContent.hasPrefix("a-") }, "A's stale load must never publish over B")
        XCTAssertEqual(store.selectedSession?.id, "b")
    }

    func testTerminalRPCAnswerStaysVisibleUntilJSONLBecomesDurable() async throws {
        let fileA = temporaryDirectory.appendingPathComponent("a.jsonl")
        let fileB = temporaryDirectory.appendingPathComponent("b.jsonl")
        try writeLinearConversation(prefix: "a", messageCount: 1, to: fileA)
        let priorEntries: [[String: Any]] = [
            [
                "type": "message", "id": "prior-same-answer", "parentId": "a-entry-0",
                "message": ["role": "assistant", "content": "Durable answer", "stopReason": "stop", "timestamp": 1_000]
            ],
            [
                "type": "message", "id": "next-user", "parentId": "prior-same-answer",
                "message": ["role": "user", "content": "Again", "timestamp": 1_500]
            ]
        ]
        let priorHandle = try FileHandle(forWritingTo: fileA)
        try priorHandle.seekToEnd()
        for entry in priorEntries {
            try priorHandle.write(contentsOf: JSONSerialization.data(withJSONObject: entry) + Data([0x0A]))
        }
        try priorHandle.close()
        try writeLinearConversation(prefix: "b", messageCount: 1, to: fileB)
        let runtime = FakeRuntime()
        runtime.sessionFile = fileA.path
        runtime.sessionID = "a"
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory), runtime: runtime)
        let a = try makeSummary(id: "a", fileURL: fileA)
        let b = try makeSummary(id: "b", fileURL: fileB)
        store.sessions = [a, b]
        store.selectSession(a)
        try await waitUntil { store.messages.count == 3 }
        store.prepareComposerOptions()

        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"), "content": .string("Durable answer"),
                "stopReason": .string("stop"), "timestamp": .number(2_000)
            ])
        ]))
        XCTAssertEqual(store.messages.last?.textContent, "Durable answer")

        store.selectSession(b)
        store.selectSession(a)
        XCTAssertEqual(store.messages.last?.textContent, "Durable answer", "A stale disk page must keep the RPC final overlay")

        let durable: [String: Any] = [
            "type": "message", "id": "durable-answer", "parentId": "next-user",
            "message": ["role": "assistant", "content": "Durable answer", "stopReason": "stop", "timestamp": 2_000]
        ]
        let handle = try FileHandle(forWritingTo: fileA)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: durable) + Data([0x0A]))
        try handle.close()
        XCTAssertEqual(try SessionParser.conversationPage(at: fileA).messages.last?.id, "durable-answer")

        store.selectSession(b)
        store.selectSession(a)
        for _ in 0..<120 where !store.messages.contains(where: { $0.id == "durable-answer" }) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(
            store.messages.contains(where: { $0.id == "durable-answer" }),
            "ids=\(store.messages.map(\.id)) loading=\(store.isConversationLoading) error=\(store.conversationError ?? "nil")"
        )
        XCTAssertEqual(store.messages.filter { $0.textContent == "Durable answer" }.count, 2)
    }

    func testDiskRefreshWaitsUntilOlderHistoryReturnsToLatest() async throws {
        let file = temporaryDirectory.appendingPathComponent("live-tail.jsonl")
        try writeLinearConversation(prefix: "live", messageCount: 60, to: file)
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: temporaryDirectory.appendingPathComponent("heartbeats", isDirectory: true)
        )
        let store = makeStore(
            repository: FileSessionRepository(rootURL: temporaryDirectory),
            activityMonitor: monitor
        )
        let session = try makeSummary(id: "live", fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path) != nil }

        store.selectSession(session)
        try await waitUntil { store.messages.count == 50 }
        store.loadEarlierMessages()
        try await waitUntil { store.isBrowsingEarlierHistory && !store.isLoadingEarlierMessages }
        let historicalIDs = store.messages.map(\.id)

        let entry: [String: Any] = [
            "type": "message", "id": "live-thinking", "parentId": "live-entry-59",
            "message": [
                "role": "assistant",
                "content": [["type": "thinking", "thinking": "Fresh live thought"]]
            ]
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: entry) + Data([0x0A]))
        try handle.close()
        monitor.tickNow()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(store.messages.map(\.id), historicalIDs, "Live disk changes must not replace the page being read")
        store.jumpToLatestMessages()
        try await waitUntil { store.messages.last?.id == "live-thinking" }
        XCTAssertEqual(store.messages.last?.textContent, "Fresh live thought")
        XCTAssertNil(store.initialScrollTargetMessageID)
    }

    func testStartingHistoryCancelsAnInFlightLatestRefresh() async throws {
        let file = temporaryDirectory.appendingPathComponent("refresh-race.jsonl")
        try writeLinearConversation(prefix: "race", messageCount: 80, to: file)
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: temporaryDirectory.appendingPathComponent("heartbeats-race", isDirectory: true)
        )
        let repository = DelayedPagingRepository(
            base: FileSessionRepository(rootURL: temporaryDirectory),
            newestDelay: 150_000_000,
            focusedDelay: 300_000_000
        )
        let store = makeStore(repository: repository, activityMonitor: monitor)
        let session = try makeSummary(id: "race", fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path) != nil }
        store.selectSession(session)
        try await waitUntil { store.messages.last?.id == "race-entry-79" }

        let fresh: [String: Any] = [
            "type": "message", "id": "fresh-tail", "parentId": "race-entry-79",
            "message": ["role": "assistant", "content": "Fresh tail"]
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: fresh) + Data([0x0A]))
        try handle.close()
        monitor.tickNow()
        try await Task.sleep(nanoseconds: 50_000_000)

        store.loadEarlierMessages()
        try await waitUntil { store.isBrowsingEarlierHistory && !store.isLoadingEarlierMessages }
        XCTAssertFalse(store.messages.contains { $0.id == "fresh-tail" })

        store.jumpToLatestMessages()
        try await waitUntil { store.messages.last?.id == "fresh-tail" }
    }

    func testLiveTailRefreshReprojectsFinishedSubagents() async throws {
        let file = temporaryDirectory.appendingPathComponent("live-agent.jsonl")
        try writeLinearConversation(prefix: "live-agent", messageCount: 2, to: file)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let launch = ChatMessage(
            id: "launch-message",
            role: .assistant,
            blocks: [PiDesktop.MessageBlock(
                id: "launch-block",
                kind: .toolCall(ToolCallPayload(
                    id: "launch",
                    name: "Agent",
                    arguments: .object([
                        "subagent_type": .string("general-purpose"),
                        "description": .string("Refresh inspector activity")
                    ])
                ))
            )],
            timestamp: startedAt,
            modelName: "gpt-5.6-sol",
            raw: .null
        )
        let launched = ChatMessage(
            id: "launch-result",
            role: .tool,
            blocks: [PiDesktop.MessageBlock(id: "launch-result-text", kind: .text("Agent started in background."))],
            timestamp: startedAt.addingTimeInterval(1),
            toolCallID: "launch",
            details: .object([
                "agentId": .string("agent-1"),
                "status": .string("background")
            ]),
            raw: .null
        )
        let wait = ChatMessage(
            id: "wait-message",
            role: .assistant,
            blocks: [PiDesktop.MessageBlock(
                id: "wait-block",
                kind: .toolCall(ToolCallPayload(
                    id: "wait",
                    name: "get_subagent_result",
                    arguments: .object(["agent_id": .string("agent-1"), "wait": .bool(true)])
                ))
            )],
            timestamp: startedAt.addingTimeInterval(2),
            raw: .null
        )
        let stopped = ChatMessage(
            id: "wait-result",
            role: .tool,
            blocks: [PiDesktop.MessageBlock(id: "wait-result-text", kind: .text("Agent stopped."))],
            timestamp: startedAt.addingTimeInterval(3),
            toolCallID: "wait",
            details: .object(["status": .string("stopped")]),
            raw: .null
        )
        let initial = ConversationPage(
            messages: [launch, launched], olderCursor: nil, leafID: "launch-result",
            rawEntryCount: 2, scannedEntryCount: 2, scannedByteCount: 10, isTruncated: false
        )
        let refreshed = ConversationPage(
            messages: [launch, launched, wait, stopped], olderCursor: nil, leafID: "wait-result",
            rawEntryCount: 4, scannedEntryCount: 4, scannedByteCount: 20, isTruncated: false
        )
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: temporaryDirectory.appendingPathComponent("heartbeats", isDirectory: true)
        )
        let store = makeStore(
            repository: ScriptedPagingRepository(newestPages: [initial, refreshed]),
            activityMonitor: monitor
        )
        let session = try makeSummary(id: "live-agent", fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path) != nil }

        store.selectSession(session)
        try await waitUntil { store.activities.first?.status == .running }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"custom\"}\n".utf8))
        try handle.close()
        monitor.tickNow()

        try await waitUntil { store.activities.first?.status == .stopped }
    }

    func testSettledTurnRefreshesGitWhileTheAppIsInactive() async throws {
        let file = temporaryDirectory.appendingPathComponent("inactive-git.jsonl")
        try writeLinearConversation(prefix: "inactive-git", messageCount: 2, to: file)
        var dirty = GitSnapshot(isRepository: true, branch: "main")
        dirty.files = [GitFileChange(path: "stale.txt", additions: 10, deletions: 0, isBinary: false, isUntracked: false)]
        let git = MutableGitService(dirty)
        let runtime = FakeRuntime()
        runtime.sessionFile = file.path
        runtime.sessionID = "inactive-git"
        let store = makeStore(
            repository: FileSessionRepository(rootURL: temporaryDirectory),
            gitService: git,
            runtime: runtime,
            isActiveOverride: false
        )
        let session = try makeSummary(id: "inactive-git", fileURL: file)
        store.sessions = [session]
        store.selectSession(session)
        store.renameSession(session, to: "Attach runtime")
        try await waitUntil { store.isSelectedRuntime && store.selectedGit.isDirty }

        await git.set(GitSnapshot(isRepository: true, branch: "main"))
        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))

        try await waitUntil { store.selectedGit.isRepository && !store.selectedGit.isDirty }
    }

    func testLiveRefreshScanTruncationDoesNotFlagLoadedHistoryOutsideTheWindow() async throws {
        // Regression: a live refresh whose newest-page scan hit its byte budget used to OR its
        // own `isTruncated` into the merged page. With the loaded history complete (no older
        // cursor), that flipped "Earlier history is outside this bounded window" on for a
        // conversation whose history was fully loaded.
        let file = temporaryDirectory.appendingPathComponent("scripted.jsonl")
        try writeLinearConversation(prefix: "scripted", messageCount: 4, to: file)
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: temporaryDirectory.appendingPathComponent("heartbeats", isDirectory: true)
        )

        func message(_ id: String, role: PiDesktop.MessageRole, text: String) -> ChatMessage {
            ChatMessage(id: id, role: role, blocks: [PiDesktop.MessageBlock(id: "\(id)-text", kind: .text(text))], timestamp: nil, raw: .null)
        }
        let m1 = message("m1", role: .user, text: "question")
        let m2 = message("m2", role: .assistant, text: "answer")
        let m3 = message("m3", role: .assistant, text: "appended")
        let initial = ConversationPage(
            messages: [m1, m2], olderCursor: nil, leafID: "m2",
            rawEntryCount: 2, scannedEntryCount: 2, scannedByteCount: 10, isTruncated: false
        )
        let truncatedRefresh = ConversationPage(
            messages: [m2, m3], olderCursor: nil, leafID: "m3",
            rawEntryCount: 2, scannedEntryCount: 2, scannedByteCount: 10, isTruncated: true
        )
        let store = makeStore(
            repository: ScriptedPagingRepository(newestPages: [initial, truncatedRefresh]),
            activityMonitor: monitor
        )
        let session = try makeSummary(id: "scripted", fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path) != nil }

        store.selectSession(session)
        try await waitUntil { store.messages.count == 2 }
        XCTAssertFalse(store.conversationHistoryLimitReached)
        XCTAssertFalse(store.hasEarlierMessages)

        // Change the fingerprint so the next activity snapshot triggers a newest-page refresh.
        let entry: [String: Any] = [
            "type": "message", "id": "scripted-entry-4", "parentId": "scripted-entry-3",
            "message": ["role": "assistant", "content": "scripted-4"]
        ]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: entry) + Data([0x0A]))
        try handle.close()
        monitor.tickNow()

        try await waitUntil { store.messages.count == 3 }
        XCTAssertEqual(store.messages.map(\.id), ["m1", "m2", "m3"], "The refresh merges through the overlap")
        XCTAssertFalse(
            store.conversationHistoryLimitReached,
            "A refresh page's own scan truncation must not mark fully loaded history as outside the window"
        )
        XCTAssertFalse(store.hasEarlierMessages)
    }

    func testStreamingDeltasCoalesceAndAMessageEndCancelsThePendingPublish() async throws {
        let file = temporaryDirectory.appendingPathComponent("stream.jsonl")
        try writeLinearConversation(prefix: "stream", messageCount: 2, to: file)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let session = try makeSummary(id: "stream", fileURL: file)
        store.sessions = [session]
        store.selectSession(session)
        store.renameSession(session, to: "Attach runtime")
        try await waitUntil { store.isSelectedRuntime }

        func update(_ text: String) -> JSONValue {
            .object([
                "type": .string("message_update"),
                "message": .object(["role": .string("assistant"), "content": .string(text)])
            ])
        }

        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.handleRPCEventForTesting(update("first"))
        XCTAssertEqual(store.streamingMessage?.textContent, "first", "The first delta publishes immediately")

        store.handleRPCEventForTesting(update("second"))
        store.handleRPCEventForTesting(update("third"))
        XCTAssertEqual(store.streamingMessage?.textContent, "first", "A burst coalesces instead of publishing per delta")
        try await waitUntil { store.streamingMessage?.textContent == "third" }

        store.handleRPCEventForTesting(update("stale trailing"))
        store.handleRPCEventForTesting(.object([
            "type": .string("message_end"),
            "message": .object(["role": .string("assistant"), "content": .string("done")])
        ]))
        XCTAssertNil(store.streamingMessage)
        XCTAssertEqual(store.messages.last?.textContent, "done")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.streamingMessage, "A cancelled trailing publish must never resurrect a settled stream")
    }

    func testDuplicatePiSessionIDsStillSelectByFilePath() async throws {
        let fileA = temporaryDirectory.appendingPathComponent("duplicate-a.jsonl")
        let fileB = temporaryDirectory.appendingPathComponent("duplicate-b.jsonl")
        try writeLinearConversation(prefix: "a", messageCount: 2, to: fileA)
        try writeLinearConversation(prefix: "b", messageCount: 2, to: fileB)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let a = try makeSummary(id: "duplicate", fileURL: fileA)
        let b = try makeSummary(id: "duplicate", fileURL: fileB)
        store.sessions = [a, b]

        store.selectSession(a)
        try await waitUntil { store.messages.last?.textContent == "a-1" }
        store.selectSession(b)
        try await waitUntil { store.messages.last?.textContent == "b-1" }

        XCTAssertEqual(store.route, .session(fileB.standardizedFileURL.path))
        XCTAssertEqual(store.selectedSession?.fileURL.standardizedFileURL, fileB.standardizedFileURL)
    }

    func testSelectingASessionInAWorktreePopulatesSelectedWorktree() async throws {
        let file = temporaryDirectory.appendingPathComponent("wt.jsonl")
        try writeLinearConversation(prefix: "wt", messageCount: 2, to: file)
        let worktree = GitWorktreeInfo(path: temporaryDirectory.path, branch: "feat/x", mainWorktreePath: "/main")
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory), gitService: FakeGitService(worktree: worktree))
        let session = try makeSummary(id: "wt", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.selectedWorktree != nil }
        XCTAssertEqual(store.selectedWorktree?.branch, "feat/x")
        XCTAssertEqual(store.selectedWorktree?.mainName, "main")
    }

    func testConversationFollowsAWorktreeRecordedInItsToolCalls() async throws {
        let project = temporaryDirectory.appendingPathComponent("project", isDirectory: true)
        let worktreeRoot = temporaryDirectory.appendingPathComponent("feature-inspector", isDirectory: true)
        let source = worktreeRoot.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let file = temporaryDirectory.appendingPathComponent("moved.jsonl")
        try writeJSONL([
            ["type": "session", "version": 3, "id": "moved", "cwd": project.path],
            ["type": "message", "id": "user", "parentId": NSNull(), "message": ["role": "user", "content": "Fix it"]],
            [
                "type": "message", "id": "assistant", "parentId": "user",
                "message": [
                    "role": "assistant", "stopReason": "toolUse",
                    "content": [[
                        "type": "toolCall", "id": "edit-1", "name": "edit",
                        "arguments": ["path": source.path]
                    ]]
                ]
            ]
        ], to: file)
        let worktree = GitWorktreeInfo(path: worktreeRoot.path, branch: "feat/inspector", mainWorktreePath: project.path)
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory), gitService: FakeGitService(worktree: worktree))
        let session = try makeSummary(id: "moved", fileURL: file, cwd: project)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.selectedWorktree?.name == "feature-inspector" }
        XCTAssertEqual(store.selectedWorktree?.path, worktreeRoot.path)
    }

    func testLiveToolCallMovesConversationIntoNamedWorktree() async throws {
        let project = temporaryDirectory.appendingPathComponent("live-project", isDirectory: true)
        let worktreeRoot = temporaryDirectory.appendingPathComponent("live-feature", isDirectory: true)
        let source = worktreeRoot.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = temporaryDirectory.appendingPathComponent("live-worktree.jsonl")
        try writeLinearConversation(prefix: "live-worktree", messageCount: 2, to: file)

        let runtime = FakeRuntime()
        runtime.sessionFile = file.path
        runtime.sessionID = "live-worktree"
        let worktree = GitWorktreeInfo(path: worktreeRoot.path, branch: "feat/live", mainWorktreePath: project.path)
        let store = makeStore(
            repository: FileSessionRepository(rootURL: temporaryDirectory),
            gitService: FakeGitService(worktree: worktree),
            runtime: runtime
        )
        let session = try makeSummary(id: "live-worktree", fileURL: file, cwd: project)
        store.sessions = [session]
        store.selectSession(session)
        store.renameSession(session, to: "Attach runtime")
        try await waitUntil { store.isSelectedRuntime }

        store.handleRPCEventForTesting(.object([
            "type": .string("tool_execution_start"),
            "toolCallId": .string("edit-live"),
            "toolName": .string("edit"),
            "args": .object(["path": .string(source.path)])
        ]))

        try await waitUntil { store.selectedWorktree?.name == "live-feature" }
    }

    func testAPlainCheckoutNeverPopulatesSelectedWorktree() async throws {
        let file = temporaryDirectory.appendingPathComponent("plain.jsonl")
        try writeLinearConversation(prefix: "plain", messageCount: 2, to: file)
        // The default `FakeGitService` (worktree == nil) mirrors a conformer that never
        // implements `worktreeInfo`, exercising the protocol's own default (always `nil`).
        let store = makeStore(repository: FileSessionRepository(rootURL: temporaryDirectory))
        let session = try makeSummary(id: "plain", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { store.messages.count == 2 }
        XCTAssertNil(store.selectedWorktree)
    }

    // MARK: - Helpers

    private func makeStore(
        repository: SessionRepositoryProtocol,
        gitService: GitStatusProviding = FakeGitService(),
        runtime: AgentRuntimeProtocol = FakeRuntime(),
        persistence: AppPersistence? = nil,
        activityMonitor: SessionActivityMonitor? = nil,
        isActiveOverride: Bool? = nil
    ) -> AppStore {
        AppStore(
            repository: repository,
            gitService: gitService,
            runtime: runtime,
            persistence: persistence ?? AppPersistence(baseURL: temporaryDirectory),
            activityPresenter: ActivityPresenter(),
            activityMonitor: activityMonitor,
            isActiveOverride: isActiveOverride
        )
    }

    private func makeSummary(id: String, fileURL: URL, cwd: URL? = nil) throws -> SessionSummary {
        var value = SessionSummary(
            id: id, fileURL: fileURL, cwd: cwd ?? temporaryDirectory,
            createdAt: Date(), modifiedAt: Date(), name: id, preview: "preview",
            messageCount: 0, metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }

    /// A simple, strictly linear (no branches) session fixture: `messageCount` alternating
    /// user/assistant messages, each with distinct, greppable text `"<prefix>-<index>"`.
    private func writeLinearConversation(prefix: String, messageCount: Int, to url: URL) throws {
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": prefix, "cwd": url.deletingLastPathComponent().path]]
        var parent: Any = NSNull()
        for index in 0..<messageCount {
            let id = "\(prefix)-entry-\(index)"
            lines.append([
                "type": "message", "id": id, "parentId": parent,
                "message": ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": "\(prefix)-\(index)"]
            ])
            parent = id
        }
        try writeJSONL(lines, to: url)
    }

    private func writeJSONL(_ lines: [[String: Any]], to url: URL) throws {
        let data = try lines.reduce(into: Data()) { output, line in
            output.append(try JSONSerialization.data(withJSONObject: line))
            output.append(0x0A)
        }
        try data.write(to: url)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}
