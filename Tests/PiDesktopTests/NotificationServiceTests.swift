import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Pure trigger/coalescing rules

final class NotificationGateTests: XCTestCase {
    func testFocusedVisibleConversationIsSuppressed() {
        XCTAssertTrue(NotificationGate.isSuppressed(sessionKey: "/a", focusedSessionKey: "/a"))
    }

    func testADifferentOrAbsentFocusIsNeverSuppressed() {
        XCTAssertFalse(NotificationGate.isSuppressed(sessionKey: "/a", focusedSessionKey: "/b"))
        XCTAssertFalse(NotificationGate.isSuppressed(sessionKey: "/a", focusedSessionKey: nil))
    }
}

final class NotificationCoalescerTests: XCTestCase {
    func testARepeatInsideTheWindowDoesNotEmitAgain() {
        var coalescer = NotificationCoalescer()
        let start = Date()
        XCTAssertTrue(coalescer.shouldEmit(sessionKey: "/a", now: start))
        XCTAssertFalse(coalescer.shouldEmit(sessionKey: "/a", now: start.addingTimeInterval(1)))
        XCTAssertTrue(
            coalescer.shouldEmit(sessionKey: "/a", now: start.addingTimeInterval(coalescer.perSessionWindow + 0.1)),
            "Once the per-session window has passed, the same session can notify again"
        )
    }

    func testDifferentSessionsDoNotShareTheSameWindow() {
        var coalescer = NotificationCoalescer()
        let now = Date()
        XCTAssertTrue(coalescer.shouldEmit(sessionKey: "/a", now: now))
        XCTAssertTrue(coalescer.shouldEmit(sessionKey: "/b", now: now))
    }

    func testBurstsAreCappedAcrossAllSessionsRegardlessOfWindow() {
        var coalescer = NotificationCoalescer()
        let now = Date()
        for index in 0..<coalescer.burstLimit {
            XCTAssertTrue(coalescer.shouldEmit(sessionKey: "/session-\(index)", now: now), "Under the cap must still emit")
        }
        XCTAssertFalse(coalescer.shouldEmit(sessionKey: "/one-too-many", now: now), "The burst cap applies across sessions")

        XCTAssertTrue(
            coalescer.shouldEmit(sessionKey: "/later", now: now.addingTimeInterval(coalescer.burstWindow + 0.1)),
            "Once the burst window rolls past, capacity frees up again"
        )
    }
}

// MARK: - AppStore trigger wiring

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

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/pi-desktop-notification-tests")
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary { throw CancellationError() }
}

private struct FakeGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

/// Records every call instead of touching `UNUserNotificationCenter`.
private final class SpyNotificationPresenter: NotificationPresenting {
    var onSelectSession: ((String) -> Void)?
    private(set) var presented: [(sessionKey: String, title: String, body: String)] = []

    func presentDesktopNotification(sessionKey: String, title: String, body: String) {
        presented.append((sessionKey, title, body))
    }
}

@MainActor
final class NotificationTriggerWiringTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiNotify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(isActive: Bool) -> (AppStore, FakeRuntime, SpyNotificationPresenter, SessionSummary) {
        let runtime = FakeRuntime()
        let spy = SpyNotificationPresenter()
        // The monitor's own `isActiveOverride` (whether it polls disk at all) is independent of
        // the store's (whether the app counts as frontmost for notification purposes); the
        // cross-terminal test needs the monitor ticking regardless of which case is exercised.
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter(),
            activityMonitor: SessionActivityMonitor(isActiveOverride: true),
            notificationService: spy,
            isActiveOverride: isActive
        )
        var session = SessionSummary(
            id: "s", fileURL: directory.appendingPathComponent("s.jsonl"), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: "Reviewing PR", preview: "preview",
            messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]
        return (store, runtime, spy, session)
    }

    /// Attaches the runtime to `session` exactly like selecting it and letting `ensureRuntime`
    /// complete does, without needing a real submit.
    private func attachRuntime(_ store: AppStore, runtime: FakeRuntime, to session: SessionSummary) {
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.prepareComposerOptions()
    }

    func testTurnFinishedNotifiesOnceWhenBackgroundedAndNotAgainWithinTheWindow() {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat() // Look elsewhere so the event is not about the visible conversation.

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(spy.presented.count, 1)
        XCTAssertEqual(spy.presented.first?.sessionKey, session.fileURL.standardizedFileURL.path)
        XCTAssertTrue(spy.presented.first!.body.contains("finished"))

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(spy.presented.count, 1, "A repeat within the coalescing window must not notify again")
    }

    func testFocusedVisibleConversationIsNeverNotifiedWhileFrontmost() {
        let (store, runtime, spy, session) = makeStore(isActive: true)
        attachRuntime(store, runtime: runtime, to: session)
        // `store` is already looking at `session` (attachRuntime selected it) and is frontmost.

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertTrue(spy.presented.isEmpty, "The active, visible conversation must stay quiet")
        XCTAssertNil(store.toast, "No banner either: this is the conversation already on screen")
    }

    func testFrontmostButDifferentConversationShowsAnInAppBannerNotADesktopNotification() {
        let (store, runtime, spy, session) = makeStore(isActive: true)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat() // Frontmost, but looking at something else now.

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertTrue(spy.presented.isEmpty, "Frontmost never uses the OS notification path")
        XCTAssertEqual(store.toast?.style, .info)
        XCTAssertTrue(store.toast?.text.contains(session.displayName) == true)
    }

    func testOpeningAnInAppBannerSelectsItsConversation() throws {
        let (store, runtime, _, session) = makeStore(isActive: true)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat()

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        let toast = try XCTUnwrap(store.toast)
        XCTAssertEqual(toast.sessionPath, session.fileURL.standardizedFileURL.path)

        store.openToast(toast)
        XCTAssertEqual(store.selectedSession?.id, session.id)
        XCTAssertNil(store.toast)
    }

    /// Drives the real `SessionActivityMonitor` (no fake snapshot injection needed here, since
    /// nothing shells out) so the running→idle transition reaches `AppStore` exactly as it does
    /// in the app: through the monitor's own published `activities`.
    func testCrossTerminalCompletionNotifiesExactlyOnceOnTheRunningToIdleTransition() async throws {
        let (store, _, spy, session) = makeStore(isActive: false)
        let path = session.fileURL.standardizedFileURL.path
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: session.fileURL)

        store.activityMonitor.setTrackedPaths([path])
        try await waitUntil { store.activityMonitor.activity(forPath: path)?.state == .running }
        XCTAssertTrue(spy.presented.isEmpty, "Still running: nothing to say yet")

        // A terminal stop reason settles the session; the monitor picks this up on its own poll.
        try Data("{\"type\":\"message\",\"id\":\"2\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: session.fileURL)
        store.activityMonitor.tickNow()
        try await waitUntil { store.activityMonitor.activity(forPath: path)?.state == .idle }
        XCTAssertEqual(spy.presented.count, 1)

        store.activityMonitor.tickNow()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(spy.presented.count, 1, "A repeat idle snapshot without a new transition must not notify again")
    }

    // MARK: - Task 5: notification body shows Pi's actual answer

    func testTurnFinishedBodyShowsTheBeginningOfPisActualAnswerNotAGenericPhrase() {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        attachRuntime(store, runtime: runtime, to: session)
        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object(["role": .string("assistant"), "content": .string("The fix is in PaymentService.swift, line 42.")])
        ]))
        // Backgrounded (isActive: false) already means `notify` never suppresses on focus, so
        // the session stays selected here — unlike the other tests in this file, `messages` must
        // still hold the assistant reply when `agent_settled` reads it for the preview.
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(spy.presented.count, 1)
        XCTAssertTrue(
            spy.presented.first!.body.contains("The fix is in PaymentService.swift"),
            "Body: \(spy.presented.first!.body)"
        )
    }

    func testTurnFinishedBodyFallsBackToTheGenericPhraseWithNoAnswerText() {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat()

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertEqual(spy.presented.count, 1)
        XCTAssertTrue(spy.presented.first!.body.contains("finished"))
    }

    func testCrossTerminalTurnFinishedUsesTheHeartbeatPreviewWhenOneIsAvailable() async throws {
        let runtime = FakeRuntime()
        let spy = SpyNotificationPresenter()
        let heartbeatDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: heartbeatDirectory, withIntermediateDirectories: true)
        let store = AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(),
            runtime: runtime,
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter(),
            activityMonitor: SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: heartbeatDirectory),
            notificationService: spy,
            isActiveOverride: false
        )
        let file = directory.appendingPathComponent("cross-terminal.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: file)
        var session = SessionSummary(
            id: "cross", fileURL: file, cwd: directory, createdAt: Date(), modifiedAt: Date(),
            name: "Cross-terminal", preview: "preview", messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]
        store.activityMonitor.setTrackedPaths([file.path])

        try Data("""
        {"sessionId":"cross","sessionFile":"\(file.path)","pid":\(ProcessInfo.processInfo.processIdentifier),"state":"running","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))"}
        """.utf8).write(to: heartbeatDirectory.appendingPathComponent("cross.json"))
        store.activityMonitor.tickNow()
        try await waitUntil { store.activityMonitor.activity(forPath: file.path)?.state == .running }

        try Data("""
        {"sessionId":"cross","sessionFile":"\(file.path)","pid":\(ProcessInfo.processInfo.processIdentifier),"state":"idle","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))","preview":"Done: renamed the export helper."}
        """.utf8).write(to: heartbeatDirectory.appendingPathComponent("cross.json"))
        store.activityMonitor.tickNow()
        try await waitUntil { !spy.presented.isEmpty }

        XCTAssertTrue(spy.presented.first!.body.contains("Done: renamed the export helper"), "Body: \(spy.presented.first!.body)")
    }

    // MARK: - Task 5: only actionable extension notices become a toast

    func testInformationalExtensionNoticeIsLoggedNotToasted() {
        let (store, runtime, spy, session) = makeStore(isActive: true)
        attachRuntime(store, runtime: runtime, to: session)

        runtime.onEvent?(.object([
            "type": .string("extension_ui_request"), "method": .string("notify"),
            "notifyType": .string("info"), "message": .string("Ponytail loaded: full")
        ]))

        XCTAssertNil(store.toast, "Purely informational extension chatter must never interrupt as a toast")
        XCTAssertTrue(spy.presented.isEmpty)
        XCTAssertEqual(store.unknownRPCEvents.last, "[notify] Ponytail loaded: full")
    }

    func testWarningOrErrorExtensionNoticeStillShowsAToast() {
        let (store, runtime, _, session) = makeStore(isActive: true)
        attachRuntime(store, runtime: runtime, to: session)

        runtime.onEvent?(.object([
            "type": .string("extension_ui_request"), "method": .string("notify"),
            "notifyType": .string("error"), "message": .string("Extension X crashed")
        ]))

        XCTAssertEqual(store.toast?.text, "Extension X crashed")
        XCTAssertEqual(store.toast?.style, .error)
    }

    func testQuestionWaitingNotifiesWhenBackgrounded() {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat()

        runtime.onEvent?(.object([
            "type": .string("tool_execution_start"),
            "toolCallId": .string("ask-1"),
            "toolName": .string("ask_user_question"),
            "args": .object(["questions": .array([.object([
                "question": .string("Which scope?"), "header": .string("Scope"),
                "options": .array([.object(["label": .string("A"), "description": .string("a")])])
            ])])])
        ]))
        XCTAssertEqual(spy.presented.count, 1)
        XCTAssertTrue(spy.presented.first!.body.contains("waiting"))
    }

    func testApprovalRequestNotifiesButAQuestionnaireDialogDoesNotDoubleNotify() {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat()

        runtime.onEvent?(.object([
            "type": .string("extension_ui_request"), "method": .string("confirm"),
            "id": .string("dialog-1"), "title": .string("Allow write access?")
        ]))
        XCTAssertEqual(spy.presented.count, 1)
        XCTAssertTrue(spy.presented.first!.body.contains("approval"))
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
