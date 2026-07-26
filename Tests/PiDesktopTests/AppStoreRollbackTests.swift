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
        default:
            if let completion { pending[type] = completion }
        }
    }

    func sendUncorrelated(_ value: JSONValue) { uncorrelated.append(value) }

    func fail(_ command: String, with error: Error) {
        pending.removeValue(forKey: command)?(.failure(error))
    }

    func succeed(_ command: String, data: JSONValue) {
        pending.removeValue(forKey: command)?(.success(.object([
            "type": .string("response"),
            "success": .bool(true),
            "data": data
        ])))
    }

    func commandCount(_ command: String) -> Int { sent.filter { $0.command == command }.count }
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
        XCTAssertEqual(store.route, .session("fresh-session"))
        runtime.fail("prompt", with: PiRPCError.processExited("provider unreachable"))
        XCTAssertEqual(store.draft, "first prompt of a new chat")
    }

    func testSwitchingRuntimeClearsExtensionDialogsSoStaleIDsAreNeverAnswered() async throws {
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

        // Switching to a different session replaces the runtime; the queued dialog must go away
        // rather than being answered into the replacement.
        store.selectSession(sessionB)
        runtime.sessionFile = sessionB.fileURL.path
        runtime.sessionID = sessionB.id
        store.draft = "start B"
        store.submitDraft()

        XCTAssertEqual(runtime.stopCount, 1, "Switching sessions replaces the runtime")
        XCTAssertNil(store.activeDialog, "Old-runtime dialogs are cleared before switching")
        store.respondToExtensionDialog(value: "should not be sent")
        XCTAssertEqual(runtime.uncorrelated.count, 1, "A stale dialog ID must never reach the replacement")
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
