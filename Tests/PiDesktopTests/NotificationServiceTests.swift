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
            activityMonitor: SessionActivityMonitor(
                isActiveOverride: isActive,
                heartbeatDirectory: directory.appendingPathComponent("heartbeats")
            ),
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

    func testAgentSettledWithoutANewCompletionIDDoesNotNotify() {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        attachRuntime(store, runtime: runtime, to: session)
        store.openNewChat()

        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertTrue(spy.presented.isEmpty, "Run-state events are not completion signals")
    }

    func testFocusedVisibleCompletionIsNeverNotifiedWhileFrontmost() async throws {
        let (store, runtime, spy, session) = makeStore(isActive: true)
        try Data("{\"type\":\"message\",\"id\":\"user\",\"message\":{\"role\":\"user\"}}\n".utf8).write(to: session.fileURL)
        attachRuntime(store, runtime: runtime, to: session)
        store.activityMonitor.setTrackedPaths([session.fileURL.path])
        try await waitUntil { store.activityMonitor.activity(forPath: session.fileURL.path) != nil }

        try Data("{\"type\":\"message\",\"id\":\"answer\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: session.fileURL)
        store.activityMonitor.tickNow()
        try await waitUntil { store.activityMonitor.activity(forPath: session.fileURL.path)?.latestCompletedEntryID == "answer" }

        XCTAssertTrue(spy.presented.isEmpty)
        XCTAssertNil(store.toast)
    }

    func testFrontmostDifferentConversationGetsCompletionBannerAndCanOpenIt() async throws {
        let (store, _, spy, session) = makeStore(isActive: true)
        try Data("{\"type\":\"message\",\"id\":\"user\",\"message\":{\"role\":\"user\"}}\n".utf8).write(to: session.fileURL)
        store.activityMonitor.setTrackedPaths([session.fileURL.path])
        try await waitUntil { store.activityMonitor.activity(forPath: session.fileURL.path) != nil }

        try Data("{\"type\":\"message\",\"id\":\"answer\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: session.fileURL)
        store.activityMonitor.tickNow()
        try await waitUntil { store.toast != nil }

        XCTAssertTrue(spy.presented.isEmpty, "Frontmost uses an in-app banner")
        let toast = try XCTUnwrap(store.toast)
        XCTAssertEqual(toast.sessionPath, session.fileURL.standardizedFileURL.path)
        XCTAssertEqual(toast.text, NotificationTrigger.turnFinished.summary)
        XCTAssertFalse(toast.text.contains(session.displayName), "In-app banners omit the conversation name")
        store.openToast(toast)
        XCTAssertEqual(store.selectedSession?.id, session.id)
    }

    func testOfflineInterruptionDoesNotNotifyBeforeItsContinuation() async throws {
        let (store, runtime, spy, session) = makeStore(isActive: false)
        let path = session.fileURL.standardizedFileURL.path
        try Data("{\"type\":\"message\",\"id\":\"baseline\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: session.fileURL)
        store.activityMonitor.setTrackedPaths([path])
        try await waitUntil { store.activityMonitor.activity(forPath: path)?.latestCompletedEntryID == "baseline" }

        attachRuntime(store, runtime: runtime, to: session)
        runtime.onEvent?(.object(["type": .string("agent_start")]))
        store.setConnectivityForTesting(isOnline: false)
        runtime.onEvent?(.object(["type": .string("auto_retry_start"), "attempt": .number(1)]))
        store.openNewChat()

        let handle = try FileHandle(forWritingTo: session.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"offline-error\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"error\"}}\n".utf8))
        try handle.close()
        store.activityMonitor.tickNow()
        try await waitUntil { store.activityMonitor.activity(forPath: path)?.latestCompletedEntryID == "offline-error" }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(spy.presented.isEmpty, "The interrupted attempt is not terminal while Desktop will continue it")
    }

    func testBackgroundCompletionsNotifyOncePerDistinctIDWithoutAStateTransition() async throws {
        let (store, _, spy, session) = makeStore(isActive: false)
        let path = session.fileURL.standardizedFileURL.path
        let fixedMtime = Date().addingTimeInterval(-600)
        try Data("{\"type\":\"message\",\"id\":\"baseline\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: session.fileURL)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: path)

        store.activityMonitor.setTrackedPaths([path])
        try await waitUntil { store.activityMonitor.activity(forPath: path)?.latestCompletedEntryID == "baseline" }
        XCTAssertTrue(spy.presented.isEmpty, "Existing history is a quiet baseline")

        let handle = try FileHandle(forWritingTo: session.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"second\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: path)
        store.activityMonitor.tickNow()
        try await waitUntil { spy.presented.count == 1 }

        store.activityMonitor.tickNow()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(spy.presented.count, 1, "Duplicate observation of one completion ID stays silent")

        let next = try FileHandle(forWritingTo: session.fileURL)
        try next.seekToEnd()
        try next.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"third\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"error\"}}\n".utf8))
        try next.close()
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: path)
        store.activityMonitor.tickNow()
        try await waitUntil { spy.presented.count == 2 }
    }

    // MARK: - Task 5: notification body shows Pi's actual answer

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
        {"sessionId":"cross","sessionFile":"\(file.path)","pid":\(ProcessInfo.processInfo.processIdentifier),"state":"idle","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))","preview":"Done: renamed the export helper.","stopReason":"stop","completionId":"answer"}
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
