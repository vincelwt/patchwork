import Combine
import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Pure DraftStore

final class DraftStoreTests: XCTestCase {
    func testSetAndGetRoundTrip() {
        var store = DraftStore()
        store.set("hello", for: "/a")
        XCTAssertEqual(store.text(for: "/a"), "hello")
        XCTAssertEqual(store.text(for: "/missing"), "", "An unknown key reads back empty, never crashes")
    }

    func testEmptyTextRemovesTheEntryOutright() {
        var store = DraftStore(texts: ["/a": "existing"])
        store.set("", for: "/a")
        XCTAssertEqual(store.text(for: "/a"), "")
        XCTAssertFalse(store.texts.keys.contains("/a"), "A cleared draft leaves no trace in state.json")
    }

    func testOversizedDraftsAreTruncatedRatherThanRejected() {
        var store = DraftStore()
        let huge = String(repeating: "x", count: DraftStore.maxDraftLength + 5_000)
        store.set(huge, for: "/a")
        XCTAssertEqual(store.text(for: "/a").count, DraftStore.maxDraftLength)
    }

    func testEvictionKeepsTheCapAndDropsTheLeastRecentlyTouchedKey() {
        var store = DraftStore()
        for index in 0..<(DraftStore.maxRetainedDrafts + 10) {
            store.set("draft \(index)", for: "/session-\(index)")
        }
        XCTAssertEqual(store.texts.count, DraftStore.maxRetainedDrafts)
        // The oldest ten were evicted; the newest is intact.
        XCTAssertEqual(store.text(for: "/session-0"), "")
        XCTAssertEqual(store.text(for: "/session-9"), "")
        XCTAssertEqual(store.text(for: "/session-10"), "draft 10")
        XCTAssertEqual(store.text(for: "/session-\(DraftStore.maxRetainedDrafts + 9)"), "draft \(DraftStore.maxRetainedDrafts + 9)")
    }

    func testTouchingAnOldKeyAgainProtectsItFromEviction() {
        var store = DraftStore()
        for index in 0..<DraftStore.maxRetainedDrafts {
            store.set("draft \(index)", for: "/session-\(index)")
        }
        // Re-touch the very first key so it becomes the most recently used.
        store.set("draft 0 revised", for: "/session-0")
        // One more insertion should now evict session-1 (now the oldest), not session-0.
        store.set("draft new", for: "/session-new")
        XCTAssertEqual(store.text(for: "/session-0"), "draft 0 revised", "Touched again: protected from eviction")
        XCTAssertEqual(store.text(for: "/session-1"), "", "Now the least recently touched: evicted")
    }

    func testLoadingAnOversizedDictionaryTrimsBackIntoBoundsImmediately() {
        var seed: [String: String] = [:]
        for index in 0..<(DraftStore.maxRetainedDrafts + 25) { seed["/session-\(index)"] = "d\(index)" }
        let store = DraftStore(texts: seed)
        XCTAssertEqual(store.texts.count, DraftStore.maxRetainedDrafts)
    }
}

// MARK: - AppStore integration

private final class FakeRuntime: PiRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionFile = ""
    var sessionID = ""
    private var pending: [String: (Result<JSONValue, Error>) -> Void] = [:]

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        switch type {
        case "get_state":
            completion?(.success(.object([
                "success": .bool(true),
                "data": .object([
                    "isStreaming": .bool(false),
                    "sessionFile": .string(sessionFile),
                    "sessionId": .string(sessionID)
                ])
            ])))
        default:
            if let completion { pending[type] = completion }
        }
    }

    func sendUncorrelated(_ value: JSONValue) {}

    func succeed(_ command: String) {
        pending.removeValue(forKey: command)?(.success(.object(["success": .bool(true), "data": .object([:])])))
    }
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/pi-desktop-draft-tests")
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw CancellationError()
    }
}

private struct FakeGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

@MainActor
final class DraftPersistenceIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiDrafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(persistence: AppPersistence, runtime: PiRuntimeProtocol = FakeRuntime()) -> AppStore {
        AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            persistence: persistence,
            activityPresenter: ActivityPresenter()
        )
    }

    private func summary(id: String, file: String) -> SessionSummary {
        var value = SessionSummary(
            id: id, fileURL: directory.appendingPathComponent(file), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: id, preview: "preview",
            messageCount: 0, metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }

    func testComposerTypingDoesNotInvalidateTheWholeAppStore() {
        let store = makeStore(persistence: AppPersistence(baseURL: directory))
        var appInvalidations = 0
        var composerInvalidations = 0
        let appObservation = store.objectWillChange.sink { appInvalidations += 1 }
        let composerObservation = store.composer.objectWillChange.sink { composerInvalidations += 1 }

        store.draft = "native key repeat"

        XCTAssertEqual(appInvalidations, 0)
        XCTAssertEqual(composerInvalidations, 1)
        withExtendedLifetime((appObservation, composerObservation)) {}
    }

    func testSwitchingAwayAndBackKeepsTheDraftText() {
        let store = makeStore(persistence: AppPersistence(baseURL: directory))
        let a = summary(id: "a", file: "a.jsonl")
        let b = summary(id: "b", file: "b.jsonl")
        store.sessions = [a, b]

        store.selectSession(a)
        store.draft = "draft for A"
        store.selectSession(b)
        XCTAssertEqual(store.draft, "", "A different conversation starts with its own (empty) draft")
        store.selectSession(a)
        XCTAssertEqual(store.draft, "draft for A", "Switching back restores what was typed")
    }

    func testReinstantiatingPersistenceFromTheSameFileKeepsTheDraft() {
        let a = summary(id: "a", file: "a.jsonl")

        let persistence1 = AppPersistence(baseURL: directory)
        let store1 = makeStore(persistence: persistence1)
        store1.sessions = [a]
        store1.selectSession(a)
        store1.draft = "typed before quitting"
        // A conversation switch flushes immediately rather than waiting on the idle debounce.
        store1.openNewChat()

        let persistence2 = AppPersistence(baseURL: directory)
        XCTAssertEqual(persistence2.state.drafts[a.fileURL.standardizedFileURL.path], "typed before quitting")

        let store2 = makeStore(persistence: persistence2)
        store2.sessions = [a]
        store2.selectSession(a)
        XCTAssertEqual(store2.draft, "typed before quitting", "A relaunch restores the same conversation's draft")
    }

    func testSendingClearsTheDraftForThatConversationOnly() {
        let runtime = FakeRuntime()
        let store = makeStore(persistence: AppPersistence(baseURL: directory), runtime: runtime)
        let a = summary(id: "a", file: "a.jsonl")
        let b = summary(id: "b", file: "b.jsonl")
        store.sessions = [a, b]

        store.selectSession(b)
        store.draft = "unrelated, untouched"

        store.selectSession(a)
        runtime.sessionFile = a.fileURL.path
        runtime.sessionID = a.id
        store.draft = "prompt for A"
        store.submitDraft()
        XCTAssertEqual(store.draft, "")

        store.selectSession(b)
        XCTAssertEqual(store.draft, "unrelated, untouched", "Sending in A must not touch B's draft")
        store.selectSession(a)
        XCTAssertEqual(store.draft, "", "A's draft stays cleared after sending, even after navigating away and back")
    }

    func testOversizedDraftIsTruncatedWhenPersisted() {
        let persistence = AppPersistence(baseURL: directory)
        let store = makeStore(persistence: persistence)
        let a = summary(id: "a", file: "a.jsonl")
        store.sessions = [a]
        store.selectSession(a)

        store.draft = String(repeating: "y", count: DraftStore.maxDraftLength + 1_000)
        store.openNewChat() // flush immediately

        let key = a.fileURL.standardizedFileURL.path
        XCTAssertEqual(persistence.state.drafts[key]?.count, DraftStore.maxDraftLength)
    }
}
