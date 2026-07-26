import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Fakes (mirrors the pattern in AppStoreRollbackTests.swift, private to this file)

private final class FakeRuntime: PiRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    private(set) var sent: [String] = []
    private var pending: [String: (Result<JSONValue, Error>) -> Void] = [:]
    var sessionFile = ""
    var sessionID = ""

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        sent.append(type)
        switch type {
        case "get_state":
            completion?(.success(.object([
                "type": .string("response"), "success": .bool(true),
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

    func commandCount(_ command: String) -> Int { sent.filter { $0 == command }.count }
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/pi-desktop-edit-tests")
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
final class AppStoreMessageEditingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiEditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Arming

    func testBeginEditingLoadsTheLastUserMessageIntoTheComposer() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.draft = "the original question"
        store.submitDraft()
        XCTAssertEqual(store.draft, "", "Sending clears the composer as usual")

        store.draft = "something I was about to type"
        store.beginEditingLastMessage()

        XCTAssertEqual(store.draft, "the original question", "Editing overwrites the composer with the last turn's text")
        XCTAssertTrue(store.isEditingLastMessage)
    }

    func testBeginEditingWithNoUserMessageYetIsANoOp() {
        let (store, _, _) = makeStore()
        store.draft = "unrelated draft"
        store.beginEditingLastMessage()
        XCTAssertEqual(store.draft, "unrelated draft")
        XCTAssertFalse(store.isEditingLastMessage)
    }

    func testCancelEditingDisarmsWithoutTouchingTheComposerText() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.draft = "original"
        store.submitDraft()
        store.beginEditingLastMessage()
        store.draft = "edited text still in progress"

        store.cancelEditingLastMessage()

        XCTAssertFalse(store.isEditingLastMessage)
        XCTAssertEqual(store.draft, "edited text still in progress", "Cancelling the armed state alone must not clear what the user typed")
    }

    func testSwitchingConversationsMidEditDisarmsIt() {
        let (store, runtime, session) = makeStore()
        let other = summary(id: "session-b", file: "b.jsonl")
        store.sessions.append(other)
        attach(store, runtime, session)
        store.draft = "original"
        store.submitDraft()
        store.beginEditingLastMessage()
        XCTAssertTrue(store.isEditingLastMessage)

        store.selectSession(other)

        XCTAssertFalse(store.isEditingLastMessage, "A route change must disarm a stale edit rather than let it resubmit into the wrong conversation")
    }

    // MARK: - Resubmitting while idle

    func testResubmitWhileIdleSendsTheEditedTextAsAFreshPrompt() async throws {
        // Seeded directly (not via submitDraft) so the conversation has a settled turn in its
        // history without also leaving `runtimeState.isStreaming` optimistically true — exactly
        // what "idle" means for this test.
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        seedUserMessage(store, text: "original question")

        store.beginEditingLastMessage()
        store.draft = "corrected question"
        store.resubmitEditedMessage()

        await waitUntil { runtime.commandCount("prompt") == 1 }
        XCTAssertEqual(runtime.commandCount("prompt"), 1, "Resubmitting while idle sends one fresh prompt")
        XCTAssertEqual(runtime.commandCount("abort"), 0, "There is nothing running, so nothing should be aborted")
        XCTAssertFalse(store.isEditingLastMessage)
        XCTAssertEqual(store.draft, "", "submitDraft's own clearing still applies")
    }

    func testResubmitWithEmptyContentCancelsInsteadOfSending() async throws {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        seedUserMessage(store, text: "original question")
        store.beginEditingLastMessage()
        store.draft = "   "
        store.attachments = []

        store.resubmitEditedMessage()
        await waitUntil { !store.isEditingLastMessage }

        XCTAssertEqual(runtime.commandCount("prompt"), 0, "Nothing new was sent")
        XCTAssertFalse(store.isEditingLastMessage)
    }

    func testResubmitWithAStaleTargetDisarmsWithoutSending() async throws {
        // The armed message no longer exists on the branch (e.g. history changed underneath it).
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        seedUserMessage(store, text: "original question")
        store.beginEditingLastMessage()
        store.messages.removeAll()

        store.resubmitEditedMessage()
        await waitUntil { !store.isEditingLastMessage }

        XCTAssertEqual(runtime.commandCount("prompt"), 0)
    }

    // MARK: - Resubmitting mid-turn

    func testResubmitMidTurnAbortsThenSendsOnceTheRunSettles() async throws {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.draft = "original question"
        store.submitDraft()
        XCTAssertTrue(store.runtimeState.isStreaming, "submitDraft optimistically marks the turn as streaming")

        store.beginEditingLastMessage()
        store.draft = "corrected mid-answer"
        store.resubmitEditedMessage()

        await waitUntil { runtime.commandCount("abort") == 1 }
        XCTAssertEqual(runtime.commandCount("prompt"), 1, "The resend must wait for the abort to actually settle")

        // Pi confirms the run stopped.
        runtime.onEvent?(.object(["type": .string("agent_settled")]))

        await waitUntil { runtime.commandCount("prompt") == 2 }
        XCTAssertEqual(runtime.commandCount("prompt"), 2)
        XCTAssertTrue(store.runtimeState.isStreaming, "The resend itself starts a new turn")
    }

    func testResubmitInvokedTwiceInARowNeverSendsTwice() async throws {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.draft = "original question"
        store.submitDraft()
        store.beginEditingLastMessage()
        store.draft = "corrected mid-answer"

        // Two taps before anything has a chance to settle.
        store.resubmitEditedMessage()
        store.resubmitEditedMessage()

        // Only once the in-flight abort is actually observed does settling it become meaningful;
        // firing the event any earlier would race the guard this test exists to cover.
        await waitUntil { runtime.commandCount("abort") == 1 }
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        await waitUntil { runtime.commandCount("prompt") == 2 }

        // Give any stray second resubmission a chance to land before asserting it never did.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runtime.commandCount("prompt"), 2, "Exactly one resend, never two")
        XCTAssertEqual(runtime.commandCount("abort"), 1, "Exactly one abort, never two")
    }

    // MARK: - Helpers

    private func makeStore() -> (AppStore, FakeRuntime, SessionSummary) {
        let runtime = FakeRuntime()
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter()
        )
        let session = summary(id: "session-a", file: "a.jsonl")
        store.sessions = [session]
        return (store, runtime, session)
    }

    /// Selects the session and points the fake runtime's `get_state` at it, so `isSelectedRuntime`
    /// is true the way it would be for a real attached conversation.
    private func attach(_ store: AppStore, _ runtime: FakeRuntime, _ session: SessionSummary) {
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
    }

    private func seedUserMessage(_ store: AppStore, text: String) {
        store.messages.append(ChatMessage(
            id: "seed-\(UUID().uuidString)", role: .user,
            blocks: [MessageBlock(id: UUID().uuidString, kind: .text(text))],
            timestamp: Date(), raw: .null
        ))
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

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
