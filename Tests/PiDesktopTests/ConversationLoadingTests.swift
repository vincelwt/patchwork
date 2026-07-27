import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Fakes

private final class FakeRuntime: PiRuntimeProtocol {
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
    func worktreeInfo(for directory: URL) async -> GitWorktreeInfo? { worktree }
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

/// Delays only the *full* parse, leaving the tail scan fast: on a tiny fixture file both steps
/// would otherwise finish inside a single poll tick, making the intermediate partial-paint state
/// unobservable. This reopens a reliable window to assert on it.
private struct TailFastFullSlowRepository: SessionRepositoryProtocol {
    let base: FileSessionRepository
    let fullParseDelayNanoseconds: UInt64
    var rootURL: URL { base.rootURL }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        try await base.discoverSessions(archivedIDs: archivedIDs)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        try await base.refreshSummary(at: fileURL, archivedIDs: archivedIDs)
    }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        try await Task.sleep(nanoseconds: fullParseDelayNanoseconds)
        return try await base.loadConversation(from: fileURL)
    }
    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan {
        try await base.loadConversationTail(from: fileURL, limit: limit)
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

    func testCacheMissPaintsThePartialTailImmediatelyThenBackfillsWithoutChangingTheVisibleTail() async throws {
        let file = temporaryDirectory.appendingPathComponent("big.jsonl")
        try writeLinearConversation(prefix: "big", messageCount: 80, to: file)
        // The full parse is held back so the partial-tail state has a reliably observable window
        // — otherwise both steps finish inside a single fixture-sized parse and the intermediate
        // state is never visible to poll against.
        let repository = TailFastFullSlowRepository(base: FileSessionRepository(rootURL: temporaryDirectory), fullParseDelayNanoseconds: 300_000_000)
        let store = makeStore(repository: repository)
        let session = try makeSummary(id: "big", fileURL: file)
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { !store.messages.isEmpty }
        // The very first non-empty paint must already be the true tail: fewer than the full 80
        // messages (a partial preview), ending on the conversation's real last message.
        let firstPaintCount = store.messages.count
        let firstPaintTailID = store.messages.last?.id
        XCTAssertLessThan(firstPaintCount, 80, "The first paint must be a partial tail, not the full parse")
        XCTAssertEqual(store.messages.last?.textContent, "big-79", "The tail is already the newest message")
        XCTAssertFalse(store.isConversationLoading, "A partial paint is still a paint — no spinner once there is something to show")

        try await waitUntil { store.messages.count == 80 }
        XCTAssertEqual(store.messages.last?.id, firstPaintTailID, "Backfilling earlier history must never change what was already shown at the bottom")
        XCTAssertFalse(store.isConversationLoading)
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

    private func makeStore(repository: SessionRepositoryProtocol, gitService: GitStatusProviding = FakeGitService()) -> AppStore {
        AppStore(
            repository: repository,
            gitService: gitService,
            runtime: FakeRuntime(),
            persistence: AppPersistence(baseURL: temporaryDirectory),
            activityPresenter: ActivityPresenter()
        )
    }

    private func makeSummary(id: String, fileURL: URL) throws -> SessionSummary {
        var value = SessionSummary(
            id: id, fileURL: fileURL, cwd: temporaryDirectory,
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
