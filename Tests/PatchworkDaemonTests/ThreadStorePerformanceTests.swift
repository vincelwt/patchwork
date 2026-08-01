import Foundation
import PatchworkKit
import XCTest
@testable import PatchworkDaemon

private final class CatalogScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let waiterEntered = DispatchSemaphore(value: 0)
    private var didBlock = false

    func blockFirstScan() {
        lock.lock()
        let shouldBlock = !didBlock
        if shouldBlock { didBlock = true }
        lock.unlock()
        guard shouldBlock else { return }
        started.signal()
        release.wait()
    }

    func waitUntilStarted() { started.wait() }
    func unblock() { release.signal() }
    func signalWaiter() { waiterEntered.signal() }
    func waitUntilWaiterEntered() { waiterEntered.wait() }
}

private final class CatalogParseProbe: @unchecked Sendable {
    private let expectedFirstWave: Int
    private let lock = NSLock()
    private let firstWaveReady = DispatchSemaphore(value: 0)
    private let releaseFirstWave = DispatchSemaphore(value: 0)
    private var started = 0
    private var inFlight = 0
    private var maximumInFlight = 0

    init(expectedFirstWave: Int) {
        self.expectedFirstWave = expectedFirstWave
    }

    func enter(_ url: URL) {
        lock.lock()
        started += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        let shouldBlock = started <= expectedFirstWave
        let completedFirstWave = started == expectedFirstWave
        lock.unlock()

        if completedFirstWave { firstWaveReady.signal() }
        if shouldBlock { releaseFirstWave.wait() }

        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    func waitForFirstWave(timeout: DispatchTimeInterval) -> Bool {
        firstWaveReady.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        for _ in 0..<expectedFirstWave { releaseFirstWave.signal() }
    }

    func snapshot() -> (started: Int, maximumInFlight: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (started, maximumInFlight)
    }
}

final class ThreadStorePerformanceTests: XCTestCase {
    func testPointPublicationRemainsResponsiveWhileColdCatalogScanIsBlocked() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = TestSupport.writeSessionFile(
            in: directory, id: "responsive-during-scan", cwd: directory.path
        )
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let gate = CatalogScanGate()
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json")),
            catalogScanHook: { gate.blockFirstScan() }
        )
        let scan = Task {
            try await store.listThreads(
                query: nil, limit: 10, cursor: nil, archived: nil, running: nil
            )
        }
        await Task.detached { gate.waitUntilStarted() }.value
        let release = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            gate.unblock()
        }
        var parsed = try SessionThreadParser.thread(at: file)
        parsed.agent = .pi

        let startedAt = Date()
        let point = await store.presentCreatedThread(parsed)
        let latency = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(point.id, parsed.id)
        XCTAssertLessThan(
            latency, 0.5,
            "point work must enter the actor while detached catalog I/O is still blocked"
        )
        await release.value
        _ = try await scan.value
    }

    func testColdCatalogParsingUsesFourWorkersAndWarmCatalogUsesTheCache() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<8 {
            _ = TestSupport.writeSessionFile(
                in: directory, id: "parallel-\(index)", cwd: directory.path
            )
        }
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let probe = CatalogParseProbe(expectedFirstWave: 4)
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json")),
            catalogParseHook: { probe.enter($0) }
        )

        let coldLoad = Task {
            try await store.listThreads(
                query: nil, limit: 20, cursor: nil, archived: nil, running: nil
            )
        }
        let filledFirstWave = await Task.detached {
            probe.waitForFirstWave(timeout: .seconds(2))
        }.value
        probe.release()
        XCTAssertTrue(filledFirstWave, "four catalog parses should be admitted concurrently")
        let cold = try await coldLoad.value
        XCTAssertEqual(cold.threads.count, 8)
        XCTAssertEqual(probe.snapshot().started, 8)
        XCTAssertEqual(probe.snapshot().maximumInFlight, 4)

        let warm = try await store.listThreads(
            query: nil, limit: 20, cursor: nil, archived: nil, running: nil
        )
        XCTAssertEqual(warm.threads.map(\.path), cold.threads.map(\.path))
        XCTAssertEqual(probe.snapshot().started, 8, "unchanged files should not be parsed twice")
    }

    func testManagedCustomRootThreadSurvivesRescansRestartAndDeletion() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = TestSupport.writeSessionFile(
            in: directory, id: "custom-managed", cwd: directory.path
        )
        let defaultRoot = directory.appendingPathComponent("default", isDirectory: true)
        let overlayURL = directory.appendingPathComponent("overlay.json")
        let overlay = DaemonOverlayStore(fileURL: overlayURL)
        try await overlay.recordManagedThread(path: custom.path)

        func makeStore(overlay: DaemonOverlayStore) -> ThreadStore {
            ThreadStore(
                rootURL: defaultRoot,
                roots: [(.pi, defaultRoot)],
                activityDirectoryURL: directory.appendingPathComponent("activity"),
                appStateURL: directory.appendingPathComponent("state.json"),
                logger: TestSupport.logger(in: directory),
                overlay: overlay
            )
        }

        let store = makeStore(overlay: overlay)
        for _ in 0..<2 {
            let listed = try await store.listThreads(
                query: nil, limit: 10, cursor: nil, archived: nil, running: nil
            )
            XCTAssertEqual(listed.threads.map(\.id), ["custom-managed"])
        }

        let reopened = makeStore(overlay: DaemonOverlayStore(fileURL: overlayURL))
        let afterRestart = try await reopened.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )
        XCTAssertEqual(afterRestart.threads.map(\.path), [custom.standardizedFileURL.path])

        try FileManager.default.removeItem(at: custom)
        let warmProjection = await reopened.activityProjection(
            excludingPaths: [], legacyIDs: []
        )
        XCTAssertTrue(warmProjection.threadsWithoutHeartbeat.isEmpty)
        let afterDeletion = try await reopened.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )
        XCTAssertTrue(afterDeletion.threads.isEmpty)
    }

    func testAppOwnedCustomRootThreadIsRecoveredAfterDaemonRestart() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = TestSupport.writeSessionFile(
            in: directory, id: "custom-app-owned", cwd: directory.path
        )
        let appStateURL = directory.appendingPathComponent("state.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "appStartedSessionPaths": [custom.path]
        ])
        try data.write(to: appStateURL)
        let defaultRoot = directory.appendingPathComponent("default", isDirectory: true)
        let store = ThreadStore(
            rootURL: defaultRoot,
            roots: [(.pi, defaultRoot)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: appStateURL,
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )

        let listed = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )

        XCTAssertEqual(listed.threads.map(\.id), ["custom-app-owned"])
        XCTAssertEqual(listed.threads.first?.agent, .pi)
    }

    func testNewCustomRootSeedInvalidatesFastMutationResolution() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedID = "duplicate-after-state-change"
        let rooted = TestSupport.writeSessionFile(
            in: directory, id: sharedID, cwd: directory.path
        )
        let customParent = directory.appendingPathComponent("custom", isDirectory: true)
        let custom = TestSupport.writeSessionFile(
            in: customParent, id: sharedID, cwd: customParent.path
        )
        let appStateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: [:]).write(to: appStateURL, options: .atomic)
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: appStateURL,
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )

        let initial = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )
        XCTAssertEqual(initial.threads.map(\.path), [rooted.standardizedFileURL.path])

        try JSONSerialization.data(withJSONObject: [
            "appStartedSessionPaths": [custom.path]
        ]).write(to: appStateURL, options: .atomic)

        do {
            _ = try await store.resolveForMutation(idOrPath: sharedID)
            XCTFail("a newly seeded duplicate must make the id ambiguous")
        } catch let error as DaemonHTTPError {
            guard case let .badRequest(code, _) = error else {
                return XCTFail("expected ambiguous_thread_id, got \(error)")
            }
            XCTAssertEqual(code, "ambiguous_thread_id")
        }
    }

    func testActivityProjectionUsesOneCoherentCatalog() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TestSupport.writeSessionFile(
            in: directory, id: "activity-first", cwd: directory.path,
            lines: [
                #"{"type":"message","id":"done","message":{"role":"assistant","content":"done","stopReason":"stop"}}"#
            ]
        )
        let second = TestSupport.writeSessionFile(
            in: directory, id: "activity-second", cwd: directory.path,
            lines: [#"{"type":"message","id":"running","message":{"role":"user","content":"work"}}"#]
        )
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )
        _ = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )
        _ = try await store.setUnread(true, idOrPath: first.path)

        let projection = await store.activityProjection(
            excludingPaths: [first.standardizedFileURL.path], legacyIDs: []
        )

        XCTAssertEqual(projection.threadsWithoutHeartbeat.map(\.path), [second.path])
        XCTAssertEqual(projection.unreadCount, 1)
    }

    func testWarmActivityProjectionSeesAnAppendToAnOldHeartbeatFreeTranscript() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = TestSupport.writeSessionFile(
            in: directory, id: "warm-external-append", cwd: directory.path,
            lines: [#"{"type":"message","id":"done","message":{"role":"assistant","content":"done","stopReason":"stop"}}"#]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path
        )
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )
        _ = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"message","id":"new-work","message":{"role":"user","content":"continue"}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))

        let projection = await store.activityProjection(
            excludingPaths: [], legacyIDs: [], now: Date()
        )

        XCTAssertEqual(projection.threadsWithoutHeartbeat.map(\.path), [file.path])
    }

    func testTerminalOverrideAppliesOnlyToTheCompletedTranscriptVersion() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = TestSupport.writeSessionFile(
            in: directory, id: "settled-version", cwd: directory.path,
            lines: [
                #"{"type":"message","id":"first","message":{"role":"user","content":"work"}}"#
            ]
        )
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )
        _ = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )
        var parsed = try SessionThreadParser.thread(at: file)
        parsed.agent = .pi

        let settled = await store.presentCreatedThread(parsed, runningOverride: false)
        XCTAssertFalse(settled.running)
        let stillSettled = await store.thread(idOrPath: file.path)
        XCTAssertEqual(stillSettled?.running, false)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            #"{"type":"message","id":"next","message":{"role":"user","content":"more work"}}"#.utf8
        ))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let runningAgain = await store.thread(idOrPath: file.path)
        XCTAssertEqual(runningAgain?.running, true)
    }

    func testHeartbeatFreeFallbackTranscodesPiCodexAndClaudeTails() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pi = TestSupport.writeSessionFile(
            in: directory, id: "running-pi", cwd: directory.path,
            lines: [#"{"type":"message","id":"pi-work","message":{"role":"user","content":"continue"}}"#]
        )
        let piRoot = directory.appendingPathComponent("sessions", isDirectory: true)
        let codexRoot = directory.appendingPathComponent("codex", isDirectory: true)
        let codex = TestSupport.writeCodexRollout(
            in: codexRoot, id: "running-codex", cwd: directory.path
        )
        let codexHandle = try FileHandle(forWritingTo: codex)
        try codexHandle.seekToEnd()
        try codexHandle.write(contentsOf: Data(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-live"}}"#.utf8
        ))
        try codexHandle.write(contentsOf: Data("\n".utf8))
        for index in 0..<(SessionFileActivityClassifier.codexLifecycleScanLines + 32) {
            try codexHandle.write(contentsOf: Data(
                #"{"type":"event_msg","payload":{"type":"agent_reasoning","id":"progress-\#(index)"}}"#.utf8
            ))
            try codexHandle.write(contentsOf: Data("\n".utf8))
        }
        try codexHandle.close()
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        let claude = TestSupport.writeClaudeTranscript(
            in: claudeRoot, id: "running-claude", cwd: directory.path
        )
        let now = Date()
        for file in [pi, codex, claude] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-7)],
                ofItemAtPath: file.path
            )
        }
        let store = ThreadStore(
            rootURL: piRoot,
            roots: [(.pi, piRoot), (.codex, codexRoot), (.claude, claudeRoot)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )
        _ = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )

        let projection = await store.activityProjection(
            excludingPaths: [], legacyIDs: [], now: now
        )

        XCTAssertEqual(
            Set(projection.threadsWithoutHeartbeat.map(\.path)),
            Set([pi.path, codex.path, claude.path])
        )
    }

    func testFastActivityProjectionDoesNotBlockPointReadsOnTheStoreActor() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = TestSupport.writeSessionFile(
            in: directory, id: "point-during-activity", cwd: directory.path
        )
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let gate = CatalogScanGate()
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json")),
            activityProjectionHook: { gate.blockFirstScan() }
        )
        _ = try await store.listThreads(
            query: nil, limit: 10, cursor: nil, archived: nil, running: nil
        )
        let projection = Task {
            await store.activityProjection(excludingPaths: [], legacyIDs: [])
        }
        await Task.detached { gate.waitUntilStarted() }.value

        let startedAt = Date()
        let point = await store.thread(idOrPath: file.path)
        let latency = Date().timeIntervalSince(startedAt)

        XCTAssertNotNil(point)
        XCTAssertLessThan(latency, 0.5)
        gate.unblock()
        _ = await projection.value
    }

    func testCatalogWaiterReappliesItsOwnHeartbeatSnapshot() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = TestSupport.writeSessionFile(
            in: directory, id: "waiter-heartbeat", cwd: directory.path,
            lines: [
                #"{"type":"message","id":"done","message":{"role":"assistant","content":"done","stopReason":"stop"}}"#
            ]
        )
        try JSONSerialization.data(withJSONObject: [
            "manuallyUnreadSessionPaths": [file.path]
        ]).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let gate = CatalogScanGate()
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json")),
            catalogScanHook: { gate.blockFirstScan() },
            catalogWaiterHook: { gate.signalWaiter() }
        )
        let firstCaller = Task {
            try await store.listThreads(
                query: nil, limit: 10, cursor: nil, archived: nil, running: nil
            )
        }
        await Task.detached { gate.waitUntilStarted() }.value
        let now = Date()
        let heartbeat = Heartbeat(
            sessionId: "waiter-heartbeat",
            sessionFile: file.path,
            cwd: directory.path,
            pid: getpid(),
            state: "running",
            startedAt: now,
            updatedAt: now
        )
        let waitingCaller = Task {
            await store.activityProjection(
                excludingPaths: [file.path],
                legacyIDs: [],
                heartbeats: [heartbeat],
                runningHeartbeats: [heartbeat],
                now: now
            )
        }
        await Task.detached { gate.waitUntilWaiterEntered() }.value
        gate.unblock()

        let first = try await firstCaller.value
        let projection = await waitingCaller.value

        XCTAssertEqual(first.threads.first?.unread, true)
        XCTAssertEqual(projection.unreadCount, 0)
    }

    func testPaginationUsesOneCoherentCatalogSnapshot() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<5 {
            _ = TestSupport.writeSessionFile(
                in: directory, id: "session-\(index)", cwd: directory.path,
                lines: [#"{"type":"message","id":"m\#(index)","message":{"role":"user","content":"message \#(index)"}}"#]
            )
        }
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let store = ThreadStore(
            rootURL: root,
            roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )

        let first = try await store.listThreads(
            query: nil, limit: 2, cursor: nil, archived: nil, running: nil
        )
        let cursor = try XCTUnwrap(first.nextCursor)
        _ = TestSupport.writeSessionFile(in: directory, id: "new-after-page-one", cwd: directory.path)
        let second = try await store.listThreads(
            query: nil, limit: 2, cursor: cursor, archived: nil, running: nil
        )
        let third = try await store.listThreads(
            query: nil, limit: 2, cursor: try XCTUnwrap(second.nextCursor), archived: nil, running: nil
        )

        let paged = first.threads + second.threads + third.threads
        XCTAssertEqual(paged.count, 5)
        XCTAssertEqual(Set(paged.map(\.id)).count, 5)
        XCTAssertFalse(paged.contains { $0.id == "new-after-page-one" })
        XCTAssertNil(third.nextCursor)

        let refreshed = try await store.listThreads(
            query: nil, limit: 20, cursor: nil, archived: nil, running: nil
        )
        XCTAssertTrue(refreshed.threads.contains { $0.id == "new-after-page-one" })
    }

    func testExpiredAndMalformedCursorsNeverSilentlyRestartAtPageOne() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            _ = TestSupport.writeSessionFile(
                in: directory, id: "session-\(index)", cwd: directory.path
            )
        }
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let store = ThreadStore(
            rootURL: root, roots: [(.pi, root)],
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        )
        let first = try await store.listThreads(
            query: nil, limit: 1, cursor: nil, archived: nil, running: nil
        )
        let expiredCursor = try XCTUnwrap(first.nextCursor)
        for _ in 0..<8 {
            _ = try await store.listThreads(
                query: nil, limit: 1, cursor: nil, archived: nil, running: nil
            )
        }

        do {
            _ = try await store.listThreads(
                query: nil, limit: 1, cursor: expiredCursor, archived: nil, running: nil
            )
            XCTFail("an evicted snapshot must be reported")
        } catch let error as DaemonHTTPError {
            guard case let .conflict(code, _) = error else {
                return XCTFail("expected cursor_expired, got \(error)")
            }
            XCTAssertEqual(code, "cursor_expired")
        }

        do {
            _ = try await store.listThreads(
                query: nil, limit: 1, cursor: "not-a-cursor", archived: nil, running: nil
            )
            XCTFail("malformed cursor must be rejected")
        } catch let error as DaemonHTTPError {
            guard case let .badRequest(code, _) = error else {
                return XCTFail("expected invalid_cursor, got \(error)")
            }
            XCTAssertEqual(code, "invalid_cursor")
        }

        let legacy = try await store.listThreads(
            query: nil, limit: 1, cursor: "1", archived: nil, running: nil
        )
        XCTAssertEqual(legacy.threads.count, 1)
    }

    /// Read-only production-corpus gate. The index and app state live in a temporary directory,
    /// so the test measures a true cold daemon scan without disturbing the installed app.
    func testMeasuresColdAndWarmInstalledThreadCatalogWhenRequested() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PATCHWORK_REAL_SESSION_SMOKE"] == "1",
            "Set PATCHWORK_REAL_SESSION_SMOKE=1 to scan installed agent histories"
        )
        let root = SessionScanner.defaultRootURL()
        let roots = SessionScanner.roots(piRootURL: root)
        try XCTSkipUnless(
            roots.contains { FileManager.default.fileExists(atPath: $0.url.path) },
            "No installed agent session roots"
        )
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(
            rootURL: root,
            roots: roots,
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json")),
            indexFileURL: directory.appendingPathComponent("thread-index.json")
        )
        let clock = ContinuousClock()

        let coldStart = clock.now
        let cold = try await store.listThreads(
            query: nil, limit: 10_000, cursor: nil, archived: nil, running: nil
        )
        let coldDuration = coldStart.duration(to: clock.now)
        let warmStart = clock.now
        let warm = try await store.listThreads(
            query: nil, limit: 10_000, cursor: nil, archived: nil, running: nil
        )
        let warmDuration = warmStart.duration(to: clock.now)

        var pointSamples: [TimeInterval] = []
        let pointPath = try XCTUnwrap(warm.threads.first?.path)
        for _ in 0..<50 {
            let startedAt = Date()
            let point = await store.thread(idOrPath: pointPath)
            XCTAssertNotNil(point)
            pointSamples.append(Date().timeIntervalSince(startedAt))
        }
        var activitySamples: [TimeInterval] = []
        for _ in 0..<20 {
            let startedAt = Date()
            _ = await store.activityProjection(excludingPaths: [], legacyIDs: [])
            activitySamples.append(Date().timeIntervalSince(startedAt))
        }
        pointSamples.sort()
        activitySamples.sort()
        let pointP95 = pointSamples[Int(Double(pointSamples.count - 1) * 0.95)]
        let activityP95 = activitySamples[Int(Double(activitySamples.count - 1) * 0.95)]

        XCTAssertFalse(cold.threads.isEmpty)
        // This test intentionally scans live installed histories. An active agent can append
        // between the cold and warm reads, legitimately moving that thread to the front without
        // changing catalog membership.
        XCTAssertEqual(Set(warm.threads.map(\.path)), Set(cold.threads.map(\.path)))
        await store.waitForIndexPersistence()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("thread-index.json").path
        ))
        print(
            "[perf] daemon catalog threads=\(cold.threads.count) "
                + "cold=\(coldDuration) warm=\(warmDuration) "
                + "point-p95=\(pointP95)s activity-p95=\(activityP95)s"
        )
        XCTAssertLessThan(pointP95, 0.100, "warm point opens should stay below 100 ms")
        XCTAssertLessThan(activityP95, 0.250, "idle activity polling should stay below 250 ms")
    }
}
