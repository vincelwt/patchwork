import XCTest
import PiDeskKit
@testable import PiDeskDaemon

final class ResilientSchedulerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func schedule(
        id: String, due: Date, trigger: ScheduleTrigger = .interval(everySeconds: 60, startAt: nil),
        target: ScheduleTarget
    ) -> Schedule {
        Schedule(
            id: id, name: id, target: target, prompt: "work", trigger: trigger,
            policy: SchedulePolicy(catchUpMissed: false),
            createdAt: due.addingTimeInterval(-60), updatedAt: due.addingTimeInterval(-60),
            nextRunAt: due
        )
    }

    private func poll(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testOverdueAutomationsPersistBeforeRunningAndExecuteOldestFirstWithoutDuplicates() async throws {
        let now = Date()
        _ = TestSupport.writeSessionFile(in: directory, id: "old-thread", cwd: directory.path)
        _ = TestSupport.writeSessionFile(in: directory, id: "new-thread", cwd: directory.path)
        let gate = Gate()
        let persistenceObserved = LockedFlag()
        let schedulesURL = directory.appendingPathComponent("schedules.json")
        let executor = FakeRunExecutor { _ in
            if let data = FileManager.default.contents(atPath: schedulesURL.path),
               let schedules = try? PiDeskJSON.decoder.decode([Schedule].self, from: data),
               schedules.count == 2, schedules.allSatisfy({ $0.pendingOccurrence != nil }) {
                persistenceObserved.set()
            }
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor, concurrency: 1)
        try await core.scheduleStore.upsert(schedule(
            id: "newer", due: now.addingTimeInterval(-60),
            target: .existingThread(threadId: "new-thread")
        ))
        try await core.scheduleStore.upsert(schedule(
            id: "older", due: now.addingTimeInterval(-3_600),
            target: .existingThread(threadId: "old-thread")
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 2)
        let firstStarted = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(firstStarted)
        let persistedBeforeExecution = await poll { persistenceObserved.value }
        XCTAssertTrue(persistedBeforeExecution)
        let duplicate = await core.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(duplicate, 0, "one pending occurrence prevents a duplicate")

        await gate.release()
        let bothStarted = await poll { executor.executedJobs.count == 2 }
        XCTAssertTrue(bothStarted)
        XCTAssertEqual(executor.executedJobs.compactMap(\.scheduleId), ["older", "newer"])
        let bothFinished = await poll {
            let schedules = await core.scheduleStore.all()
            return schedules.allSatisfy { $0.pendingOccurrence == nil && ($0.nextRunAt ?? .distantPast) > now }
        }
        XCTAssertTrue(bothFinished)
    }

    func testSameTickSkipPolicyStillAppliesToTwoSchedulesForOneThread() async throws {
        let now = Date()
        _ = TestSupport.writeSessionFile(in: directory, id: "shared-thread", cwd: directory.path)
        let gate = Gate()
        let executor = FakeRunExecutor { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor, concurrency: 1)
        try await core.scheduleStore.upsert(schedule(
            id: "first", due: now.addingTimeInterval(-120),
            target: .existingThread(threadId: "shared-thread")
        ))
        try await core.scheduleStore.upsert(schedule(
            id: "second", due: now.addingTimeInterval(-60),
            target: .existingThread(threadId: "shared-thread")
        ))

        let fired = await core.scheduler.tick(now: now)
        let skipped = await core.scheduleStore.get(id: "second")
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(skipped?.lastStatus, .skipped)
        XCTAssertNil(skipped?.pendingOccurrence)
        let started = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(started)
        await gate.release()
    }

    func testTransientPrePromptFailureRetriesAfterDaemonRecreation() async throws {
        let now = Date()
        let firstExecutor = FakeRunExecutor { _ in
            RunOutcome(status: .failed, error: "temporary pipe failure", summary: nil, retryable: true)
        }
        let first = TestSupport.makeCore(
            in: directory, executor: firstExecutor, schedulerRetryDelays: [60]
        )
        try await first.scheduleStore.upsert(schedule(
            id: "retry", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))
        let firstFired = await first.scheduler.tick(now: now)
        XCTAssertEqual(firstFired, 1)
        let retryPersisted = await poll {
            guard let pending = await first.scheduleStore.get(id: "retry")?.pendingOccurrence else { return false }
            return pending.attemptCount == 1 && pending.runId == nil && pending.notBefore > now
        }
        XCTAssertTrue(retryPersisted)
        let persistedSchedule = await first.scheduleStore.get(id: "retry")
        let retryAt = try XCTUnwrap(persistedSchedule?.pendingOccurrence?.notBefore)

        let secondExecutor = FakeRunExecutor()
        let second = TestSupport.makeCore(
            in: directory, executor: secondExecutor, schedulerRetryDelays: [60]
        )
        let tooEarly = await second.scheduler.tick(now: retryAt.addingTimeInterval(-1))
        XCTAssertEqual(tooEarly, 0, "relaunch preserves the persisted backoff")
        let secondFired = await second.scheduler.tick(now: retryAt.addingTimeInterval(1))
        XCTAssertEqual(secondFired, 1)
        let retried = await poll { secondExecutor.executedJobs.count == 1 }
        XCTAssertTrue(retried)
        let settled = await poll { await second.scheduleStore.get(id: "retry")?.pendingOccurrence == nil }
        XCTAssertTrue(settled)

        let runs = await second.runHistoryStore.query(scheduleId: "retry", threadId: nil, limit: 10)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(Set(runs.map(\.status)), [.failed, .ok])
        XCTAssertEqual(Set(runs.compactMap(\.attempt)), [1, 2])
    }

    func testOfflineLaunchPersistsWorkWithoutDispatchingUntilConnectivityReturns() async throws {
        let now = Date()
        let online = LockedFlag()
        let executor = FakeRunExecutor()
        let core = TestSupport.makeCore(
            in: directory, executor: executor, networkAvailable: { online.value }
        )
        try await core.scheduleStore.upsert(schedule(
            id: "offline", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        let whileOffline = await core.scheduler.tick(now: now)
        let pending = await core.scheduleStore.get(id: "offline")?.pendingOccurrence
        XCTAssertEqual(whileOffline, 0)
        XCTAssertEqual(pending?.attemptCount, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)

        online.set()
        let afterReconnect = await core.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(afterReconnect, 1)
        let ran = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(ran)
    }

    func testPermanentFailureDoesNotRetry() async throws {
        let now = Date()
        let executor = FakeRunExecutor { _ in
            RunOutcome(status: .failed, error: "invalid configuration", summary: nil)
        }
        let core = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        try await core.scheduleStore.upsert(schedule(
            id: "permanent", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        _ = await core.scheduler.tick(now: now)
        let settled = await poll {
            await core.scheduleStore.get(id: "permanent")?.pendingOccurrence == nil
        }
        _ = await core.scheduler.tick(now: now.addingTimeInterval(1))

        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.count, 1)
    }

    func testRetryCountIsBounded() async throws {
        let now = Date()
        let executor = FakeRunExecutor { _ in
            RunOutcome(status: .failed, error: "still offline", summary: nil, retryable: true)
        }
        let core = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        try await core.scheduleStore.upsert(schedule(
            id: "bounded", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        _ = await core.scheduler.tick(now: now)
        let firstFinished = await poll {
            await core.scheduleStore.get(id: "bounded")?.pendingOccurrence?.runId == nil
        }
        XCTAssertTrue(firstFinished)
        _ = await core.scheduler.tick(now: Date().addingTimeInterval(1))
        let exhausted = await poll {
            await core.scheduleStore.get(id: "bounded")?.pendingOccurrence == nil
        }
        XCTAssertTrue(exhausted)

        XCTAssertEqual(executor.executedJobs.count, 2)
        let finalSchedule = await core.scheduleStore.get(id: "bounded")
        XCTAssertEqual(finalSchedule?.lastStatus, .failed)
    }

    func testUnknownOccurrencePhaseIsPreservedAndNeverGuessed() async throws {
        let now = Date()
        let executor = FakeRunExecutor()
        let core = TestSupport.makeCore(in: directory, executor: executor)
        var saved = schedule(
            id: "future", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = ScheduleOccurrence(
            id: "occ-future", scheduledAt: now.addingTimeInterval(-60),
            phase: .other("future-phase"), notBefore: now
        )
        try await core.scheduleStore.upsert(saved)

        let fired = await core.scheduler.tick(now: now)
        let persisted = await core.scheduleStore.get(id: "future")?.pendingOccurrence
        XCTAssertEqual(fired, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        XCTAssertEqual(persisted?.phase.rawValue, "future-phase")
    }

    func testQueuedWorkFromPreviousDaemonRetriesWithoutSpendingAnAttempt() async throws {
        let now = Date()
        let occurrence = ScheduleOccurrence(
            id: "occ-queued", scheduledAt: now.addingTimeInterval(-60),
            attemptCount: 1, notBefore: now, runId: "run-queued"
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "queued", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = occurrence
        saved.lastRunAt = occurrence.scheduledAt
        saved.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(saved)
        await writer.runHistoryStore.record(Run(
            id: "run-queued", scheduleId: "queued", trigger: .schedule,
            startedAt: now, status: .queued, occurrenceId: occurrence.id,
            scheduledAt: occurrence.scheduledAt, attempt: 1
        ))

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        await recovered.start()
        let ran = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(ran)
        await recovered.stop()

        XCTAssertEqual(executor.executedJobs.first?.attempt, 1)
    }

    func testAcceptedRunFromPreviousDaemonIsInterruptedAndNeverResent() async throws {
        let now = Date()
        let occurrence = ScheduleOccurrence(
            id: "occ-accepted", scheduledAt: now.addingTimeInterval(-60),
            phase: .accepted, attemptCount: 1, notBefore: now,
            runId: "run-accepted"
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "accepted", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = occurrence
        saved.lastRunAt = occurrence.scheduledAt
        saved.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(saved)
        await writer.runHistoryStore.record(Run(
            id: "run-accepted", scheduleId: "accepted", trigger: .schedule,
            startedAt: now.addingTimeInterval(-30), status: .running,
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt, attempt: 1,
            promptStartedAt: now.addingTimeInterval(-20), promptAcceptedAt: now.addingTimeInterval(-19)
        ))

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        await recovered.start()
        let recoveredOccurrence = await poll { await recovered.scheduleStore.get(id: "accepted")?.pendingOccurrence == nil }
        XCTAssertTrue(recoveredOccurrence)
        await recovered.stop()

        XCTAssertTrue(executor.executedJobs.isEmpty)
        let recoveredSchedule = await recovered.scheduleStore.get(id: "accepted")
        let recoveredRun = await recovered.runHistoryStore.get(id: "run-accepted")
        XCTAssertEqual(recoveredSchedule?.lastStatus, .interrupted)
        XCTAssertEqual(recoveredRun?.status, .interrupted)
    }

    func testHeartbeatPendingAtRelaunchIsDiscardedInsteadOfReplayed() async throws {
        let now = Date()
        let writer = TestSupport.makeCore(in: directory)
        let saved = schedule(
            id: "heartbeat", due: now.addingTimeInterval(-3_600),
            trigger: .heartbeat(everySeconds: 900),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        try await writer.scheduleStore.upsert(saved)

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        await recovered.start()
        let resynced = await poll {
            (await recovered.scheduleStore.get(id: "heartbeat")?.nextRunAt ?? .distantPast) > now
        }
        XCTAssertTrue(resynced)
        await recovered.stop()

        XCTAssertTrue(executor.executedJobs.isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}
