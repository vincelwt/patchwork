import Foundation
import PatchworkKit
import XCTest
@testable import Patchwork

private final class DaemonEventRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }
    func send(
        type: String,
        payload: [String: JSONValue],
        completion: ((Result<JSONValue, Error>) -> Void)?
    ) {}
    func sendUncorrelated(_ value: JSONValue) {}
}

private struct DaemonEventGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

private actor GatedSessionCatalog {
    private var current: [SessionSummary]
    private let gateFirstScan: Bool
    private var calls = 0
    private var firstScanStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirstScan: CheckedContinuation<Void, Never>?

    init(current: [SessionSummary], gateFirstScan: Bool) {
        self.current = current
        self.gateFirstScan = gateFirstScan
    }

    func discover() async -> [SessionSummary] {
        calls += 1
        let captured = current
        guard calls == 1, gateFirstScan else { return captured }
        firstScanStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseFirstScan = $0 }
        return captured
    }

    func waitUntilFirstScanStarts() async {
        guard !firstScanStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func replace(with sessions: [SessionSummary]) { current = sessions }
    func release() { releaseFirstScan?.resume(); releaseFirstScan = nil }
    func callCount() -> Int { calls }
}

private final class GatedSessionRepository: SessionRepositoryProtocol, @unchecked Sendable {
    let rootURL: URL
    let catalog: GatedSessionCatalog

    init(rootURL: URL, sessions: [SessionSummary], gateFirstScan: Bool = true) {
        self.rootURL = rootURL
        catalog = GatedSessionCatalog(current: sessions, gateFirstScan: gateFirstScan)
    }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        await catalog.discover()
    }

    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }

    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw CancellationError()
    }
}

private actor ArchiveOperationGate {
    private let baseThread: PatchworkThread
    private var calls: [Bool] = []
    private var inFlight = 0
    private var maximumInFlight = 0
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?

    init(thread: PatchworkThread) { baseThread = thread }

    func perform(path: String, archived: Bool) async throws -> ThreadResponse {
        calls.append(archived)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        if calls.count == 1 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseFirst = $0 }
        }
        inFlight -= 1
        var thread = baseThread
        thread.path = path
        thread.archived = archived
        return ThreadResponse(thread: thread)
    }

    func waitUntilFirstStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func snapshot() -> (calls: [Bool], maximumInFlight: Int) {
        (calls, maximumInFlight)
    }
}

private actor FlakyDiscoveryState {
    private var failuresRemaining: Int
    private let sessions: [SessionSummary]

    init(failures: Int, sessions: [SessionSummary]) {
        failuresRemaining = failures
        self.sessions = sessions
    }

    func discover() throws -> [SessionSummary] {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CocoaError(.fileReadUnknown)
        }
        return sessions
    }
}

private final class FlakySessionRepository: SessionRepositoryProtocol, @unchecked Sendable {
    let rootURL: URL
    let state: FlakyDiscoveryState

    init(rootURL: URL, failures: Int, sessions: [SessionSummary]) {
        self.rootURL = rootURL
        state = FlakyDiscoveryState(failures: failures, sessions: sessions)
    }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        try await state.discover()
    }

    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }

    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw CancellationError()
    }
}

@MainActor
final class AppStoreDaemonEventTests: XCTestCase {
    private var directory: URL!
    private var overlayURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDaemonEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        overlayURL = directory.appendingPathComponent("overlay.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDaemonSyncRetryBackoffIsBounded() {
        XCTAssertEqual(AppStore.daemonSyncRetryNanoseconds(failureCount: 0), 250_000_000)
        XCTAssertEqual(AppStore.daemonSyncRetryNanoseconds(failureCount: 1), 250_000_000)
        XCTAssertEqual(AppStore.daemonSyncRetryNanoseconds(failureCount: 2), 500_000_000)
        XCTAssertEqual(AppStore.daemonSyncRetryNanoseconds(failureCount: 3), 1_000_000_000)
        XCTAssertEqual(AppStore.daemonSyncRetryNanoseconds(failureCount: 4), 2_000_000_000)
        XCTAssertEqual(AppStore.daemonSyncRetryNanoseconds(failureCount: 99), 5_000_000_000)
    }

    func testReadyBarrierReconcilesAThreadCreatedBeforeSubscription() async throws {
        let session = summary(id: "before-ready", file: "before-ready.jsonl")
        try writeOverlay(managedPaths: [session.fileURL.path])
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: [session], gateFirstScan: false
        )
        let store = makeStore(repository: repository)
        var reconciled = false

        await store.consumeDaemonEvent(
            .unknown(name: "ready", data: .object([:])), reconciled: &reconciled
        )
        await store.waitForDaemonReconciliationForTesting()

        XCTAssertTrue(reconciled)
        XCTAssertEqual(store.sessions.map(\.fileURL), [session.fileURL])
    }

    func testFailedReadyReconciliationRetriesWithoutBlockingTheEventStream() async throws {
        let session = summary(id: "after-retry", file: "after-retry.jsonl")
        try writeOverlay(managedPaths: [session.fileURL.path])
        let repository = FlakySessionRepository(
            rootURL: directory, failures: 1, sessions: [session]
        )
        let store = makeStore(repository: repository)
        var reconciled = false

        let shouldContinue = await store.consumeDaemonEvent(
            .unknown(name: "ready", data: .object([:])), reconciled: &reconciled
        )
        XCTAssertTrue(shouldContinue)
        XCTAssertTrue(reconciled)
        await store.waitForDaemonReconciliationForTesting()
        XCTAssertEqual(store.sessions.map(\.fileURL), [session.fileURL])
    }

    func testDaemonRunEventsPaintAndClearThinkingImmediately() async throws {
        let session = summary(id: "daemon-running", file: "daemon-running.jsonl")
        try writeOverlay(managedPaths: [session.fileURL.path])
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: [session], gateFirstScan: false
        )
        let store = makeStore(repository: repository)
        let refreshed = await store.refreshSessions()
        XCTAssertTrue(refreshed)
        let startedAt = Date(timeIntervalSince1970: 100)
        var reconciled = true

        let queued = Run(
            id: "run-one", threadId: session.id, threadPath: session.fileURL.path,
            trigger: .api, startedAt: startedAt, status: .queued
        )
        let queuedContinues = await store.consumeDaemonEvent(.run(queued), reconciled: &reconciled)
        XCTAssertTrue(queuedContinues)
        let listed = try XCTUnwrap(store.sessions.first)
        XCTAssertTrue(store.isRunning(listed))
        XCTAssertEqual(store.runningSince(listed), startedAt)

        let finished = Run(
            id: "run-one", threadId: session.id, threadPath: session.fileURL.path,
            trigger: .api, startedAt: startedAt, finishedAt: Date(timeIntervalSince1970: 101),
            status: .ok
        )
        let finishedContinues = await store.consumeDaemonEvent(.run(finished), reconciled: &reconciled)
        XCTAssertTrue(finishedContinues)
        XCTAssertFalse(store.isRunning(listed))
    }

    func testReadyDropsRunActivityWhoseTerminalEventWasMissed() async throws {
        let session = summary(id: "reconnected-run", file: "reconnected-run.jsonl")
        try writeOverlay(managedPaths: [session.fileURL.path])
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: [session], gateFirstScan: false
        )
        let store = makeStore(repository: repository)
        let refreshed = await store.refreshSessions()
        XCTAssertTrue(refreshed)
        var reconciled = true
        let running = Run(
            id: "lost-terminal", threadId: session.id, threadPath: session.fileURL.path,
            trigger: .api, startedAt: Date(timeIntervalSince1970: 100), status: .running
        )
        _ = await store.consumeDaemonEvent(.run(running), reconciled: &reconciled)
        XCTAssertTrue(store.isRunning(try XCTUnwrap(store.sessions.first)))

        _ = await store.consumeDaemonEvent(
            .unknown(name: "ready", data: .object([:])), reconciled: &reconciled
        )
        XCTAssertFalse(store.isRunning(try XCTUnwrap(store.sessions.first)))
        await store.waitForDaemonReconciliationForTesting()
    }

    func testReadyAndThreadEventsProjectPathScopedReadState() async throws {
        let session = summary(id: "read-sync", file: "read-sync.jsonl")
        try writeOverlay(managedPaths: [session.fileURL.path], unread: true)
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: [session], gateFirstScan: false
        )
        let store = makeStore(repository: repository)
        var reconciled = false

        let readyContinues = await store.consumeDaemonEvent(
            .unknown(name: "ready", data: .object([:])), reconciled: &reconciled
        )
        XCTAssertTrue(readyContinues)
        await store.waitForDaemonReconciliationForTesting()
        let listed = try XCTUnwrap(store.sessions.first)
        XCTAssertTrue(store.isUnread(listed))

        try writeOverlay(managedPaths: [session.fileURL.path], unread: false)
        let thread = PatchworkThread(
            id: session.id, path: session.fileURL.path, name: session.name,
            cwd: session.cwd.path, folder: directory.lastPathComponent,
            createdAt: session.createdAt, updatedAt: session.modifiedAt,
            unread: false, agent: session.agent
        )
        let threadContinues = await store.consumeDaemonEvent(.thread(thread), reconciled: &reconciled)
        XCTAssertTrue(threadContinues)
        XCTAssertFalse(store.isUnread(try XCTUnwrap(store.sessions.first)))
    }

    func testPendingOfflineRestoreWinsAStaleDaemonArchiveAfterRelaunch() async throws {
        let session = summary(id: "offline-restore", file: "offline-restore.jsonl")
        let persistence = AppPersistence(baseURL: directory)
        persistence.setArchived(
            false,
            sessionID: session.id,
            sessionPath: session.fileURL.path,
            queueDaemonSync: true
        )
        try writeOverlay(
            managedPaths: [session.fileURL.path], archivedPaths: [session.fileURL.path]
        )
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: [session], gateFirstScan: false
        )

        let relaunched = makeStore(repository: repository)
        let didRefresh = await relaunched.refreshSessions()
        XCTAssertTrue(didRefresh)

        XCTAssertFalse(try XCTUnwrap(relaunched.sessions.first).isArchived)
        XCTAssertEqual(
            relaunched.persistence.state.pendingDaemonArchiveIntentBySessionPath[
                session.fileURL.standardizedFileURL.path
            ],
            false
        )
    }

    func testRapidArchiveRestoreIsSerializedAndStaleResponseCannotRepaint() async throws {
        let session = summary(id: "archive-order", file: "archive-order.jsonl")
        try writeOverlay(managedPaths: [session.fileURL.path])
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: [session], gateFirstScan: false
        )
        let gate = ArchiveOperationGate(thread: PatchworkThread(
            id: session.id, path: session.fileURL.path, name: session.name,
            cwd: session.cwd.path, folder: directory.lastPathComponent,
            createdAt: session.createdAt, updatedAt: session.modifiedAt,
            agent: session.agent
        ))
        let store = makeStore(
            repository: repository,
            archiveThreadOperation: { path, archived in
                try await gate.perform(path: path, archived: archived)
            }
        )
        let refreshed = await store.refreshSessions()
        XCTAssertTrue(refreshed)

        await store.requestArchive(try XCTUnwrap(store.sessions.first))
        await gate.waitUntilFirstStarts()
        XCTAssertTrue(try XCTUnwrap(store.sessions.first).isArchived)
        store.toggleArchive(try XCTUnwrap(store.sessions.first))
        XCTAssertFalse(try XCTUnwrap(store.sessions.first).isArchived)
        await gate.release()
        await store.waitForArchiveSyncForTesting(path: session.fileURL.path)

        let snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.calls, [true, false])
        XCTAssertEqual(snapshot.maximumInFlight, 1)
        XCTAssertFalse(try XCTUnwrap(store.sessions.first).isArchived)
        XCTAssertNil(
            store.persistence.state.pendingDaemonArchiveIntentBySessionPath[
                session.fileURL.standardizedFileURL.path
            ]
        )
    }

    func testScheduleDeletionEventReloadsSidebarAutomationProjection() async throws {
        let repository = GatedSessionRepository(rootURL: directory, sessions: [], gateFirstScan: false)
        let store = makeStore(repository: repository)
        let service = InMemoryScheduleService(entries: [
            ScheduleEntry(
                id: "scheduled", name: "Scheduled", target: .existingThread(threadID: "thread-1"),
                prompt: "Continue", trigger: .interval(everySeconds: 60)
            )
        ])
        store.cachedScheduleService = service
        var reconciled = true

        let scheduleContinues = await store.consumeDaemonEvent(
            .unknown(name: "schedule_deleted", data: .object([:])), reconciled: &reconciled
        )
        XCTAssertTrue(scheduleContinues)
        await store.waitForDaemonReconciliationForTesting()
        XCTAssertEqual(store.scheduledThreadIDs, ["thread-1"])
    }

    func testThreadEventPaintsWhileReadyCatalogReconciliationIsBlocked() async throws {
        let repository = GatedSessionRepository(rootURL: directory, sessions: [])
        let store = makeStore(repository: repository)
        let session = summary(id: "instant-event", file: "instant-event.jsonl")
        let thread = PatchworkThread(
            id: session.id, path: session.fileURL.path, name: session.name,
            cwd: session.cwd.path, folder: directory.lastPathComponent,
            createdAt: session.createdAt, updatedAt: session.modifiedAt, agent: session.agent
        )
        var reconciled = false
        try writeOverlay(managedPaths: [session.fileURL.path])

        let readyContinues = await store.consumeDaemonEvent(
            .unknown(name: "ready", data: .object([:])), reconciled: &reconciled
        )
        XCTAssertTrue(readyContinues)
        await repository.catalog.waitUntilFirstScanStarts()
        let threadContinues = await store.consumeDaemonEvent(.thread(thread), reconciled: &reconciled)
        XCTAssertTrue(threadContinues)
        XCTAssertEqual(store.sessions.map(\.fileURL), [session.fileURL])

        await repository.catalog.replace(with: [session])
        await repository.catalog.release()
        await store.waitForDaemonReconciliationForTesting()
        for _ in 0..<100 where store.sessions.map(\.fileURL) != [session.fileURL] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.sessions.map(\.fileURL), [session.fileURL])
    }

    func testThreadEventDuringAStaleScanQueuesASecondScanWithoutDuplication() async throws {
        let repository = GatedSessionRepository(rootURL: directory, sessions: [])
        let store = makeStore(repository: repository)
        let session = summary(id: "during-scan", file: "during-scan.jsonl")
        let thread = PatchworkThread(
            id: session.id, path: session.fileURL.path, name: session.name,
            cwd: session.cwd.path, folder: directory.lastPathComponent,
            createdAt: session.createdAt, updatedAt: session.modifiedAt, agent: session.agent
        )

        let firstScan = Task { await store.refreshSessions() }
        await repository.catalog.waitUntilFirstScanStarts()
        await repository.catalog.replace(with: [session])
        try writeOverlay(managedPaths: [session.fileURL.path])
        store.applyDaemonThreadUpdate(
            thread, daemonOverlay: DaemonWorktreeProjects.loadSnapshot(from: overlayURL)
        )
        await repository.catalog.release()
        _ = await firstScan.value

        for _ in 0..<100 {
            if await repository.catalog.callCount() >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let callCount = await repository.catalog.callCount()
        XCTAssertGreaterThanOrEqual(callCount, 2)
        XCTAssertEqual(store.sessions.map(\.fileURL), [session.fileURL])
    }

    func testFirstFullScanPrioritizesANewThreadAfterACachedLargeCatalog() async throws {
        let heartbeatDirectory = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(
            at: heartbeatDirectory, withIntermediateDirectories: true
        )
        let monitor = SessionActivityMonitor(
            isActiveOverride: true, heartbeatDirectory: heartbeatDirectory
        )
        var initial: [SessionSummary] = []
        for index in 0..<200 {
            let item = summary(id: "existing-\(index)", file: "existing-\(index).jsonl")
            try Data("{\"type\":\"message\",\"id\":\"done-\(index)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
                .write(to: item.fileURL)
            initial.append(item)
        }
        let created = summary(id: "created-in-cli", file: "created-in-cli.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"prompt\",\"message\":{\"role\":\"user\"}}\n".utf8)
            .write(to: created.fileURL)
        let repository = GatedSessionRepository(
            rootURL: directory, sessions: initial + [created], gateFirstScan: false
        )
        try writeOverlay(managedPaths: (initial + [created]).map { $0.fileURL.path })
        let store = makeStore(repository: repository, activityMonitor: monitor)
        // Bootstrap restores cached summaries before the first disk discovery. Preserve that
        // ordering here so the newly created CLI path joins at index 200 in the monitor.
        store.sessions = initial
        monitor.setTrackedPaths(initial.map { $0.fileURL.path })
        try await waitUntil {
            monitor.activities.count >= SessionActivityMonitor.fallbackStatsPerTick
        }
        XCTAssertNil(monitor.activity(forPath: created.fileURL.path))

        let loadedUpdatedCatalog = await store.refreshSessions()
        XCTAssertTrue(loadedUpdatedCatalog)
        try await waitUntil(timeout: 1) {
            monitor.activity(forPath: created.fileURL.path)?.state == .running
        }
    }

    func testLocalOwnershipDuringAStaleScanQueuesASecondCustomRootScan() async throws {
        let repository = GatedSessionRepository(rootURL: directory, sessions: [])
        let store = makeStore(repository: repository)
        let customRoot = directory.appendingPathComponent("custom", isDirectory: true)
        let session = SessionSummary(
            id: "local-materialization",
            fileURL: customRoot.appendingPathComponent("owned.jsonl"),
            cwd: customRoot,
            createdAt: Date(), modifiedAt: Date(), name: "Owned", preview: "",
            messageCount: 0, metrics: TokenMetrics(), isArchived: false
        )

        let firstScan = Task { await store.refreshSessions() }
        await repository.catalog.waitUntilFirstScanStarts()
        XCTAssertTrue(store.recordAppStartedSessionPath(session.fileURL.path))
        await repository.catalog.replace(with: [session])
        await repository.catalog.release()
        _ = await firstScan.value

        for _ in 0..<100 {
            if await repository.catalog.callCount() >= 2,
               store.sessions.map(\.fileURL) == [session.fileURL] { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let callCount = await repository.catalog.callCount()
        XCTAssertGreaterThanOrEqual(callCount, 2)
        XCTAssertEqual(store.sessions.map(\.fileURL), [session.fileURL])
        XCTAssertTrue(
            store.persistence.state.appStartedSessionPaths.contains(
                session.fileURL.standardizedFileURL.path
            )
        )
    }

    private func makeStore(
        repository: SessionRepositoryProtocol,
        archiveThreadOperation: ArchiveThreadOperation? = nil,
        activityMonitor: SessionActivityMonitor? = nil
    ) -> AppStore {
        let store = AppStore(
            repository: repository,
            gitService: DaemonEventGitService(),
            runtime: DaemonEventRuntime(),
            persistence: AppPersistence(baseURL: directory),
            activityMonitor: activityMonitor,
            daemonWorktreeProjectsURL: overlayURL,
            archiveThreadOperation: archiveThreadOperation
        )
        store.cachedScheduleService = InMemoryScheduleService()
        return store
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func summary(id: String, file: String) -> SessionSummary {
        var summary = SessionSummary(
            id: id, fileURL: directory.appendingPathComponent(file), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: id, preview: "",
            messageCount: 0, metrics: TokenMetrics(), isArchived: false
        )
        summary.prepareSearchKey()
        return summary
    }

    private func writeOverlay(
        managedPaths: [String], unread: Bool? = nil, archivedPaths: [String] = []
    ) throws {
        var payload: [String: Any] = ["managedThreadPaths": managedPaths]
        if !archivedPaths.isEmpty { payload["archivedThreadPaths"] = archivedPaths }
        if let unread, let path = managedPaths.first {
            payload["readOverrides"] = [
                path: [
                    "unread": unread,
                    "markedAt": PatchworkDate.string(from: Date().addingTimeInterval(60)),
                ]
            ]
        }
        try JSONSerialization.data(withJSONObject: payload).write(to: overlayURL)
    }
}
