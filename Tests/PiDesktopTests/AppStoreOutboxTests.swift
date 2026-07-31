import PiDeskKit
import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Fakes (mirrors the pattern in AppStoreMessageEditingTests.swift, private to this file)

private final class FakeRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    private(set) var stopCount = 0
    private(set) var sent: [(type: String, payload: [String: JSONValue])] = []
    var sessionFile = ""
    var sessionID = ""
    var followUpError: Error?
    var delayNextState = false
    private var pendingState: ((Result<JSONValue, Error>) -> Void)?

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false; stopCount += 1 }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        sent.append((type, payload))
        switch type {
        case "prompt", "follow_up":
            if let followUpError { completion?(.failure(followUpError)) }
            else { completion?(.success(.object(["success": .bool(true), "data": .object([:])]))) }
        case "get_state" where delayNextState:
            delayNextState = false
            pendingState = completion
        case "get_state":
            completion?(stateResponse())
        default:
            completion?(.success(.object(["success": .bool(true), "data": .object([:])])))
        }
    }

    func sendUncorrelated(_ value: JSONValue) {}

    func finishDelayedState() { pendingState?(stateResponse()); pendingState = nil }
    func commandCount(_ command: String) -> Int { sent.filter { $0.type == command }.count }
    func lastPayload(_ command: String) -> [String: JSONValue]? { sent.last { $0.type == command }?.payload }

    private func stateResponse() -> Result<JSONValue, Error> {
        .success(.object([
            "type": .string("response"), "success": .bool(true),
            "data": .object([
                "isStreaming": .bool(false),
                "sessionFile": .string(sessionFile),
                "sessionId": .string(sessionID)
            ])
        ]))
    }
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/pi-desktop-outbox-tests")
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

/// End-to-end coverage for immediate steering and follow-ups held until `agent_settled`.
@MainActor
final class AppStoreOutboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testActiveComposerSendSteersImmediatelyBeforeTurnEnd() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.draft = "change direction"

        store.submitDraft()

        XCTAssertEqual(runtime.commandCount("steer"), 1)
        XCTAssertEqual(runtime.lastPayload("steer")?["message"]?.stringValue, "change direction")
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testEnqueueingHoldsTheMessageInsteadOfSendingIt() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)

        store.enqueueOutbox(text: "steer this", delivery: .steer)

        XCTAssertEqual(store.outbox.map(\.text), ["steer this"])
        XCTAssertEqual(runtime.commandCount("steer"), 0, "Nothing reaches Pi until the matching boundary fires")
    }

    func testTurnEndFlushesOnlySteeringEntries() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.enqueueOutbox(text: "steer me", delivery: .steer)
        store.enqueueOutbox(text: "later please", delivery: .followUp)

        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))

        XCTAssertEqual(store.outbox.map(\.text), ["later please"], "Only the steering entry flushes at turn_end")
        XCTAssertEqual(runtime.commandCount("steer"), 1)
        XCTAssertEqual(runtime.lastPayload("steer")?["message"]?.stringValue, "steer me")
    }

    func testQueuedImagesFlushAsFilePathsAndRPCImageData() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        let imageURL = directory.appendingPathComponent("queued image.png")
        store.enqueueOutbox(
            text: "Use this",
            delivery: .steer,
            attachments: [ImageAttachment(
                data: Data("pixels".utf8), mimeType: "image/png",
                fileName: imageURL.lastPathComponent, fileURL: imageURL
            )]
        )

        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))

        XCTAssertEqual(
            runtime.lastPayload("steer")?["message"]?.stringValue,
            "Use this\n\nAttached image file paths:\n- \(imageURL.path)"
        )
        XCTAssertEqual(runtime.lastPayload("steer")?["images"]?.arrayValue?.count, 1)
    }

    func testFollowUpWaitsPastTurnEndUntilAgentSettled() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.enqueueOutbox(text: "later please", delivery: .followUp)

        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))
        XCTAssertEqual(store.outbox.map(\.text), ["later please"])
        XCTAssertEqual(runtime.commandCount("prompt"), 0)

        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(runtime.commandCount("prompt"), 1)
        XCTAssertEqual(runtime.lastPayload("prompt")?["message"]?.stringValue, "later please")
    }

    func testOldestQueuedEntryOfAKindFlushesFirst() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.enqueueOutbox(text: "first", delivery: .steer)
        store.enqueueOutbox(text: "second", delivery: .steer)

        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))

        XCTAssertEqual(runtime.sent.filter { $0.type == "steer" }.map { $0.payload["message"]?.stringValue }, ["first", "second"])
    }

    func testEditingAQueuedEntryChangesWhatEventuallyFlushes() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.enqueueOutbox(text: "original", delivery: .steer)
        guard let id = store.outbox.first?.id else { return XCTFail("expected a queued entry") }

        store.updateOutbox(id: id, text: "edited")
        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))

        XCTAssertEqual(runtime.lastPayload("steer")?["message"]?.stringValue, "edited")
    }

    func testRemovingAQueuedEntryStopsItFromEverBeingSent() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.enqueueOutbox(text: "regret this", delivery: .steer)
        guard let id = store.outbox.first?.id else { return XCTFail("expected a queued entry") }

        store.removeOutbox(id: id)
        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))

        XCTAssertEqual(runtime.commandCount("steer"), 0)
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testChangingAFollowUpToSteeringSendsItImmediately() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.enqueueOutbox(text: "move me", delivery: .followUp)
        guard let id = store.outbox.first?.id else { return XCTFail("expected a queued entry") }

        store.setOutboxDelivery(id: id, delivery: .steer)

        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(runtime.commandCount("steer"), 1)
        XCTAssertEqual(runtime.lastPayload("steer")?["message"]?.stringValue, "move me")
    }

    func testSingleEscapeStopsCurrentTurnWithoutAQueuedMessage() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))

        store.stopFromEscape(fully: false)

        XCTAssertEqual(runtime.commandCount("abort"), 1)
        XCTAssertEqual(runtime.stopCount, 0)
    }

    func testSecondEscapeFullyStopsAfterTheFirstAlreadySettled() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))

        store.stopFromEscape(fully: false)
        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))
        XCTAssertFalse(store.canStopCurrentThread)

        store.stopFromEscape(fully: true)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testSingleEscapeSendsEveryQueuedMessageAfterCurrentTurnSettles() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.enqueueOutbox(text: "steer later", delivery: .steer)
        store.enqueueOutbox(text: "follow later", delivery: .followUp)
        store.handleRPCEventForTesting(.object([
            "type": .string("queue_update"),
            "followUp": .array([.string("runtime follow-up")])
        ]))

        store.stopFromEscape(fully: false)

        XCTAssertEqual(store.outbox.map(\.delivery), [.followUp, .followUp])
        XCTAssertEqual(store.runtimeState.followUpQueue, ["runtime follow-up"])
        XCTAssertEqual(runtime.commandCount("abort"), 1)
        XCTAssertEqual(runtime.commandCount("follow_up"), 0)
        XCTAssertEqual(runtime.stopCount, 0)
        runtime.delayNextState = true
        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(runtime.sent.filter { $0.type == "prompt" }.compactMap { $0.payload["message"]?.stringValue }, ["steer later"])

        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))
        runtime.finishDelayedState() // A stale first-prompt query must not dispatch a duplicate.

        let continuations = runtime.sent.filter { $0.type == "prompt" }
        XCTAssertEqual(continuations.compactMap { $0.payload["message"]?.stringValue }, ["steer later", "follow later"])
    }

    func testSingleEscapeRestoresAFollowUpThatPiDefinitelyRejects() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        runtime.followUpError = AgentRuntimeError.notRunning
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.enqueueOutbox(text: "do not lose this", delivery: .followUp)

        store.stopFromEscape(fully: false)
        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))

        XCTAssertEqual(store.outbox.map(\.text), ["do not lose this"])
        XCTAssertEqual(store.outbox.map(\.delivery), [.followUp])
        XCTAssertEqual(runtime.commandCount("abort"), 1)
    }

    func testStopImmediatelyClearsEveryQueueAndRetiresTheRuntime() {
        let (store, runtime, session) = makeStore()
        attach(store, runtime, session)
        store.handleRPCEventForTesting(.object(["type": .string("agent_start")]))
        store.enqueueOutbox(text: "do not steer", delivery: .steer)
        store.enqueueOutbox(text: "do not continue", delivery: .followUp)
        store.handleRPCEventForTesting(.object([
            "type": .string("queue_update"),
            "steering": .array([.string("already accepted")]),
            "followUp": .array([.string("also accepted")])
        ]))

        store.stopFromEscape(fully: true)

        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertTrue(store.runtimeState.steeringQueue.isEmpty)
        XCTAssertTrue(store.runtimeState.followUpQueue.isEmpty)
        XCTAssertFalse(store.runtimeState.isStreaming)
        XCTAssertFalse(store.canStopCurrentThread)
        XCTAssertEqual(runtime.commandCount("abort"), 1)
        XCTAssertEqual(runtime.stopCount, 1)

        store.abort()
        store.handleRPCEventForTesting(.object(["type": .string("turn_end")]))
        store.handleRPCEventForTesting(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(runtime.commandCount("abort"), 1, "Repeated stop is a no-op")
        XCTAssertEqual(runtime.commandCount("steer"), 0)
        XCTAssertEqual(runtime.commandCount("follow_up"), 0)
        XCTAssertEqual(runtime.commandCount("prompt"), 0)
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

    /// Selects the session and actually starts the fake runtime against it (via
    /// `prepareComposerOptions`, the same call the composer makes), so `flushOutbox`'s
    /// `runtime.isRunning` guard is satisfied exactly like a real attached conversation.
    private func attach(_ store: AppStore, _ runtime: FakeRuntime, _ session: SessionSummary) {
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.selectSession(session)
        store.prepareComposerOptions()
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
}
