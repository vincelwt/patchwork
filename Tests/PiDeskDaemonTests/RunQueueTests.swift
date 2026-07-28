import XCTest
import PiDeskKit
@testable import PiDeskDaemon

final class RunQueueTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeQueue(
        concurrency: Int = 2,
        behavior: @escaping @Sendable (RunJob) async -> RunOutcome = { _ in RunOutcome(status: .ok, error: nil, summary: "ok") }
    ) -> (queue: RunQueue, history: RunHistoryStore, bus: EventBus, executor: FakeRunExecutor) {
        let logger = TestSupport.logger(in: directory)
        let history = RunHistoryStore(fileURL: directory.appendingPathComponent("runs-\(UUID().uuidString).jsonl"), logger: logger)
        let bus = EventBus(logger: logger)
        let executor = FakeRunExecutor(behavior: behavior)
        let queue = RunQueue(concurrencyLimit: concurrency, executor: executor, historyStore: history, bus: bus, logger: logger)
        return (queue, history, bus, executor)
    }

    private func job(id: String = "run_\(UUID().uuidString)", thread: String? = nil, cwd: String = "/tmp") -> RunJob {
        RunJob(
            id: id, scheduleId: nil, trigger: .manual,
            target: thread.map { RunTarget.existingThread(threadId: $0, path: "/tmp/\($0).jsonl", cwd: cwd) } ?? .newThread(cwd: cwd, namePattern: nil),
            prompt: "hello", mode: nil, timeoutSeconds: 5, queuedAt: Date()
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

    // MARK: - Never spawns Pi

    func testFakeExecutorNeverInvokesARealProcess() async {
        let (queue, _, _, executor) = makeQueue()
        await queue.enqueue(job(thread: "t1"))
        let ran = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(ran)
        // The only thing that proves this: FakeRunExecutor is the entire implementation here,
        // and it is a plain Swift type with no `Process` anywhere in it (see TestSupport.swift).
    }

    // MARK: - Concurrency + FIFO

    func testRespectsConcurrencyLimitAndDrainsFIFO() async {
        let gate = Gate()
        let (queue, _, _, executor) = makeQueue(concurrency: 2) { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: nil)
        }

        await queue.enqueue(job(id: "a", thread: "t-a"))
        await queue.enqueue(job(id: "b", thread: "t-b"))
        await queue.enqueue(job(id: "c", thread: "t-c"))

        // Only 2 of the 3 distinct-thread jobs may start immediately (concurrency limit 2).
        let twoStarted = await poll { executor.executedJobs.count == 2 }
        XCTAssertTrue(twoStarted)
        let stillTwo = await poll(timeout: 0.3) { executor.executedJobs.count == 3 }
        XCTAssertFalse(stillTwo, "a third distinct-thread job must not start before a slot frees up")
        let active = await queue.activeCount()
        let queued = await queue.queuedCount()
        XCTAssertEqual(active, 2)
        XCTAssertEqual(queued, 1)

        await gate.release()
        let allThree = await poll { executor.executedJobs.count == 3 }
        XCTAssertTrue(allThree)
    }

    func testNeverStacksTwoRunsOnTheSameThread() async {
        let gate = Gate()
        let (queue, _, _, executor) = makeQueue(concurrency: 5) { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: nil)
        }

        await queue.enqueue(job(id: "first", thread: "same-thread"))
        await queue.enqueue(job(id: "second", thread: "same-thread"))
        await queue.enqueue(job(id: "unrelated", thread: "other-thread"))

        // The concurrency limit (5) is nowhere near binding; only per-thread exclusivity can be
        // the reason "second" does not start alongside "first" and "unrelated".
        let twoStarted = await poll { executor.executedJobs.count == 2 }
        XCTAssertTrue(twoStarted)
        let startedIDs = Set(executor.executedJobs.map(\.id))
        XCTAssertEqual(startedIDs, ["first", "unrelated"])
        let stillBusy = await queue.isThreadBusy("same-thread")
        XCTAssertTrue(stillBusy)

        await gate.release()
        let bothRan = await poll { executor.executedJobs.count == 3 }
        XCTAssertTrue(bothRan)
    }

    // MARK: - Status recording

    func testSuccessfulRunIsRecordedAsRunningThenOk() async {
        let (queue, history, _, _) = makeQueue { _ in RunOutcome(status: .ok, error: nil, summary: "the answer") }
        await queue.enqueue(job(id: "run-1", thread: "t1"))
        let finished = await poll { await history.get(id: "run-1")?.status == .ok }
        XCTAssertTrue(finished)
        let run = await history.get(id: "run-1")
        XCTAssertEqual(run?.summary, "the answer")
        XCTAssertNotNil(run?.finishedAt)
    }

    func testFailedRunIsRecordedWithError() async {
        let (queue, history, _, _) = makeQueue { _ in RunOutcome(status: .failed, error: "boom", summary: nil) }
        await queue.enqueue(job(id: "run-2", thread: "t2"))
        let finished = await poll { await history.get(id: "run-2")?.status == .failed }
        XCTAssertTrue(finished)
        let run = await history.get(id: "run-2")
        XCTAssertEqual(run?.error, "boom")
    }

    func testRecordSkippedNeverInvokesTheExecutor() async {
        let (queue, history, _, executor) = makeQueue()
        await queue.recordSkipped(job(id: "run-3", thread: "t3"), reason: "Thread was already running.")
        let run = await history.get(id: "run-3")
        XCTAssertEqual(run?.status, .skipped)
        XCTAssertEqual(run?.error, "Thread was already running.")
        let executedCount = executor.executedJobs.count
        XCTAssertEqual(executedCount, 0)
    }

    func testEveryTransitionPublishesARunEvent() async {
        let (queue, _, bus, _) = makeQueue { _ in RunOutcome(status: .ok, error: nil, summary: nil) }
        var seenStatuses: [RunStatus] = []
        let collected = expectation(description: "saw queued, running, and finished events")
        collected.expectedFulfillmentCount = 3
        _ = bus.subscribe { name, data in
            guard name == "run", let run = try? PiDeskJSON.decoder.decode(Run.self, from: data) else { return }
            seenStatuses.append(run.status)
            collected.fulfill()
        }
        await queue.enqueue(job(id: "run-4", thread: "t4"))
        await fulfillment(of: [collected], timeout: 2)
        XCTAssertEqual(
            seenStatuses.sorted { $0.rawValue < $1.rawValue },
            [.queued, .running, .ok].sorted { $0.rawValue < $1.rawValue }
        )
    }

    // MARK: - Abort

    func testAbortCancelsARunningJobAndRecordsInterruption() async {
        let (queue, history, _, _) = makeQueue(behavior: FakeRunExecutor.hanging())
        await queue.enqueue(job(id: "run-5", thread: "t5"))
        let started = await poll { await history.get(id: "run-5")?.status == .running }
        XCTAssertTrue(started)

        let aborted = await queue.abort(threadId: "t5")
        XCTAssertTrue(aborted)
        let finished = await poll(timeout: 3) { await history.get(id: "run-5")?.status == .interrupted }
        XCTAssertTrue(finished)
    }

    func testAbortDropsQueuedJobsForTheSameThread() async {
        let (queue, history, _, executor) = makeQueue(behavior: FakeRunExecutor.hanging())
        await queue.enqueue(job(id: "running", thread: "t5"))
        await queue.enqueue(job(id: "queued", thread: "t5"))
        let started = await poll { await history.get(id: "running")?.status == .running }
        XCTAssertTrue(started)

        let aborted = await queue.abort(threadId: "t5")
        XCTAssertTrue(aborted)
        let finished = await poll(timeout: 3) { await history.get(id: "running")?.status == .interrupted }
        XCTAssertTrue(finished)
        let queued = await queue.queuedCount()
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(executor.executedJobs.map(\.id), ["running"])
        let cancelled = await history.get(id: "queued")
        XCTAssertEqual(cancelled?.status, .skipped)
        XCTAssertEqual(cancelled?.error, "Thread was stopped before this run started.")
    }

    func testAbortOfAnUnknownThreadReturnsFalse() async {
        let (queue, _, _, _) = makeQueue()
        let aborted = await queue.abort(threadId: "no-such-thread")
        XCTAssertFalse(aborted)
    }

    // MARK: - Graceful shutdown

    func testShutdownWithNoRunsReturnsImmediately() async {
        let (queue, _, _, _) = makeQueue()
        let start = Date()
        await queue.shutdown(graceSeconds: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "nothing in flight must never wait out the grace period")
    }

    func testShutdownLetsAnInFlightRunFinishWithinTheGracePeriod() async {
        let (queue, history, _, _) = makeQueue { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        await queue.enqueue(job(id: "run-6", thread: "t6"))
        let started = await poll { await history.get(id: "run-6")?.status == .running }
        XCTAssertTrue(started)

        await queue.shutdown(graceSeconds: 2)

        let run = await history.get(id: "run-6")
        XCTAssertEqual(run?.status, .ok, "a run that finishes inside the grace period must not be cut off")
        let active = await queue.activeCount()
        XCTAssertEqual(active, 0)
    }

    func testShutdownRecordsInterruptionPastTheGracePeriod() async {
        let (queue, history, _, _) = makeQueue(behavior: FakeRunExecutor.hanging())
        await queue.enqueue(job(id: "run-7", thread: "t7"))
        let started = await poll { await history.get(id: "run-7")?.status == .running }
        XCTAssertTrue(started)

        let start = Date()
        await queue.shutdown(graceSeconds: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        let run = await history.get(id: "run-7")
        XCTAssertEqual(run?.status, .interrupted, "app shutdown is distinct from an execution timeout")
        XCTAssertLessThan(elapsed, 5, "must not block past the grace period plus a bounded cooperative unwind")
        let active = await queue.activeCount()
        XCTAssertEqual(active, 0, "no run may still read as active once shutdown returns")
    }

    func testShutdownNeverStartsQueuedWork() async {
        let (queue, history, _, executor) = makeQueue(concurrency: 1, behavior: FakeRunExecutor.hanging())
        await queue.enqueue(job(id: "active", thread: "active-thread"))
        await queue.enqueue(job(id: "owed", thread: "owed-thread"))
        let started = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(started)

        await queue.shutdown(graceSeconds: 0.1)

        XCTAssertEqual(executor.executedJobs.map(\.id), ["active"])
        let owed = await history.get(id: "owed")
        XCTAssertEqual(owed?.status, .queued)
    }

    func testShutdownDrainsEveryConcurrentRunNotJustOne() async {
        let (queue, history, _, _) = makeQueue(concurrency: 3, behavior: FakeRunExecutor.hanging())
        await queue.enqueue(job(id: "run-8", thread: "t8"))
        await queue.enqueue(job(id: "run-9", thread: "t9"))
        let bothStarted = await poll { await queue.activeCount() == 2 }
        XCTAssertTrue(bothStarted)

        await queue.shutdown(graceSeconds: 0.2)

        let first = await history.get(id: "run-8")
        let second = await history.get(id: "run-9")
        XCTAssertEqual(first?.status, .interrupted)
        XCTAssertEqual(second?.status, .interrupted)
        let active = await queue.activeCount()
        XCTAssertEqual(active, 0)
    }
}

/// A tiny async gate so tests can hold a fake run "in flight" deterministically instead of
/// racing sleeps.
actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
