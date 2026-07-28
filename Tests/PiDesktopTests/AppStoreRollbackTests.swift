import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Fakes

private final class FakeRuntime: PiRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var startCount = 0
    var stopCount = 0
    var uncorrelated: [JSONValue] = []
    private(set) var sent: [(command: String, payload: [String: JSONValue])] = []
    private var pending: [String: (Result<JSONValue, Error>) -> Void] = [:]
    /// sessionFile reported by get_state, which decides which session owns the runtime.
    var sessionFile: String = ""
    var sessionID: String = ""
    var delaysStateResponse = false
    var hasConnectivityResumeCommand = true
    var connectivityResumeCommandPath = ActivityExtensionInstaller.installedFileURL().path
    var getCommandsFailure: Error?

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
        switch type {
        case "get_state" where delaysStateResponse:
            if let completion { pending[type] = completion }
        case "get_state":
            completion?(.success(.object([
                "type": .string("response"),
                "success": .bool(true),
                "data": .object([
                    "isStreaming": .bool(false),
                    "sessionFile": .string(sessionFile),
                    "sessionId": .string(sessionID),
                    "model": .object(["id": .string("m"), "name": .string("M"), "provider": .string("p")])
                ])
            ])))
        case "get_commands":
            if let getCommandsFailure {
                completion?(.failure(getCommandsFailure))
                return
            }
            let commands: [JSONValue] = hasConnectivityResumeCommand ? [.object([
                "name": .string("pi-desktop-resume"),
                "source": .string("extension"),
                "description": .string("Resume an interrupted turn after network connectivity returns"),
                "sourceInfo": .object(["path": .string(connectivityResumeCommandPath)])
            ])] : []
            completion?(.success(.object([
                "type": .string("response"),
                "success": .bool(true),
                "data": .object(["commands": .array(commands)])
            ])))
        default:
            if let completion { pending[type] = completion }
        }
    }

    func sendUncorrelated(_ value: JSONValue) { uncorrelated.append(value) }

    func fail(_ command: String, with error: Error) {
        pending.removeValue(forKey: command)?(.failure(error))
    }

    /// Mirrors `PiRPCClient`'s real ordering on a crash: every pending completion is rejected
    /// first — classified exactly like `RPCTimeoutPolicy` classifies a timeout for the same
    /// command, outcome-unknown unless it is a read-only state query — and only then does
    /// `onExit` fire.
    func crash(_ message: String) {
        for command in Array(pending.keys) {
            let error: Error = RPCTimeoutPolicy.stateQueries.contains(command)
                ? PiRPCError.processExited(message)
                : PiRPCError.outcomeUnknown(command)
            pending.removeValue(forKey: command)?(.failure(error))
        }
        isRunning = false
        onExit?(message)
    }

    func succeed(_ command: String, data: JSONValue) {
        pending.removeValue(forKey: command)?(.success(.object([
            "type": .string("response"),
            "success": .bool(true),
            "data": data
        ])))
    }

    func commandCount(_ command: String) -> Int { sent.filter { $0.command == command }.count }
    func lastPayload(_ command: String) -> [String: JSONValue]? { sent.last { $0.command == command }?.payload }
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/pi-desktop-tests")
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

// MARK: - Tests

@MainActor
final class AppStoreRollbackTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPureRollbackScopeHelper() {
        let a = DraftOrigin(route: .session("a"), sessionPath: "/tmp/a.jsonl")
        let b = DraftOrigin(route: .session("b"), sessionPath: "/tmp/b.jsonl")

        XCTAssertTrue(DraftOrigin.shouldRestoreDraft(origin: a, currentRoute: .session("a"), currentSessionPath: "/tmp/a.jsonl"))
        XCTAssertFalse(DraftOrigin.shouldRestoreDraft(origin: a, currentRoute: .session("b"), currentSessionPath: "/tmp/b.jsonl"))
        XCTAssertFalse(DraftOrigin.shouldRestoreDraft(origin: a, currentRoute: .newChat, currentSessionPath: nil))
        XCTAssertFalse(DraftOrigin.shouldRestoreDraft(origin: b, currentRoute: .session("b"), currentSessionPath: "/tmp/renamed.jsonl"))
    }

    func testLateFailureFromAnotherConversationNeverContaminatesTheCurrentDraft() async throws {
        let (store, runtime, sessionA, sessionB) = makeStore()

        store.selectSession(sessionA)
        store.draft = "prompt for A"
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.submitDraft()

        XCTAssertEqual(store.draft, "", "Sending clears the composer")
        XCTAssertEqual(runtime.commandCount("prompt"), 1)

        // The user moves to another conversation and starts typing before A's failure arrives.
        store.selectSession(sessionB)
        store.draft = "unrelated text in B"
        runtime.fail("prompt", with: PiRPCError.processExited("Pi crashed in A"))

        XCTAssertEqual(store.draft, "unrelated text in B", "A's failure must not inject text into B")
        XCTAssertTrue(store.attachments.isEmpty, "A's images must not appear in B")
        let toast = try XCTUnwrap(store.toast)
        XCTAssertTrue(toast.text.localizedCaseInsensitiveContains("another conversation"),
                      "The notification names the other conversation")
        XCTAssertTrue(toast.text.contains("Pi crashed in A"))
        XCTAssertEqual(runtime.commandCount("prompt"), 1, "A failure must never resubmit the prompt")

        store.selectSession(sessionA)
        XCTAssertEqual(store.draft, "prompt for A", "The failed draft waits in its own conversation")
    }

    func testMessageAppearsBeforeRuntimeStartupFinishes() throws {
        let (store, runtime, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        runtime.delaysStateResponse = true

        store.draft = "show this now"
        store.submitDraft()

        XCTAssertEqual(store.messages.last?.textContent, "show this now")
        XCTAssertTrue(store.messages.last?.id.hasPrefix("local-") == true)
        XCTAssertEqual(runtime.commandCount("prompt"), 0, "RPC startup is still pending")

        runtime.succeed("get_state", data: .object([
            "isStreaming": .bool(false),
            "sessionFile": .string(sessionA.fileURL.path),
            "sessionId": .string(sessionA.id)
        ]))
        XCTAssertEqual(runtime.commandCount("prompt"), 1)
        XCTAssertEqual(runtime.commandCount("get_messages"), 0)
        XCTAssertEqual(store.messages.map(\.textContent), ["show this now"])
    }

    func testEscapeDuringStartupAbortsThePromptAtAgentStart() {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        runtime.delaysStateResponse = true
        store.draft = "stop during startup"
        store.submitDraft()

        store.stopFromEscape(fully: false)
        runtime.succeed("get_state", data: .object([
            "isStreaming": .bool(false),
            "sessionFile": .string(session.fileURL.path),
            "sessionId": .string(session.id)
        ]))
        runtime.onEvent?(.object(["type": .string("agent_start")]))

        XCTAssertEqual(runtime.commandCount("prompt"), 1)
        XCTAssertEqual(runtime.commandCount("abort"), 1)
        XCTAssertEqual(runtime.stopCount, 0)
    }

    func testNewChatMessageAppearsBeforeSessionPromotion() throws {
        let (store, runtime, _, _) = makeStore()
        store.openNewChat()
        store.selectedFolder = temporaryDirectory
        runtime.sessionFile = temporaryDirectory.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"
        runtime.delaysStateResponse = true

        store.draft = "first prompt"
        store.submitDraft()

        XCTAssertEqual(store.route, .newChat)
        XCTAssertEqual(store.messages.last?.textContent, "first prompt")

        runtime.succeed("get_state", data: .object([
            "isStreaming": .bool(false),
            "sessionFile": .string(runtime.sessionFile),
            "sessionId": .string(runtime.sessionID)
        ]))
        XCTAssertEqual(store.route, .session(URL(fileURLWithPath: runtime.sessionFile).standardizedFileURL.path))
        XCTAssertEqual(store.messages.last?.textContent, "first prompt")
    }

    func testFailureOnTheOriginatingConversationRestoresTheDraft() async throws {
        let (store, runtime, sessionA, _) = makeStore()

        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "prompt for A"
        store.submitDraft()
        runtime.fail("prompt", with: PiRPCError.processExited("rejected"))

        XCTAssertEqual(store.draft, "prompt for A")
        XCTAssertEqual(store.toast?.style, .error)
        XCTAssertFalse(store.messages.contains { $0.id.hasPrefix("local-") }, "The optimistic message is removed")
    }

    func testAmbiguousTimeoutDoesNotRollBackOrDuplicateThePrompt() async throws {
        let (store, runtime, sessionA, _) = makeStore()

        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "prompt that may have landed"
        store.submitDraft()
        runtime.fail("prompt", with: RPCTimeoutPolicy.error(for: "prompt"))

        XCTAssertEqual(store.draft, "", "An unconfirmed prompt must not be handed back for resending")
        XCTAssertEqual(store.toast?.style, .warning)
        XCTAssertTrue(store.messages.contains { $0.id.hasPrefix("local-") },
                      "The optimistic message stays: Pi may already be answering it")
        XCTAssertEqual(runtime.commandCount("prompt"), 1)
    }

    func testHandledPromptWithoutAgentStartReconcilesToIdle() {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "/mode"
        store.submitDraft()

        runtime.succeed("prompt", data: .object([:]))

        XCTAssertFalse(store.runtimeState.isStreaming)
        XCTAssertFalse(store.canStopCurrentThread)
    }

    /// Task 2: a crash mid-turn restores the exact last user message for a one-click resend, and
    /// — the specific bug this guards — does so exactly once. `crash()` rejects the pending
    /// "prompt" completion as outcome-unknown (mirroring a real `PiRPCClient`) before calling
    /// `onExit`, so both `dispatchMessage`'s completion and `handleRuntimeExit` observe the same
    /// crash; only one of them may ever actually restore the draft.
    func testCrashDuringAnInFlightPromptRestoresTheDraftExactlyOnceNotTwice() async throws {
        let (store, runtime, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "fix the crash"
        store.submitDraft()
        XCTAssertEqual(store.draft, "", "Sending clears the composer")
        XCTAssertTrue(store.messages.contains { $0.id.hasPrefix("local-") })

        runtime.crash("Pi exited with status 139.")

        XCTAssertEqual(store.draft, "fix the crash", "Restored exactly once, never concatenated with itself")
        XCTAssertNotNil(store.runtimeState.lastError, "The failure is persisted, not just a toast that disappears")
        XCTAssertEqual(store.toast?.style, .error)
        XCTAssertTrue(store.messages.contains { $0.id.hasPrefix("local-") },
                      "The optimistic message stays: Pi may already have accepted it before dying")
    }

    func testCrashWhileNoPromptWasInFlightNeverTouchesTheDraft() async throws {
        let (store, runtime, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "not sent yet"

        runtime.crash("Pi exited with status 1.")

        XCTAssertEqual(store.draft, "not sent yet", "Nothing was in flight, so nothing is restored or altered")
        XCTAssertNotNil(store.runtimeState.lastError)
    }

    func testCrashAfterNavigatingAwayNeverRestoresIntoTheNewConversation() async throws {
        let (store, runtime, sessionA, sessionB) = makeStore()
        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "prompt for A"
        store.submitDraft()

        store.selectSession(sessionB)
        store.draft = "unrelated text in B"

        runtime.crash("Pi exited with status 139.")

        XCTAssertEqual(store.draft, "unrelated text in B", "A's crash must not inject text into B")
    }

    func testSettledTurnClearsThePendingPromptSoALaterUnrelatedCrashRestoresNothing() async throws {
        let (store, runtime, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "first message"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))

        // A later, unrelated crash (nothing pending any more) must not resurrect the first turn.
        runtime.crash("Pi exited with status 1.")
        XCTAssertEqual(store.draft, "", "The settled turn left nothing pending to restore")
    }

    func testOfflineProviderRetryPausesAndResumesOnceAfterReconnect() throws {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "finish this work"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object([
            "type": .string("auto_retry_start"),
            "attempt": .number(1)
        ]))
        XCTAssertTrue(store.runtimeState.isWaitingForNetwork)
        XCTAssertEqual(runtime.commandCount("abort_retry"), 1, "Offline time must not consume Pi's retry budget")

        store.setConnectivityForTesting(isOnline: true)
        XCTAssertEqual(runtime.commandCount("prompt"), 1, "The original run must settle before continuation")
        runtime.onEvent?(.object([
            "type": .string("auto_retry_end"),
            "success": .bool(false),
            "finalError": .string("Retry cancelled")
        ]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))

        XCTAssertEqual(runtime.commandCount("get_commands"), 1)
        XCTAssertEqual(runtime.commandCount("prompt"), 2)
        XCTAssertEqual(runtime.lastPayload("prompt")?["message"]?.stringValue, "/pi-desktop-resume")
        XCTAssertFalse(store.runtimeState.isWaitingForNetwork)
        XCTAssertTrue(store.runtimeState.isStreaming)
        XCTAssertNil(store.runtimeState.lastError, "An intentional connectivity pause is not a failed turn")

        store.setConnectivityForTesting(isOnline: true)
        XCTAssertEqual(runtime.commandCount("prompt"), 2, "Repeated path updates must never duplicate the continuation")
    }

    func testOfflineErrorWithoutPiRetryDoesNotArmContinuation() {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "fail without retry"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"),
                "stopReason": .string("error"),
                "errorMessage": .string("not retryable")
            ])
        ]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        store.setConnectivityForTesting(isOnline: true)

        XCTAssertFalse(store.runtimeState.isWaitingForNetwork)
        XCTAssertEqual(runtime.commandCount("abort_retry"), 0)
        XCTAssertEqual(runtime.commandCount("get_commands"), 0)
        XCTAssertEqual(runtime.commandCount("prompt"), 1)
    }

    func testPiRecoveryBeforeSettlementCancelsDesktopContinuation() {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "keep going"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        store.setConnectivityForTesting(isOnline: true)
        runtime.onEvent?(.object(["type": .string("auto_retry_end"), "success": .bool(true)]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))

        XCTAssertFalse(store.runtimeState.isWaitingForNetwork)
        XCTAssertEqual(runtime.commandCount("prompt"), 1, "Pi already recovered, so Desktop must not continue twice")
    }

    func testAbortCancelsASettledOfflineContinuation() {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "do not resume after I cancel"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        runtime.onEvent?(.object(["type": .string("auto_retry_end"), "success": .bool(false)]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertTrue(store.runtimeState.isWaitingForNetwork)

        store.abort()
        store.setConnectivityForTesting(isOnline: true)
        XCTAssertFalse(store.runtimeState.isWaitingForNetwork)
        XCTAssertEqual(runtime.commandCount("prompt"), 1)
        XCTAssertEqual(runtime.commandCount("abort"), 1, "Full stop also clears Pi-owned continuations")
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testAbortBeforeRetryEventCannotRearmConnectivityResume() {
        let (store, runtime, session, _) = makeStore()
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "stop here"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))
        runtime.onEvent?(.object(["type": .string("agent_start")]))
        store.setConnectivityForTesting(isOnline: false)

        store.abort()
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        runtime.onEvent?(.object([
            "type": .string("auto_retry_end"),
            "success": .bool(false),
            "finalError": .string("Retry cancelled")
        ]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        store.setConnectivityForTesting(isOnline: true)

        XCTAssertFalse(store.runtimeState.isWaitingForNetwork)
        XCTAssertNil(store.runtimeState.lastError)
        XCTAssertEqual(runtime.commandCount("abort_retry"), 0)
        XCTAssertEqual(runtime.commandCount("prompt"), 1)
    }

    func testMissingResumeHelperFallsBackToAPlainContinuation() {
        let (store, runtime, session, _) = makeStore()
        runtime.hasConnectivityResumeCommand = false
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "survive an extension upgrade race"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        runtime.onEvent?(.object(["type": .string("auto_retry_end"), "success": .bool(false)]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        store.setConnectivityForTesting(isOnline: true)

        let continuation = runtime.lastPayload("prompt")?["message"]?.stringValue
        XCTAssertFalse(continuation?.hasPrefix("/") == true)
        XCTAssertTrue(continuation?.contains("Continue from where it stopped") == true)
        XCTAssertEqual(runtime.commandCount("prompt"), 2)
    }

    func testResumeHelperQueryFailureFallsBackToAPlainContinuation() {
        let (store, runtime, session, _) = makeStore()
        runtime.getCommandsFailure = PiRPCError.processExited("query unavailable")
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "survive a query failure"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        runtime.onEvent?(.object(["type": .string("auto_retry_end"), "success": .bool(false)]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        store.setConnectivityForTesting(isOnline: true)

        XCTAssertFalse(runtime.lastPayload("prompt")?["message"]?.stringValue?.hasPrefix("/") == true)
        XCTAssertTrue(store.runtimeState.isStreaming)
        XCTAssertNil(store.runtimeState.lastError)
        XCTAssertEqual(runtime.commandCount("prompt"), 2)
    }

    func testLookalikeResumeHelperFallsBackToAPlainContinuation() {
        let (store, runtime, session, _) = makeStore()
        runtime.connectivityResumeCommandPath = "/tmp/not-pi-desktop.ts"
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.draft = "use only the installed helper"
        store.submitDraft()
        runtime.succeed("prompt", data: .object([:]))

        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        runtime.onEvent?(.object(["type": .string("auto_retry_end"), "success": .bool(false)]))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        store.setConnectivityForTesting(isOnline: true)

        let continuation = runtime.lastPayload("prompt")?["message"]?.stringValue
        XCTAssertFalse(continuation?.hasPrefix("/") == true)
        XCTAssertTrue(continuation?.contains("Continue from where it stopped") == true)
        XCTAssertEqual(runtime.commandCount("prompt"), 2)
    }

    func testNewChatRuntimeOffersExactModelAndThinkingMenus() throws {
        let (store, runtime, _, _) = makeStore()
        store.openNewChat()
        store.selectedFolder = temporaryDirectory

        store.prepareComposerOptions()
        XCTAssertTrue(store.isCurrentRouteRuntime)
        XCTAssertEqual(store.modelPickerPresentation, .disabled, "The picker waits for its query-only RPC")

        runtime.succeed("get_available_models", data: .object([
            "models": .array([
                .object([
                    "provider": .string("openai-codex"),
                    "id": .string("gpt-5.6"),
                    "name": .string("GPT-5.6"),
                    "reasoning": .bool(true)
                ])
            ])
        ]))
        runtime.succeed("get_available_thinking_levels", data: .object([
            "levels": .array([.string("off"), .string("xhigh")])
        ]))

        XCTAssertEqual(store.modelPickerPresentation, .menu)
        XCTAssertEqual(store.thinkingPickerPresentation, .menu)
        XCTAssertEqual(store.availableModels.first?.modelID, "gpt-5.6")
        XCTAssertEqual(store.availableThinkingLevels, ["off", "xhigh"])
    }

    func testNewChatPromotionKeepsTheDraftRecoverableInThePromotedSession() async throws {
        let (store, runtime, _, _) = makeStore()
        store.openNewChat()
        store.selectedFolder = temporaryDirectory
        runtime.sessionFile = temporaryDirectory.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"

        store.draft = "first prompt of a new chat"
        store.submitDraft()

        // The new chat is promoted in place, so the failure still belongs to this composer.
        XCTAssertEqual(store.route, .session(URL(fileURLWithPath: runtime.sessionFile).standardizedFileURL.path))
        runtime.fail("prompt", with: PiRPCError.processExited("provider unreachable"))
        XCTAssertEqual(store.draft, "first prompt of a new chat")
    }

    func testSwitchingRuntimeParksExtensionDialogsWithTheirOwningConversation() async throws {
        let (store, runtime, sessionA, sessionB) = makeStore()

        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "start A"
        store.submitDraft()

        // Settle the run so switching conversations is allowed.
        runtime.fail("prompt", with: PiRPCError.processExited("failed in A"))
        XCTAssertFalse(store.runtimeState.isStreaming)

        runtime.onEvent?(dialogEvent(id: "dialog-1", message: "first"))
        runtime.onEvent?(dialogEvent(id: "dialog-2", message: "second"))
        XCTAssertEqual(store.activeDialog?.id, "dialog-1", "A second request must not replace the first")

        store.respondToExtensionDialog(value: "answer-1")
        XCTAssertEqual(store.activeDialog?.id, "dialog-2", "The queue advances after a response")
        XCTAssertEqual(runtime.uncorrelated.count, 1)

        // B gets its own runtime. A's unanswered dialog is hidden, not answered through B.
        store.selectSession(sessionB)
        store.draft = "start B"
        store.submitDraft()

        XCTAssertEqual(runtime.stopCount, 0, "A stays alive while its dialog is waiting")
        XCTAssertNil(store.activeDialog)
        store.respondToExtensionDialog(value: "should not be sent")
        XCTAssertEqual(runtime.uncorrelated.count, 1)

        store.selectSession(sessionA)
        store.prepareComposerOptions()
        XCTAssertEqual(store.activeDialog?.id, "dialog-2")
        store.respondToExtensionDialog(value: "answer-2")
        XCTAssertEqual(runtime.uncorrelated.count, 2, "The answer returns to A's runtime")
    }

    func testRouteRuntimeStopsTheEphemeralStatusProbeBeforeStarting() {
        let runtime = FakeRuntime()
        let probe = FakeRuntime()
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            persistence: AppPersistence(baseURL: temporaryDirectory),
            activityPresenter: ActivityPresenter(),
            probeRuntimeFactory: { probe }
        )

        store.refreshExtensionStatuses()
        XCTAssertTrue(probe.isRunning)
        XCTAssertEqual(probe.startCount, 1)

        store.selectedFolder = temporaryDirectory
        store.prepareComposerOptions()

        XCTAssertFalse(probe.isRunning)
        XCTAssertEqual(probe.stopCount, 1, "A real route runtime must not race the launch probe")
        XCTAssertTrue(runtime.isRunning)
        XCTAssertEqual(runtime.startCount, 1)
    }

    func testRuntimeExitClearsPendingDialogs() async throws {
        let (store, runtime, sessionA, _) = makeStore()
        store.selectSession(sessionA)
        runtime.sessionFile = sessionA.fileURL.path
        runtime.sessionID = sessionA.id
        store.draft = "start A"
        store.submitDraft()

        runtime.onEvent?(dialogEvent(id: "dialog-1", message: "first"))
        XCTAssertNotNil(store.activeDialog)
        runtime.onExit?("Pi exited with status 1.")
        XCTAssertNil(store.activeDialog)
    }

    func testExtensionSetTitleAndWidgetPlacementAreRetained() async throws {
        let (store, runtime, sessionA, _) = makeStore()
        store.selectSession(sessionA)

        runtime.onEvent?(.object([
            "type": .string("extension_ui_request"),
            "method": .string("setTitle"),
            "title": .string("Reviewing PR 42")
        ]))
        XCTAssertEqual(store.windowTitle, "Reviewing PR 42")

        runtime.onEvent?(.object([
            "type": .string("extension_ui_request"),
            "method": .string("setWidget"),
            "widgetKey": .string("build"),
            "widgetLines": .array([.string("tests: green")]),
            "widgetPlacement": .string("belowEditor")
        ]))
        XCTAssertEqual(store.extensionWidgets["build"]?.placement, "belowEditor")
    }

    // MARK: - Helpers

    private func dialogEvent(id: String, message: String) -> JSONValue {
        .object([
            "type": .string("extension_ui_request"),
            "method": .string("input"),
            "id": .string(id),
            "title": .string("Extension"),
            "message": .string(message)
        ])
    }

    private func makeStore() -> (AppStore, FakeRuntime, SessionSummary, SessionSummary) {
        let runtime = FakeRuntime()
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            runtimeFactory: { FakeRuntime() },
            persistence: AppPersistence(baseURL: temporaryDirectory),
            activityPresenter: ActivityPresenter()
        )
        let a = summary(id: "session-a", file: "a.jsonl")
        let b = summary(id: "session-b", file: "b.jsonl")
        store.sessions = [a, b]
        return (store, runtime, a, b)
    }

    private func summary(id: String, file: String) -> SessionSummary {
        var value = SessionSummary(
            id: id,
            fileURL: temporaryDirectory.appendingPathComponent(file),
            cwd: temporaryDirectory,
            createdAt: Date(),
            modifiedAt: Date(),
            name: id,
            preview: "preview",
            messageCount: 0,
            metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }
}

@MainActor
final class StatusCacheMergeTests: XCTestCase {
    func testTransientSubagentStatusIsLiveOnlyAndOldCacheIsPurged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-status-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = AppPersistence(baseURL: directory)
        persistence.cacheExtensionStatuses([ExtensionStatusParser.subagentsKey: "1 running agent"])
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: FakeRuntime(),
            persistence: persistence,
            activityPresenter: ActivityPresenter()
        )

        XCTAssertNil(store.statusModel.values[ExtensionStatusParser.subagentsKey])
        XCTAssertNil(persistence.state.cachedExtensionStatuses[ExtensionStatusParser.subagentsKey])

        store.handleRPCEventForTesting(.object([
            "type": .string("extension_ui_request"),
            "method": .string("setStatus"),
            "statusKey": .string(ExtensionStatusParser.subagentsKey),
            "statusText": .string("1 running agent")
        ]))
        XCTAssertEqual(store.statusModel.values[ExtensionStatusParser.subagentsKey], "1 running agent")
        XCTAssertNil(persistence.state.cachedExtensionStatuses[ExtensionStatusParser.subagentsKey])

        store.handleRPCEventForTesting(.object([
            "type": .string("extension_ui_request"),
            "method": .string("setStatus"),
            "statusKey": .string(ExtensionStatusParser.subagentsKey)
        ]))
        XCTAssertNil(store.statusModel.values[ExtensionStatusParser.subagentsKey])
    }

    func testAPartialLiveUpdateNeverErasesTheKnownAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-status-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = AppPersistence(baseURL: directory)
        persistence.cacheExtensionStatuses([
            "codex-account": "vince@example.com 7d:22% reset\u{d7}3:5h",
            "fast-priority": "fast"
        ])
        let runtime = FakeRuntime()
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            persistence: persistence,
            activityPresenter: ActivityPresenter()
        )

        // A runtime that has only reported `mode` so far must not blank the rest of the bar.
        let event: JSONValue = .object([
            "type": .string("extension_ui_request"),
            "method": .string("setStatus"),
            "statusKey": .string("mode"),
            "statusText": .string("mode:ultra")
        ])
        store.handleRPCEventForTesting(event)

        let model = store.statusModel
        XCTAssertEqual(model.mode, PiMode.ultra)
        XCTAssertEqual(model.codexAccount?.account, "vince@example.com", "the known account must survive")
        XCTAssertNotNil(model.fastPriority)
    }
}
