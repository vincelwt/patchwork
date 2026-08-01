import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// Sanity coverage for the composition root itself, direct (no HTTP) \u2014 the deeper behavior of
/// each piece it wires together is covered by the other files in this target.
final class DaemonCoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testHealthReflectsSettingsAndStartsWithNoRuns() async {
        let core = TestSupport.makeCore(in: directory, concurrency: 3)
        let health = await core.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.api, PiDeskAPI.apiVersion)
        XCTAssertEqual(health.runningRuns, 0)
        XCTAssertEqual(health.queuedRuns, 0)
        XCTAssertTrue(health.schedulesEnabled)
        XCTAssertTrue(health.scheduleIdempotency)
        XCTAssertTrue(health.threadCreationIdempotency)
        XCTAssertTrue(health.messageSubmissionIdempotency)
        XCTAssertTrue(health.scheduleRunIdempotency)
        XCTAssertTrue(health.issues.isEmpty)
    }

    func testHealthSurfacesQuarantinedScheduleIssues() async {
        let schedulesFile = directory.appendingPathComponent("schedules.json")
        try? "not json".write(to: schedulesFile, atomically: true, encoding: .utf8)
        let core = DaemonCore(
            settings: DaemonSettings(),
            logger: TestSupport.logger(in: directory),
            executor: FakeRunExecutor(),
            sessionRootURL: directory.appendingPathComponent("sessions"),
            activityDirectoryURL: directory.appendingPathComponent("activity"),
            schedulesFileURL: schedulesFile,
            runHistoryFileURL: directory.appendingPathComponent("runs.jsonl")
        )
        let health = await core.health()
        XCTAssertTrue(health.ok, "a quarantined schedule must not make the daemon itself unhealthy")
        XCTAssertEqual(health.issues.first?.code, "schedules_file_corrupt")
    }

    func testStartAndStopAreIdempotentAndDoNotHang() async {
        let core = TestSupport.makeCore(in: directory, schedulerPollInterval: 0.05)
        await core.start()
        await core.start() // must not double-schedule or crash
        await core.stop()
        await core.stop()
    }

    /// The composition-root wiring for graceful shutdown: `stop()` must actually reach
    /// `RunQueue.shutdown` (unit-tested in depth in `RunQueueTests`), not just stop the
    /// scheduler's poll loop.
    func testStopDrainsAnInFlightRunBeforeReturning() async {
        let gate = Gate()
        let executor = FakeRunExecutor { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor, schedulerPollInterval: 0.05)
        await core.start()
        await core.runQueue.enqueue(RunJob(
            id: "run_stop_test", scheduleId: nil, trigger: .manual,
            target: .newThread(cwd: "/tmp", namePattern: nil), prompt: "hi", mode: nil,
            timeoutSeconds: 30, queuedAt: Date()
        ))
        var active = await core.runQueue.activeCount()
        var attempts = 0
        while active == 0, attempts < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            active = await core.runQueue.activeCount()
            attempts += 1
        }
        XCTAssertEqual(active, 1)

        await gate.release()
        await core.stop(graceSeconds: 2)
        let remaining = await core.runQueue.activeCount()
        XCTAssertEqual(remaining, 0, "stop() must wait for the drained run, not just cancel the scheduler")
    }
}
