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

    private var pending: [RunJob] = []
    private var runningThreadIDs: Set<String> = []
    private var runningCount = 0
    private var runningTasks: [String: (threadID: String?, task: Task<Void, Never>)] = [:]
    private var cancelledRunIDs: Set<String> = []
    private var shutdownRunIDs: Set<String> = []
    private var isShuttingDown = false

    init(
        concurrencyLimit: Int,
        executor: RunExecuting,
        historyStore: RunHistoryStore,
        bus: EventBus,
        logger: DaemonLogger
    ) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        manager = RunManager(executor: executor)
        self.historyStore = historyStore
        self.bus = bus
        self.logger = logger
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

    /// `POST /v1/threads/{id}/abort`. Drops queued jobs and cancels the running task; the real
    /// executor then terminates its Pi process, so nothing for this thread can restart afterward.
    @discardableResult
    func abort(threadId: String) async -> Bool {
        let cancelled = pending.filter { $0.target.existingThreadID == threadId }
        pending.removeAll { $0.target.existingThreadID == threadId }
        let running = runningTasks.first { $0.value.threadID == threadId }
        if let running {
            cancelledRunIDs.insert(running.key)
            running.value.task.cancel()
        }
        for job in cancelled {
            await recordSkipped(job, reason: "Thread was stopped before this run started.")
        }
        return running != nil || !cancelled.isEmpty
    }

    /// Graceful daemon shutdown (docs/daemon-api.md, "Shutdown"): give whatever is currently
    /// running up to `graceSeconds` to finish naturally — a scheduled run seconds from completing
    /// should not be cut off just because the app quit or the daemon received SIGTERM — then
    /// cancel anything still going. That reuses the exact cooperative-cancellation path
    /// `/v1/threads/{id}/abort` already uses, so a lingering `pi` child still gets
    /// `PiRPCSession.stop()`'s SIGTERM-then-SIGKILL treatment and the run is recorded as
    /// `.interrupted` instead of being silently left `running` forever or orphaned when this
    /// process exits. Never starts queued work; its durable occurrence waits for the next launch.
    func shutdown(graceSeconds: TimeInterval) async {
        isShuttingDown = true
        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while runningCount > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stillRunning = runningTasks.map { ($0.key, $0.value.task) }
        shutdownRunIDs.formUnion(stillRunning.map(\.0))
        for (_, task) in stillRunning { task.cancel() }
        for (_, task) in stillRunning { await task.value }
    }

    func enqueue(_ job: RunJob) async {
        guard !isShuttingDown else { return }
        let queued = Run(
            id: job.id, scheduleId: job.scheduleId, threadId: job.target.existingThreadID,
            trigger: job.trigger, startedAt: job.queuedAt, status: .queued,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt
        )
        await historyStore.record(queued)
        bus.publish(.run(queued))
        pending.append(job)
        pump()
    }

    /// Records a run that never entered the queue at all (skipped by policy before it could
    /// collide with anything), so there is still a visible, queryable history entry for it.
    func recordSkipped(_ job: RunJob, reason: String) async {
        let run = Run(
            id: job.id, scheduleId: job.scheduleId, threadId: job.target.existingThreadID,
            trigger: job.trigger, startedAt: job.queuedAt, finishedAt: job.queuedAt,
            status: .skipped, error: reason, summary: nil,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt
        )
        await historyStore.record(run)
        bus.publish(.run(run))
        logger.info("Run \(job.id) skipped: \(reason)")
        await job.onCompletion?(RunOutcome(status: .skipped, error: reason, summary: nil))
    }

    private func pump() {
        guard !isShuttingDown else { return }
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
            trigger: job.trigger, startedAt: Date(), status: .running,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt
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

        var finalOutcome = outcome
        if cancelledRunIDs.remove(job.id) != nil {
            finalOutcome = RunOutcome(
                status: .interrupted, error: "The run was stopped before it finished.",
                summary: outcome.summary, resolvedThreadId: outcome.resolvedThreadId,
                resolvedThreadPath: outcome.resolvedThreadPath,
                promptStartedAt: outcome.promptStartedAt, promptAcceptedAt: outcome.promptAcceptedAt
            )
        } else if shutdownRunIDs.remove(job.id) != nil {
            finalOutcome = RunOutcome(
                status: .interrupted, error: "Pi Desktop closed before the run finished.",
                summary: outcome.summary, resolvedThreadId: outcome.resolvedThreadId,
                resolvedThreadPath: outcome.resolvedThreadPath, retryable: true,
                promptStartedAt: outcome.promptStartedAt, promptAcceptedAt: outcome.promptAcceptedAt
            )
        }

        let finished = Run(
            id: job.id, scheduleId: job.scheduleId,
            threadId: finalOutcome.resolvedThreadId ?? job.target.existingThreadID,
            trigger: job.trigger, startedAt: job.queuedAt, finishedAt: Date(),
            status: finalOutcome.status, error: finalOutcome.error, summary: finalOutcome.summary,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt,
            promptStartedAt: finalOutcome.promptStartedAt,
            promptAcceptedAt: finalOutcome.promptAcceptedAt, retryable: finalOutcome.retryable
        )
        await historyStore.record(finished)
        bus.publish(.run(finished))
        logger.info("Run \(job.id) finished: \(finalOutcome.status.rawValue)\(finalOutcome.error.map { " (\($0))" } ?? "")")

        await job.onCompletion?(finalOutcome)
        pump()
    }
}
