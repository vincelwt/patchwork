import Foundation
import XCTest
@testable import PiDesktop

private final class ParallelFakeRuntime: PiRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionFile: String
    var sessionID: String
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [(command: String, payload: [String: JSONValue])] = []

    init(sessionFile: String, sessionID: String) {
        self.sessionFile = sessionFile
        self.sessionID = sessionID
    }

    func start(cwd: URL, sessionPath: URL?) throws {
        isRunning = true
        startCount += 1
    }

    func stop() {
        isRunning = false
        stopCount += 1
    }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        sent.append((type, payload))
        if type == "prompt" { return } // Keep the turn live until the test emits agent_settled.
        let data: JSONValue
        switch type {
        case "get_state":
            data = .object([
                "isStreaming": .bool(false),
                "sessionFile": .string(sessionFile),
                "sessionId": .string(sessionID)
            ])
        case "get_messages":
            data = .object(["messages": .array([])])
        case "get_available_models":
            data = .object(["models": .array([])])
        case "get_available_thinking_levels":
            data = .object(["levels": .array([.string("off")])])
        default:
            data = .object([:])
        }
        completion?(.success(.object(["success": .bool(true), "data": data])))
    }

    func sendUncorrelated(_ value: JSONValue) {}

    func commandCount(_ command: String) -> Int { sent.filter { $0.command == command }.count }
}

private struct ParallelFakeRepository: SessionRepositoryProtocol {
    let rootURL: URL
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw CancellationError()
    }
}

private struct ParallelFakeGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

@MainActor
final class AppStoreParallelRuntimeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiParallelRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDifferentConversationsRunInParallelAndKeepTheirLiveStateIsolated() throws {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()

        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        XCTAssertEqual(runtimeA.commandCount("prompt"), 1)
        XCTAssertTrue(store.runtimeState.isStreaming)
        store.enqueueOutbox(text: "steer A", delivery: .steer)

        store.selectSession(sessionB)
        runtimeA.onEvent?(.object([
            "type": .string("extension_ui_request"),
            "method": .string("input"),
            "id": .string("dialog-a"),
            "title": .string("A needs input")
        ]))
        XCTAssertNil(store.activeDialog, "A's dialog must not appear in B")
        store.draft = "task B"
        store.submitDraft()

        XCTAssertEqual(runtimeA.stopCount, 0, "Starting B must not stop A")
        XCTAssertEqual(runtimeB.commandCount("prompt"), 1)
        XCTAssertTrue(store.isRunning(sessionA))
        XCTAssertTrue(store.isRunning(sessionB))
        XCTAssertTrue(store.outbox.isEmpty, "A's outbox must not appear in B")

        runtimeA.onEvent?(.object(["type": .string("turn_end")]))
        XCTAssertEqual(runtimeA.commandCount("steer"), 1)
        XCTAssertEqual(runtimeB.commandCount("steer"), 0)
        runtimeA.onEvent?(.object([
            "type": .string("message_update"),
            "message": assistantMessage("A is still working")
        ]))
        XCTAssertNil(store.streamingMessage, "A's partial answer must not appear in B")

        store.selectSession(sessionA)
        store.prepareComposerOptions()
        XCTAssertEqual(store.activeDialog?.id, "dialog-a")
        XCTAssertEqual(store.streamingMessage?.textContent, "A is still working")
        XCTAssertTrue(store.runtimeState.isStreaming)

        store.abort()
        XCTAssertEqual(runtimeA.commandCount("abort"), 1)
        XCTAssertEqual(runtimeB.commandCount("abort"), 0)
    }

    func testSettledBackgroundRuntimeIsRetiredWithoutStoppingTheSelectedRun() {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()

        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()

        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))

        XCTAssertEqual(runtimeA.stopCount, 1)
        XCTAssertEqual(runtimeB.stopCount, 0)
        XCTAssertTrue(store.isRunning(sessionB))
    }

    func testAcceptedFollowUpIsNotKilledBeforeItsNextAgentStart() {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        store.enqueueOutbox(text: "continue A", delivery: .followUp)

        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(runtimeA.commandCount("follow_up"), 1)
        XCTAssertFalse(store.runtimeState.isStreaming)

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()

        XCTAssertEqual(runtimeA.stopCount, 0, "An accepted follow-up still owns A's runtime")
        XCTAssertEqual(runtimeB.commandCount("prompt"), 1)
    }

    func testNewChatCanStartWhileAnotherConversationIsWorking() {
        let sessionA = summary(id: "session-a", file: "a.jsonl")
        let newSessionFile = directory.appendingPathComponent("new.jsonl")
        let runtimeA = ParallelFakeRuntime(sessionFile: sessionA.fileURL.path, sessionID: sessionA.id)
        let newRuntime = ParallelFakeRuntime(sessionFile: newSessionFile.path, sessionID: "new-session")
        let store = AppStore(
            repository: ParallelFakeRepository(rootURL: directory),
            gitService: ParallelFakeGitService(),
            runtime: runtimeA,
            runtimeFactory: { newRuntime },
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter(),
            isActiveOverride: true
        )
        store.sessions = [sessionA]
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()

        store.openNewChat()
        store.selectedFolder = directory
        store.draft = "task in a new conversation"
        store.submitDraft()

        XCTAssertEqual(runtimeA.stopCount, 0)
        XCTAssertEqual(newRuntime.commandCount("prompt"), 1)
        XCTAssertEqual(store.route, .session(newSessionFile.standardizedFileURL.path))
        XCTAssertTrue(store.sessions.contains { $0.id == "new-session" })
    }

    private func makeStore() -> (AppStore, ParallelFakeRuntime, ParallelFakeRuntime, SessionSummary, SessionSummary) {
        let sessionA = summary(id: "session-a", file: "a.jsonl")
        let sessionB = summary(id: "session-b", file: "b.jsonl")
        let runtimeA = ParallelFakeRuntime(sessionFile: sessionA.fileURL.path, sessionID: sessionA.id)
        let runtimeB = ParallelFakeRuntime(sessionFile: sessionB.fileURL.path, sessionID: sessionB.id)
        var spareRuntimes = [runtimeB]
        let store = AppStore(
            repository: ParallelFakeRepository(rootURL: directory),
            gitService: ParallelFakeGitService(),
            runtime: runtimeA,
            runtimeFactory: { spareRuntimes.removeFirst() },
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter(),
            isActiveOverride: true
        )
        store.sessions = [sessionA, sessionB]
        return (store, runtimeA, runtimeB, sessionA, sessionB)
    }

    private func summary(id: String, file: String) -> SessionSummary {
        var summary = SessionSummary(
            id: id,
            fileURL: directory.appendingPathComponent(file),
            cwd: directory,
            createdAt: Date(),
            modifiedAt: Date(),
            name: id,
            preview: "preview",
            messageCount: 0,
            metrics: TokenMetrics()
        )
        summary.prepareSearchKey()
        return summary
    }

    private func assistantMessage(_ text: String) -> JSONValue {
        .object([
            "id": .string("assistant-a"),
            "role": .string("assistant"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ])
    }
}
