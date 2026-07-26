import Foundation
import PiDeskKit

/// FIFO queue with a concurrency limit and per-thread mutual exclusion: at most `concurrencyLimit`
/// jobs execute at once, and a thread that already has a job running (or already queued) is
/// skipped over when picking the next runnable job, so two prompts can never race the same Pi
/// session \u2014 "never stack" is enforced here, once, for every trigger (manual, API, scheduled).
///
/// Every state transition (queued \u2192 running \u2192 finished) is recorded through `RunHistoryStore`
/// and published on `EventBus`, so `GET /v1/runs` and `GET /v1/events` agree with each other and
/// with `GET /v1/health`'s counts by construction.
actor RunQueue {
    private let concurrencyLimit: Int
    private let manager: RunManager
    private let historyStore: RunHistoryStore
    private let bus: EventBus
    private let logger: DaemonLogger
    /// Notified after every finished (including skipped) run, so the scheduler can update a
    /// schedule's `lastRunAt`/`lastStatus` without `RunQueue` knowing schedules exist.
    private let onCompletion: (@Sendable (RunJob, RunOutcome) async -> Void)?

    private var pending: [RunJob] = []
    private var runningThreadIDs: Set<String> = []
    private var runningCount = 0
    private var runningTasks: [String: (threadID: String?, task: Task<Void, Never>)] = [:]

    init(
        concurrencyLimit: Int,
        executor: RunExecuting,
        historyStore: RunHistoryStore,
        bus: EventBus,
        logger: DaemonLogger,
        onCompletion: (@Sendable (RunJob, RunOutcome) async -> Void)? = nil
    ) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        manager = RunManager(executor: executor)
        self.historyStore = historyStore
        self.bus = bus
        self.logger = logger
        self.onCompletion = onCompletion
    }

    func activeThreadIDs() -> Set<String> { runningThreadIDs }
    func pendingThreadIDs() -> Set<String> { Set(pending.compactMap(\.target.existingThreadID)) }
    func queuedCount() -> Int { pending.count }
    func activeCount() -> Int { runningCount }

    /// True if a job for this thread is already running or already waiting its turn \u2014 the
    /// signal `skipIfRunning`/heartbeat-gated triggers consult before enqueueing another one.
    func isThreadBusy(_ threadID: String) -> Bool {
        runningThreadIDs.contains(threadID) || pending.contains { $0.target.existingThreadID == threadID }
    }

    /// `POST /v1/threads/{id}/abort`. Cancels the running job's task; a cooperative executor
    /// (every real one, and every well-behaved fake) notices within a few seconds and unwinds
    /// — the doc's `Run.status` enum has no distinct "aborted" value, so this still resolves as
    /// `timeout`, the closest of the documented statuses to "cut short before it finished".
    @discardableResult
    func abort(threadId: String) -> Bool {
        guard let entry = runningTasks.first(where: { $0.value.threadID == threadId }) else { return false }
        entry.value.task.cancel()
        return true
    }

    /// Drops every not-yet-started job for this thread from the FIFO queue (used when a caller
    /// wants a clean slate rather than waiting out an already-queued backlog). Does not touch a
    /// job that has already started.
    @discardableResult
    func cancelQueued(threadId: String) -> Int {
        let before = pending.count
        pending.removeAll { $0.target.existingThreadID == threadId }
        return before - pending.count
    }

    /// Graceful daemon shutdown (docs/daemon-api.md, "Shutdown"): give whatever is currently
    /// running up to `graceSeconds` to finish naturally — a scheduled run seconds from completing
    /// should not be cut off just because the app quit or the daemon received SIGTERM — then
    /// cancel anything still going. That reuses the exact cooperative-cancellation path
    /// `/v1/threads/{id}/abort` already uses, so a lingering `pi` child still gets
    /// `PiRPCSession.stop()`'s SIGTERM-then-SIGKILL treatment and the run is recorded as
    /// `.timeout` instead of being silently left `running` forever or orphaned when this process
    /// exits. Never queues anything new; the caller stops the scheduler first.
    func shutdown(graceSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while runningCount > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stillRunning = runningTasks.values.map(\.task)
        for task in stillRunning { task.cancel() }
        for task in stillRunning { await task.value }
    }

    func enqueue(_ job: RunJob) {
        pending.append(job)
        pump()
    }

    /// Records a run that never entered the queue at all (skipped by policy before it could
    /// collide with anything), so there is still a visible, queryable history entry for it.
    func recordSkipped(_ job: RunJob, reason: String) async {
        let run = Run(
            id: job.id, scheduleId: job.scheduleId, threadId: job.target.existingThreadID,
            trigger: job.trigger, startedAt: job.queuedAt, finishedAt: job.queuedAt,
            status: .skipped, error: reason, summary: nil
        )
        await historyStore.record(run)
        bus.publish(.run(run))
        logger.info("Run \(job.id) skipped: \(reason)")
        await onCompletion?(job, RunOutcome(status: .skipped, error: reason, summary: nil))
    }

    private func pump() {
        while runningCount < concurrencyLimit, let index = nextRunnableIndex() {
            let job = pending.remove(at: index)
            start(job)
        }
    }

    private func nextRunnableIndex() -> Int? {
        for (index, job) in pending.enumerated() {
            if let threadID = job.target.existingThreadID, runningThreadIDs.contains(threadID) { continue }
            return index
        }
        return nil
    }

    private func start(_ job: RunJob) {
        runningCount += 1
        if let threadID = job.target.existingThreadID { runningThreadIDs.insert(threadID) }

        let startedRun = Run(
            id: job.id, scheduleId: job.scheduleId, threadId: job.target.existingThreadID,
            trigger: job.trigger, startedAt: Date(), status: .running
        )
        logger.info("Run \(job.id) started (\(job.trigger.rawValue), target=\(job.target.existingThreadID ?? "new thread in \(job.target.cwd)"))")

        let task = Task {
            await historyStore.record(startedRun)
            bus.publish(.run(startedRun))
            let outcome = await manager.run(job)
            await finish(job: job, outcome: outcome)
        }
        runningTasks[job.id] = (job.target.existingThreadID, task)
    }

    private func finish(job: RunJob, outcome: RunOutcome) async {
        runningCount -= 1
        runningTasks.removeValue(forKey: job.id)
        if let threadID = job.target.existingThreadID { runningThreadIDs.remove(threadID) }

        let finished = Run(
            id: job.id, scheduleId: job.scheduleId,
            threadId: outcome.resolvedThreadId ?? job.target.existingThreadID,
            trigger: job.trigger, startedAt: job.queuedAt, finishedAt: Date(),
            status: outcome.status, error: outcome.error, summary: outcome.summary
        )
        await historyStore.record(finished)
        bus.publish(.run(finished))
        logger.info("Run \(job.id) finished: \(outcome.status.rawValue)\(outcome.error.map { " (\($0))" } ?? "")")

        await onCompletion?(job, outcome)
        pump()
    }
}
