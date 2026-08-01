import PatchworkKit
import Combine
import Foundation
import XCTest
@testable import Patchwork

private final class ParallelFakeRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionFile: String
    var sessionID: String
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [(command: String, payload: [String: JSONValue])] = []
    var followUpError: Error?

    init(sessionFile: String, sessionID: String) {
        self.sessionFile = sessionFile
        self.sessionID = sessionID
    }

    func start(cwd: URL, sessionPath: URL?) throws {
        if let sessionPath { sessionFile = sessionPath.standardizedFileURL.path }
        isRunning = true
        startCount += 1
    }

    func stop() {
        isRunning = false
        stopCount += 1
    }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        sent.append((type, payload))
        if (type == "prompt" || type == "follow_up"), let followUpError {
            completion?(.failure(followUpError))
            return
        }
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

    func testDetachedStreamingBurstDoesNotInvalidateVisibleConversation() {
        let (store, runtimeA, _, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.onEvent?(.object([
            "type": .string("message_update"),
            "message": assistantMessage("first output")
        ]))
        XCTAssertEqual(store.runtimeState.phase, .working)
        store.selectSession(sessionB)

        var invalidations = 0
        let cancellable = store.objectWillChange.sink { invalidations += 1 }
        for index in 0..<100 {
            runtimeA.onEvent?(.object([
                "type": .string("message_update"),
                "message": assistantMessage("update \(index)")
            ]))
        }

        XCTAssertEqual(invalidations, 0, "A hidden token burst must not redraw B's whole window")
        withExtendedLifetime(cancellable) {}
        store.selectSession(sessionA)
        XCTAssertEqual(store.streamingMessage?.textContent, "update 99")
    }

    func testCancelledOldRoutePublishCannotConsumeTheNewRouteDelta() async throws {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.onEvent?(.object([
            "type": .string("message_update"),
            "message": assistantMessage("A first")
        ]))
        runtimeA.onEvent?(.object([
            "type": .string("message_update"),
            "message": assistantMessage("A trailing")
        ]))

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        runtimeB.onEvent?(.object([
            "type": .string("message_update"),
            "message": assistantMessage("B visible")
        ]))

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.streamingMessage?.textContent, "B visible")
        XCTAssertEqual(store.selectedSession?.id, sessionB.id)
    }

    func testVisibleStreamingUpdatesInvalidateOnlyTheTranscriptScope() async throws {
        let (store, runtimeA, _, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.onEvent?(.object([
            "type": .string("message_update"),
            "message": assistantMessage("first output")
        ]))
        try await Task.sleep(nanoseconds: 150_000_000)

        let revisionBeforeBurst = store.transcriptRevision
        var storeInvalidations = 0
        var transcriptInvalidations = 0
        let storeCancellable = store.objectWillChange.sink { storeInvalidations += 1 }
        let transcriptCancellable = store.transcriptStream.objectWillChange.sink { transcriptInvalidations += 1 }
        for index in 0..<100 {
            runtimeA.onEvent?(.object([
                "type": .string("message_update"),
                "message": assistantMessage("update \(index)")
            ]))
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(storeInvalidations, 0, "visible tokens must not redraw the sidebar, composer, or window shell")
        XCTAssertGreaterThan(transcriptInvalidations, 0)
        XCTAssertGreaterThan(store.transcriptRevision, revisionBeforeBurst)
        XCTAssertEqual(store.streamingMessage?.textContent, "update 99")
        withExtendedLifetime((storeCancellable, transcriptCancellable)) {}
    }

    func testLiveActivityUpdatesInvalidateOnlyTheInspectorScope() {
        let (store, _, _, _, _) = makeStore()
        store.activities = [ActivityItem(
            id: "process-1", sourceID: "tool-1", kind: .process,
            title: "Build", subtitle: nil, detail: nil, status: .running,
            startedAt: Date(), endedAt: nil, raw: .null,
            agentID: nil, agentType: nil, modelName: nil, toolCallCount: nil, duration: nil
        )]
        var storeInvalidations = 0
        var activityInvalidations = 0
        let storeCancellable = store.objectWillChange.sink { storeInvalidations += 1 }
        let activityCancellable = store.runtimeActivities.objectWillChange.sink { activityInvalidations += 1 }

        for index in 0..<100 { store.activities[0].detail = "update \(index)" }

        XCTAssertEqual(storeInvalidations, 0, "tool progress must not redraw the transcript, composer, or window shell")
        XCTAssertEqual(activityInvalidations, 100)
        XCTAssertEqual(store.activities.first?.detail, "update 99")
        withExtendedLifetime((storeCancellable, activityCancellable)) {}
    }

    func testCodexQueueStatusIsEphemeralAndRuntimeScoped() {
        let (store, runtimeA, _, sessionA, sessionB) = makeStore()
        let queueEvent: JSONValue = .object([
            "type": .string("extension_ui_request"),
            "method": .string("setStatus"),
            "statusKey": .string(ExtensionStatusParser.providerQueueKey),
            "statusText": .string("Waiting for Codex slot…")
        ])

        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.onEvent?(queueEvent)
        XCTAssertEqual(store.statusModel.values[ExtensionStatusParser.providerQueueKey], "Waiting for Codex slot…")

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        XCTAssertNil(store.statusModel.values[ExtensionStatusParser.providerQueueKey])

        store.selectSession(sessionA)
        store.prepareComposerOptions()
        XCTAssertEqual(store.statusModel.values[ExtensionStatusParser.providerQueueKey], "Waiting for Codex slot…")

        store.selectSession(sessionB)
        store.prepareComposerOptions()
        runtimeA.onEvent?(.object([
            "type": .string("extension_ui_request"),
            "method": .string("setStatus"),
            "statusKey": .string(ExtensionStatusParser.providerQueueKey)
        ]))
        XCTAssertNil(store.statusModel.values[ExtensionStatusParser.providerQueueKey])

        store.selectSession(sessionA)
        store.prepareComposerOptions()
        XCTAssertNil(store.statusModel.values[ExtensionStatusParser.providerQueueKey])
    }

    func testRunningSinceUsesTheCurrentPromptBeforeTheActivityPoll() throws {
        let oldModifiedAt = Date(timeIntervalSince1970: 1)
        let (store, _, _, sessionA, _) = makeStore(sessionAModifiedAt: oldModifiedAt)
        store.selectSession(sessionA)

        let beforeSubmit = Date()
        store.draft = "new work"
        store.submitDraft()
        let beganAt = try XCTUnwrap(store.runningSince(sessionA))

        XCTAssertGreaterThanOrEqual(beganAt, beforeSubmit)
        XCTAssertLessThanOrEqual(beganAt, Date())
        XCTAssertNotEqual(beganAt, oldModifiedAt, "A new turn must not display the conversation's old modification age")
    }

    func testOneSleepHoldCoversOverlappingRunsUntilTheLastSettles() {
        var transitions: [Bool] = []
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore(sleepPrevention: {
            transitions.append($0)
        })

        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        XCTAssertEqual(transitions, [true])

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        XCTAssertEqual(transitions, [true], "a second thread must reuse the app's existing hold")

        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(transitions, [true], "the remaining thread keeps the shared hold alive")

        runtimeB.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(transitions, [true, false])
        XCTAssertFalse(store.isCaffeinated)
    }

    func testSwitchingBackImmediatelyRestoresQueuedMessages() {
        let (store, runtimeA, _, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.onEvent?(.object(["type": .string("agent_start")]))
        store.enqueueOutbox(text: "local follow-up", delivery: .followUp)
        runtimeA.onEvent?(.object([
            "type": .string("queue_update"),
            "followUp": .array([.string("Pi follow-up")])
        ]))

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        XCTAssertTrue(store.outbox.isEmpty)

        store.selectSession(sessionA)

        XCTAssertTrue(store.isSelectedRuntime)
        XCTAssertEqual(store.outbox.map(\.text), ["local follow-up"])
        XCTAssertEqual(store.runtimeState.followUpQueue, ["Pi follow-up"])
    }

    func testSelectedParkedConversationCanStopWithoutComposerPrewarm() {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()

        var stopPublished = false
        let cancellable = store.objectWillChange.sink { stopPublished = true }
        store.selectSession(sessionA)
        stopPublished = false
        XCTAssertTrue(store.canStopCurrentThread)
        store.abort()

        XCTAssertTrue(stopPublished)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(runtimeA.commandCount("abort"), 1)
        XCTAssertEqual(runtimeA.stopCount, 1)
        XCTAssertEqual(runtimeB.stopCount, 0)
        XCTAssertFalse(store.canStopCurrentThread)
    }

    func testSingleEscapePreservesFollowUpOnASelectedParkedConversation() {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.onEvent?(.object(["type": .string("agent_start")]))
        store.enqueueOutbox(text: "continue A", delivery: .followUp)
        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        runtimeB.onEvent?(.object(["type": .string("agent_start")]))

        store.selectSession(sessionA)
        store.stopFromEscape(fully: false)

        XCTAssertEqual(runtimeA.commandCount("abort"), 1)
        XCTAssertEqual(runtimeA.stopCount, 0)
        XCTAssertEqual(runtimeB.stopCount, 0)
        XCTAssertEqual(store.outbox.map(\.text), ["continue A"])
        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(runtimeA.commandCount("prompt"), 2)
        XCTAssertEqual(runtimeA.commandCount("follow_up"), 0)
    }

    func testRunningConversationsCanBeRenamedWithoutChangingTheSelectedRuntime() {
        let (store, runtimeA, runtimeB, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        store.renameSession(sessionA, to: "Renamed while running")

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        store.renameSession(sessionA, to: "Renamed from the sidebar")
        store.abort()

        XCTAssertEqual(runtimeA.commandCount("set_session_name"), 2)
        XCTAssertEqual(runtimeA.stopCount, 0)
        XCTAssertEqual(runtimeB.commandCount("abort"), 1, "Renaming A must leave selected runtime B attached")
        XCTAssertEqual(store.sessions.first { $0.id == sessionA.id }?.displayName, "Renamed from the sidebar")
    }

    func testSessionNameEventsImmediatelyUpdateTheirOwningConversation() {
        let (store, runtimeA, _, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()

        runtimeA.onEvent?(.object([
            "type": .string("session_info_changed"),
            "name": .string("Selected conversation name")
        ]))

        XCTAssertEqual(store.sessions.first { $0.id == sessionA.id }?.displayName, "Selected conversation name")
        XCTAssertEqual(store.runtimeState.sessionName, "Selected conversation name")

        store.selectSession(sessionB)
        store.draft = "task B"
        store.submitDraft()
        runtimeA.onEvent?(.object([
            "type": .string("session_info_changed"),
            "name": .string("Background conversation name")
        ]))

        XCTAssertEqual(store.sessions.first { $0.id == sessionA.id }?.displayName, "Background conversation name")
        XCTAssertEqual(store.selectedSession?.id, sessionB.id)
        XCTAssertNil(store.runtimeState.sessionName, "A background rename must not alter B's runtime state")
    }

    func testCopiedSessionIDsKeepRenameResponsesAndEventsPathScoped() {
        let (store, runtimeA, _, original, _) = makeStore()
        let copied = summary(id: original.id, file: "copied-a.jsonl")
        store.sessions = [original, copied]

        store.selectSession(copied)
        store.renameSession(copied, to: "Copied response")

        XCTAssertEqual(store.sessions.first { $0.instanceID == original.instanceID }?.displayName, original.displayName)
        XCTAssertEqual(store.sessions.first { $0.instanceID == copied.instanceID }?.displayName, "Copied response")

        runtimeA.onEvent?(.object([
            "type": .string("session_info_changed"),
            "name": .string("Copied event")
        ]))

        XCTAssertEqual(store.sessions.first { $0.instanceID == original.instanceID }?.displayName, original.displayName)
        XCTAssertEqual(store.sessions.first { $0.instanceID == copied.instanceID }?.displayName, "Copied event")
    }

    func testCopiedSessionIDsExposeDistinctPhysicalViewIdentities() {
        let original = summary(id: "shared", file: "original.jsonl")
        let copied = summary(id: "shared", file: "copied.jsonl")

        XCTAssertEqual(original.id, copied.id)
        XCTAssertNotEqual(original.instanceID, copied.instanceID)
        XCTAssertEqual(Set([original.instanceID, copied.instanceID]).count, 2)
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

    func testRejectedBackgroundFollowUpReturnsToItsOwningOutbox() {
        let (store, runtimeA, _, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.followUpError = AgentRuntimeError.notRunning
        store.enqueueOutbox(text: "keep A", delivery: .followUp)
        store.selectSession(sessionB)

        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))
        store.selectSession(sessionA)
        store.prepareComposerOptions()

        XCTAssertEqual(store.outbox.map(\.text), ["keep A"])
        XCTAssertEqual(store.outbox.map(\.delivery), [.followUp])
    }

    func testAcceptedFollowUpCanBeStoppedBeforeItsNextAgentStart() {
        let (store, runtimeA, _, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        store.enqueueOutbox(text: "continue A", delivery: .followUp)

        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(runtimeA.commandCount("prompt"), 2)
        XCTAssertTrue(store.runtimeState.isStreaming, "Queued prompt owns the runtime during preflight")
        XCTAssertTrue(store.canStopCurrentThread, "Accepted follow-up remains stoppable before agent_start")

        store.abort()

        XCTAssertEqual(runtimeA.commandCount("abort"), 1)
        XCTAssertEqual(runtimeA.stopCount, 1)
        XCTAssertFalse(store.canStopCurrentThread)
    }

    func testEscapeDuringDirectPromptPreflightAbortsWhenAgentActuallyStarts() {
        let (store, runtimeA, _, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()

        store.stopFromEscape(fully: false)
        XCTAssertEqual(runtimeA.commandCount("abort"), 0, "Preflight has no active agent to abort yet")

        runtimeA.onEvent?(.object(["type": .string("agent_start")]))
        XCTAssertEqual(runtimeA.commandCount("abort"), 1)
    }

    func testEscapeDuringFollowUpPreflightAbortsWhenAgentActuallyStarts() {
        let (store, runtimeA, _, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        store.enqueueOutbox(text: "continue A", delivery: .followUp)
        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))

        store.stopFromEscape(fully: false)
        XCTAssertEqual(runtimeA.commandCount("abort"), 0, "Preflight has no active agent to abort yet")

        runtimeA.onEvent?(.object(["type": .string("agent_start")]))
        XCTAssertEqual(runtimeA.commandCount("abort"), 1)
    }

    func testUnconfirmedFollowUpRemainsStoppable() {
        let (store, runtimeA, _, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        store.draft = "task A"
        store.submitDraft()
        runtimeA.followUpError = AgentRuntimeError.outcomeUnknown("follow_up")
        store.enqueueOutbox(text: "maybe accepted", delivery: .followUp)

        runtimeA.onEvent?(.object(["type": .string("agent_settled")]))

        XCTAssertTrue(store.canStopCurrentThread)
        store.abort()
        XCTAssertEqual(runtimeA.stopCount, 1)
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
            runtimeFactory: { _ in newRuntime },
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

    func testParallelRuntimeLimitRefusesANewStartWithoutKillingExistingWork() {
        let sessions = (0...AppStore.maximumConcurrentRuntimes).map { index in
            summary(id: "session-\(index)", file: "session-\(index).jsonl")
        }
        let runtimes = sessions.map {
            ParallelFakeRuntime(sessionFile: $0.fileURL.path, sessionID: $0.id)
        }
        var spares = Array(runtimes.dropFirst())
        let store = AppStore(
            repository: ParallelFakeRepository(rootURL: directory),
            gitService: ParallelFakeGitService(),
            runtime: runtimes[0],
            runtimeFactory: { _ in spares.removeFirst() },
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter(),
            isActiveOverride: true
        )
        store.sessions = sessions

        for index in 0..<AppStore.maximumConcurrentRuntimes {
            store.selectSession(sessions[index])
            store.draft = "task \(index)"
            store.submitDraft()
        }
        store.selectSession(sessions[AppStore.maximumConcurrentRuntimes])
        store.draft = "must remain retryable"
        store.submitDraft()

        XCTAssertEqual(runtimes.last?.startCount, 0)
        XCTAssertEqual(store.draft, "must remain retryable")
        XCTAssertTrue(store.toast?.text.contains("already active") == true)
        XCTAssertTrue(runtimes.prefix(AppStore.maximumConcurrentRuntimes).allSatisfy { $0.stopCount == 0 })
    }

    private func makeStore(
        sessionAModifiedAt: Date = Date(),
        sleepPrevention: @escaping SleepPreventionHandler = { _ in }
    ) -> (AppStore, ParallelFakeRuntime, ParallelFakeRuntime, SessionSummary, SessionSummary) {
        let sessionA = summary(id: "session-a", file: "a.jsonl", modifiedAt: sessionAModifiedAt)
        let sessionB = summary(id: "session-b", file: "b.jsonl")
        let runtimeA = ParallelFakeRuntime(sessionFile: sessionA.fileURL.path, sessionID: sessionA.id)
        let runtimeB = ParallelFakeRuntime(sessionFile: sessionB.fileURL.path, sessionID: sessionB.id)
        var spareRuntimes = [runtimeB]
        let store = AppStore(
            repository: ParallelFakeRepository(rootURL: directory),
            gitService: ParallelFakeGitService(),
            runtime: runtimeA,
            runtimeFactory: { _ in spareRuntimes.removeFirst() },
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter(),
            sleepPrevention: sleepPrevention,
            isActiveOverride: true
        )
        store.sessions = [sessionA, sessionB]
        return (store, runtimeA, runtimeB, sessionA, sessionB)
    }

    private func summary(id: String, file: String, modifiedAt: Date = Date()) -> SessionSummary {
        var summary = SessionSummary(
            id: id,
            fileURL: directory.appendingPathComponent(file),
            cwd: directory,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
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
