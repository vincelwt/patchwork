import XCTest
import PatchworkKit
@testable import PatchworkDaemon

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
        maxPromptBytes: Int = RunQueue.defaultMaxPromptBytes,
        maxPendingJobs: Int = RunQueue.defaultMaxPendingJobs,
        maxPendingBytes: Int = RunQueue.defaultMaxPendingBytes,
        leaseStore: LeaseStore = LeaseStore(),
        behavior: @escaping @Sendable (RunJob) async -> RunOutcome = { _ in RunOutcome(status: .ok, error: nil, summary: "ok") }
    ) -> (queue: RunQueue, history: RunHistoryStore, bus: EventBus, executor: FakeRunExecutor) {
        let logger = TestSupport.logger(in: directory)
        let history = RunHistoryStore(fileURL: directory.appendingPathComponent("runs-\(UUID().uuidString).jsonl"), logger: logger)
        let bus = EventBus(logger: logger)
        let executor = FakeRunExecutor(behavior: behavior)
        let queue = RunQueue(
            concurrencyLimit: concurrency, executor: executor, historyStore: history,
            bus: bus, logger: logger, leaseStore: leaseStore, maxPromptBytes: maxPromptBytes,
            maxPendingJobs: maxPendingJobs, maxPendingBytes: maxPendingBytes
        )
        return (queue, history, bus, executor)
    }

    private func key(_ name: String) -> ThreadInstanceKey {
        ThreadInstanceKey(path: "/tmp/\(name).jsonl")
    }

    private func job(
        id: String = "run_\(UUID().uuidString)", thread: String? = nil,
        path: String? = nil, cwd: String = "/tmp", prompt: String = "hello"
    ) -> RunJob {
        RunJob(
            id: id, scheduleId: nil, trigger: .manual,
            target: thread.map {
                RunTarget.existingThread(
                    threadId: $0, path: path ?? "/tmp/\($0).jsonl", cwd: cwd
                )
            } ?? .newThread(cwd: cwd, namePattern: nil),
            prompt: prompt, mode: nil, timeoutSeconds: 5, queuedAt: Date()
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

    func testExecutionStartBarrierCompletesBeforeExecutorAndProjectsPreallocatedIdentity() async {
        let capture = StartBarrierCapture()
        let (queue, history, _, executor) = makeQueue { _ in
            let ready = await capture.value
            return ready
                ? RunOutcome(status: .ok, error: nil, summary: nil)
                : RunOutcome.failed("executor crossed the start barrier early")
        }
        var fresh = job(id: "start-barrier")
        fresh.initialSessionID = "preallocated-session"
        fresh.onExecutionStart = {
            await capture.mark()
            return .ready
        }

        await queue.enqueue(fresh)

        let finished = await poll { await history.get(id: fresh.id)?.status == .ok }
        XCTAssertTrue(finished)
        XCTAssertEqual(executor.executedJobs.count, 1)
        let run = await history.get(id: fresh.id)
        XCTAssertEqual(run?.threadId, "preallocated-session")
    }

    func testRejectedExecutionStartNeverInvokesExecutor() async {
        let (queue, history, _, executor) = makeQueue()
        var retry = job(id: "start-retry")
        retry.onExecutionStart = { .retry }
        var cancelled = job(id: "start-cancelled")
        cancelled.onExecutionStart = { .cancelled }

        await queue.enqueue(retry)
        await queue.enqueue(cancelled)

        let settled = await poll {
            let retryStatus = await history.get(id: retry.id)?.status
            let cancelledStatus = await history.get(id: cancelled.id)?.status
            return retryStatus == .failed && cancelledStatus == .interrupted
        }
        XCTAssertTrue(settled)
        XCTAssertTrue(executor.executedJobs.isEmpty)
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
        let stillBusy = await queue.isThreadBusy(key("same-thread"))
        XCTAssertTrue(stillBusy)

        await gate.release()
        let bothRan = await poll { executor.executedJobs.count == 3 }
        XCTAssertTrue(bothRan)
    }

    func testResolvedNewThreadPathSerializesTheNextMessage() async {
        let gate = Gate()
        let decisions = IdentityDecisionCapture()
        let resolvedPath = "/tmp/resolved-new-thread.jsonl"
        let (queue, history, bus, executor) = makeQueue(concurrency: 2) { job in
            if job.id == "fresh" {
                let accepted = await job.onThreadIdentityResolved?("resolved", resolvedPath) ?? false
                await decisions.record(accepted)
                await gate.waitForRelease()
            }
            return RunOutcome(status: .ok, error: nil, summary: nil)
        }
        let events = LockedRunEvents()
        _ = bus.subscribe { name, data in
            guard name == "run",
                  let run = try? PatchworkJSON.decoder.decode(Run.self, from: data) else { return }
            events.append(run)
        }

        await queue.enqueue(job(id: "fresh"))
        let promoted = await poll {
            await queue.isThreadBusy(ThreadInstanceKey(path: resolvedPath))
        }
        XCTAssertTrue(promoted)
        let identityPersisted = await poll {
            guard let run = await history.get(id: "fresh") else { return false }
            return run.status == .running
                && run.threadId == "resolved"
                && run.threadPath == resolvedPath
        }
        XCTAssertTrue(identityPersisted)
        let identityPublished = await poll {
            events.values.contains {
                $0.id == "fresh" && $0.status == .running
                    && $0.threadId == "resolved" && $0.threadPath == resolvedPath
            }
        }
        XCTAssertTrue(identityPublished)
        let queued = await queue.enqueue(
            job(id: "follow-up", thread: "resolved", path: resolvedPath)
        )
        XCTAssertEqual(queued, .queued)
        let startedWhileOwned = await poll(timeout: 0.2) { executor.executedJobs.count > 1 }
        XCTAssertFalse(startedWhileOwned)
        let promotionDecision = await decisions.last()
        XCTAssertEqual(promotionDecision, true)

        await gate.release()
        let followUpStarted = await poll { executor.executedJobs.count == 2 }
        XCTAssertTrue(followUpStarted)
        let terminalKeptIdentity = await poll {
            guard let run = await history.get(id: "fresh") else { return false }
            return run.status == .ok && run.threadId == "resolved"
                && run.threadPath == resolvedPath
        }
        XCTAssertTrue(terminalKeptIdentity)
    }

    func testAbortByResolvedPathStopsAFreshRun() async {
        let resolvedPath = "/tmp/abort-resolved-new-thread.jsonl"
        let (queue, history, _, _) = makeQueue { job in
            guard await job.onThreadIdentityResolved?("resolved-abort", resolvedPath) == true else {
                return RunOutcome.failed("identity rejected", retryable: true)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return RunOutcome(status: .interrupted, error: "cancelled", summary: nil)
        }

        await queue.enqueue(job(id: "fresh-abort"))
        let promoted = await poll {
            await queue.isThreadBusy(ThreadInstanceKey(path: resolvedPath))
        }
        XCTAssertTrue(promoted)
        let aborted = await queue.abort(thread: ThreadInstanceKey(path: resolvedPath))
        XCTAssertTrue(aborted)
        let interrupted = await poll {
            await history.get(id: "fresh-abort")?.status == .interrupted
        }
        XCTAssertTrue(interrupted)
    }

    func testResolvedIdentityCannotClaimAPathOwnedByAnotherRuntime() async {
        let gate = Gate()
        let decisions = IdentityDecisionCapture()
        let resolvedPath = "/tmp/already-owned.jsonl"
        let (queue, history, _, _) = makeQueue(concurrency: 2) { job in
            if job.id == "owner" {
                await gate.waitForRelease()
                return RunOutcome(status: .ok, error: nil, summary: nil)
            }
            let accepted = await job.onThreadIdentityResolved?("collision", resolvedPath) ?? false
            await decisions.record(accepted)
            return accepted
                ? RunOutcome(status: .ok, error: nil, summary: nil)
                : RunOutcome.failed("identity rejected", retryable: true)
        }

        await queue.enqueue(job(id: "owner", thread: "owner", path: resolvedPath))
        let ownerStarted = await poll {
            await queue.isThreadBusy(ThreadInstanceKey(path: resolvedPath))
        }
        XCTAssertTrue(ownerStarted)
        await queue.enqueue(job(id: "colliding-fresh"))
        let rejected = await poll { await decisions.last() != nil }
        XCTAssertTrue(rejected)
        let collisionDecision = await decisions.last()
        XCTAssertEqual(collisionDecision, false)
        let collisionFinished = await poll {
            await history.get(id: "colliding-fresh")?.status == .failed
        }
        XCTAssertTrue(collisionFinished)
        let ownerStillBusy = await queue.isThreadBusy(ThreadInstanceKey(path: resolvedPath))
        XCTAssertTrue(ownerStillBusy)
        await gate.release()
    }

    func testFreshIdentityPromotionRejectsAPathWithAnActiveLease() async {
        let leases = LeaseStore()
        let resolvedPath = "/tmp/leased-during-fresh-start.jsonl"
        let resolvedKey = ThreadInstanceKey(path: resolvedPath)
        _ = await leases.acquireIfAvailable(
            thread: resolvedKey, owner: "native-window", ttlSeconds: 60
        )
        let decisions = IdentityDecisionCapture()
        let (queue, history, _, executor) = makeQueue(leaseStore: leases) { job in
            let accepted = await job.onThreadIdentityResolved?("fresh-id", resolvedPath) ?? false
            await decisions.record(accepted)
            return accepted
                ? RunOutcome(status: .ok, error: nil, summary: nil)
                : RunOutcome.failed("identity rejected", retryable: true)
        }

        await queue.enqueue(job(id: "fresh-lease-collision"))

        let decided = await poll { await decisions.last() != nil }
        XCTAssertTrue(decided)
        let decision = await decisions.last()
        XCTAssertEqual(decision, false)
        let finished = await poll {
            await history.get(id: "fresh-lease-collision")?.status == .failed
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(executor.executedJobs.count, 1)
        let active = await queue.activeThreadKeys()
        XCTAssertFalse(active.contains(resolvedKey))
        let lease = await leases.current(thread: resolvedKey)
        XCTAssertEqual(lease?.owner, "native-window")
    }

    func testConcurrentSameThreadAdmissionReportsExactlyOneQueued() async {
        let (queue, _, _, _) = makeQueue(concurrency: 2, behavior: FakeRunExecutor.hanging())

        async let first = queue.enqueue(job(id: "first-admission", thread: "same"))
        async let second = queue.enqueue(job(id: "second-admission", thread: "same"))
        let admissions = await [first, second]

        XCTAssertEqual(admissions.filter { $0 == .started }.count, 1)
        XCTAssertEqual(admissions.filter { $0 == .queued }.count, 1)
        _ = await queue.abort(thread: key("same"))
    }

    func testExistingThreadAdmissionFailsBeforeHistoryOrExecutionWhileLeased() async {
        let leases = LeaseStore()
        _ = await leases.acquireIfAvailable(
            thread: key("leased"), owner: "native", ttlSeconds: 60
        )
        let (queue, history, _, executor) = makeQueue(leaseStore: leases)

        let admission = await queue.enqueue(job(id: "blocked", thread: "leased"))

        guard case let .rejected(code, _) = admission else {
            return XCTFail("a leased transcript must not enter the queue")
        }
        XCTAssertEqual(code, "thread_leased")
        let recorded = await history.get(id: "blocked")
        XCTAssertNil(recorded)
        XCTAssertTrue(executor.executedJobs.isEmpty)
    }

    func testQueuedHistoryFailureRejectsBeforeExecution() async throws {
        let logger = TestSupport.logger(in: directory)
        let historyFile = directory.appendingPathComponent("immutable-runs.jsonl")
        try Data().write(to: historyFile)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: historyFile.path
            )
        }
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: historyFile.path
        )
        let history = RunHistoryStore(fileURL: historyFile, logger: logger)
        let executor = FakeRunExecutor()
        let queue = RunQueue(
            concurrencyLimit: 1, executor: executor, historyStore: history,
            bus: EventBus(logger: logger), logger: logger
        )

        let admission = await queue.enqueue(job(id: "history-blocked", thread: "history"))

        guard case let .rejected(code, _) = admission else {
            return XCTFail("an unrecordable run must not enter the executor")
        }
        XCTAssertEqual(code, "run_history_unavailable")
        XCTAssertTrue(executor.executedJobs.isEmpty)
        let ghost = await history.get(id: "history-blocked")
        XCTAssertNil(ghost)
        let activeCount = await queue.activeCount()
        let queuedCount = await queue.queuedCount()
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(queuedCount, 0)
    }

    func testAdmissionBoundsPendingCountAndBytesWithoutEvictingOlderPrompts() async {
        let gate = Gate()
        let (queue, _, _, executor) = makeQueue(
            concurrency: 1, maxPromptBytes: 8, maxPendingJobs: 2, maxPendingBytes: 8
        ) { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: nil)
        }

        let runningAdmission = await queue.enqueue(job(id: "running", thread: "one", prompt: "12345678"))
        let olderAdmission = await queue.enqueue(job(id: "older", thread: "two", prompt: "1234"))
        let newerAdmission = await queue.enqueue(job(id: "newer", thread: "three", prompt: "5678"))
        XCTAssertEqual(runningAdmission, .started)
        XCTAssertEqual(olderAdmission, .queued)
        XCTAssertEqual(newerAdmission, .queued)
        let rejected = await queue.enqueue(job(id: "rejected", thread: "four", prompt: "x"))
        guard case let .rejected(code, _) = rejected else {
            return XCTFail("the newest prompt should be refused once the pending budget is full")
        }
        XCTAssertEqual(code, "run_queue_full")

        await gate.release()
        let acceptedRan = await poll { executor.executedJobs.count == 3 }
        XCTAssertTrue(acceptedRan)
        XCTAssertEqual(executor.executedJobs.map(\.id), ["running", "older", "newer"])
    }

    func testAdmissionRejectsAnOversizedPromptBeforeRecordingOrRunningIt() async {
        let (queue, history, _, executor) = makeQueue(maxPromptBytes: 4)
        let admission = await queue.enqueue(job(id: "large", thread: "large", prompt: "12345"))

        guard case let .rejected(code, _) = admission else {
            return XCTFail("an oversized prompt should be rejected")
        }
        XCTAssertEqual(code, "prompt_too_large")
        let recorded = await history.get(id: "large")
        XCTAssertNil(recorded)
        XCTAssertTrue(executor.executedJobs.isEmpty)
    }

    func testRuntimeReservationMakesAPromptWaitForTheIdleAttachment() async {
        let (queue, _, _, executor) = makeQueue()
        let reserved = await queue.reserveRuntime(thread: key("t1"))
        XCTAssertTrue(reserved)

        await queue.enqueue(job(id: "waiting", thread: "t1"))
        let startedWhileReserved = await poll(timeout: 0.2) { !executor.executedJobs.isEmpty }
        XCTAssertFalse(startedWhileReserved)

        await queue.releaseRuntime(thread: key("t1"))
        let startedAfterRelease = await poll { executor.executedJobs.map(\.id) == ["waiting"] }
        XCTAssertTrue(startedAfterRelease)
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
            guard name == "run", let run = try? PatchworkJSON.decoder.decode(Run.self, from: data) else { return }
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

        let aborted = await queue.abort(thread: key("t5"))
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

        let aborted = await queue.abort(thread: key("t5"))
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
        let aborted = await queue.abort(thread: key("no-such-thread"))
        XCTAssertFalse(aborted)
    }

    func testCopiedHistoriesWithTheSameSessionIDCanRunConcurrently() async {
        let gate = Gate()
        let (queue, _, _, executor) = makeQueue(concurrency: 2) { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: nil)
        }

        await queue.enqueue(job(id: "copy-a", thread: "copied", path: "/tmp/copy-a.jsonl"))
        await queue.enqueue(job(id: "copy-b", thread: "copied", path: "/tmp/copy-b.jsonl"))

        let bothStarted = await poll { executor.executedJobs.count == 2 }
        XCTAssertTrue(bothStarted, "physical transcripts must not block each other by shared session id")
        await gate.release()
    }

    func testAbortOnlyStopsTheRequestedCopiedHistoryPath() async {
        let (queue, history, _, _) = makeQueue(concurrency: 2, behavior: FakeRunExecutor.hanging())
        let firstPath = "/tmp/abort-copy-a.jsonl"
        let secondPath = "/tmp/abort-copy-b.jsonl"
        await queue.enqueue(job(id: "copy-a", thread: "copied", path: firstPath))
        await queue.enqueue(job(id: "copy-b", thread: "copied", path: secondPath))
        let bothStarted = await poll { await queue.activeCount() == 2 }
        XCTAssertTrue(bothStarted)

        let aborted = await queue.abort(thread: ThreadInstanceKey(path: firstPath))
        XCTAssertTrue(aborted)
        let firstFinished = await poll { await history.get(id: "copy-a")?.status == .interrupted }
        XCTAssertTrue(firstFinished)
        let secondStatus = await history.get(id: "copy-b")?.status
        let activeKeys = await queue.activeThreadKeys()
        XCTAssertEqual(secondStatus, .running)
        XCTAssertEqual(activeKeys, Set([ThreadInstanceKey(path: secondPath)]))

        _ = await queue.abort(thread: ThreadInstanceKey(path: secondPath))
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
        XCTAssertEqual(owed?.status, .interrupted)
        XCTAssertNotNil(owed?.finishedAt)
        XCTAssertEqual(owed?.retryable, false)
        let queuedCount = await queue.queuedCount()
        XCTAssertEqual(queuedCount, 0)
    }

    func testShutdownCompletesEveryQueuedJobExactlyOnceAndRetriesOnlyScheduledWork() async {
        let (queue, history, _, _) = makeQueue(
            concurrency: 1, behavior: FakeRunExecutor.hanging()
        )
        await queue.enqueue(job(id: "active", thread: "active"))
        let completions = CompletionCapture()
        let manual = RunJob(
            id: "manual", scheduleId: nil, trigger: .manual,
            target: .existingThread(threadId: "manual", path: "/tmp/manual.jsonl", cwd: "/tmp"),
            prompt: "manual", mode: nil, timeoutSeconds: 5, queuedAt: Date(),
            onCompletion: { outcome in await completions.record("manual", outcome: outcome) }
        )
        let scheduled = RunJob(
            id: "scheduled", scheduleId: "schedule-1", trigger: .schedule,
            target: .existingThread(threadId: "scheduled", path: "/tmp/scheduled.jsonl", cwd: "/tmp"),
            prompt: "scheduled", mode: nil, timeoutSeconds: 5, queuedAt: Date(),
            onCompletion: { outcome in await completions.record("scheduled", outcome: outcome) }
        )
        await queue.enqueue(manual)
        await queue.enqueue(scheduled)

        await queue.shutdown(graceSeconds: 0)

        let manualCount = await completions.count(for: "manual")
        let scheduledCount = await completions.count(for: "scheduled")
        let manualOutcome = await completions.outcome(for: "manual")
        let scheduledOutcome = await completions.outcome(for: "scheduled")
        let manualRun = await history.get(id: "manual")
        let scheduledRun = await history.get(id: "scheduled")
        XCTAssertEqual(manualCount, 1)
        XCTAssertEqual(scheduledCount, 1)
        XCTAssertEqual(manualOutcome?.retryable, false)
        XCTAssertEqual(scheduledOutcome?.retryable, true)
        XCTAssertEqual(manualRun?.status, .interrupted)
        XCTAssertEqual(scheduledRun?.status, .interrupted)
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

actor CompletionCapture {
    private var outcomes: [String: [RunOutcome]] = [:]

    func record(_ id: String, outcome: RunOutcome) {
        outcomes[id, default: []].append(outcome)
    }

    func count(for id: String) -> Int { outcomes[id]?.count ?? 0 }
    func outcome(for id: String) -> RunOutcome? { outcomes[id]?.last }
}

actor IdentityDecisionCapture {
    private var values: [Bool] = []

    func record(_ value: Bool) { values.append(value) }
    func last() -> Bool? { values.last }
}

actor StartBarrierCapture {
    private(set) var value = false
    func mark() { value = true }
}

private final class LockedRunEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Run] = []

    var values: [Run] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ run: Run) {
        lock.lock()
        stored.append(run)
        lock.unlock()
    }
}
