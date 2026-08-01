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
    enum Admission: Equatable, Sendable {
        case started
        case queued
        case rejected(code: String, message: String)
    }

    struct Reservation: Hashable, Sendable {
        fileprivate let id: UUID
    }

    enum ReservationAdmission: Sendable {
        case reserved(Reservation)
        case rejected(code: String, message: String)
    }

    static let defaultMaxPromptBytes = 1 * 1_024 * 1_024
    static let defaultMaxPendingJobs = 256
    static let defaultMaxPendingBytes = 16 * 1_024 * 1_024

    private let concurrencyLimit: Int
    private let maxPromptBytes: Int
    private let maxPendingJobs: Int
    private let maxPendingBytes: Int
    private let manager: RunManager
    private let historyStore: RunHistoryStore
    private let bus: EventBus
    private let logger: DaemonLogger
    private let leaseStore: LeaseStore

    private var pending: [RunJob] = []
    private var pendingBytes = 0
    private var reservations: [UUID: Int] = [:]
    /// A job is visible to admission and abort immediately, but cannot start until its queued
    /// history entry is durable. This keeps concurrent admission atomic across the actor hop.
    private var awaitingQueuedRecord: Set<String> = []
    /// Physical transcript identities, never public session ids. A copied history keeps the same
    /// session id, but must remain independently runnable and stoppable.
    private var runningThreadKeys: Set<ThreadInstanceKey> = []
    /// Idle sessions temporarily attached for model/thinking RPCs. Queued prompts wait until the
    /// setter has stopped that process, so two Pi runtimes never write one session concurrently.
    private var reservedThreadKeys: Set<ThreadInstanceKey> = []
    private var runningCount = 0
    private var runningTasks: [String: (threadKey: ThreadInstanceKey?, task: Task<Void, Never>)] = [:]
    private var cancelledRunIDs: Set<String> = []
    private var shutdownRunIDs: Set<String> = []
    private var isShuttingDown = false

    init(
        concurrencyLimit: Int,
        executor: RunExecuting,
        historyStore: RunHistoryStore,
        bus: EventBus,
        logger: DaemonLogger,
        leaseStore: LeaseStore = LeaseStore(),
        maxPromptBytes: Int = RunQueue.defaultMaxPromptBytes,
        maxPendingJobs: Int = RunQueue.defaultMaxPendingJobs,
        maxPendingBytes: Int = RunQueue.defaultMaxPendingBytes
    ) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.maxPromptBytes = max(1, maxPromptBytes)
        self.maxPendingJobs = max(1, maxPendingJobs)
        self.maxPendingBytes = max(1, maxPendingBytes)
        manager = RunManager(executor: executor)
        self.historyStore = historyStore
        self.bus = bus
        self.logger = logger
        self.leaseStore = leaseStore
    }

    func activeThreadKeys() -> Set<ThreadInstanceKey> { runningThreadKeys }
    func pendingThreadKeys() -> Set<ThreadInstanceKey> { Set(pending.compactMap(\.target.threadInstanceKey)) }
    func queuedCount() -> Int { pending.count }
    func activeCount() -> Int { runningCount }

    /// Payload limits apply before either queue admission or direct live delivery. Keeping this
    /// check on the configured queue prevents a steer from accepting text that the idle path
    /// would reject.
    func validatePayload(prompt: String, mode: String?) -> Admission? {
        guard let rejection = payloadRejection(prompt: prompt, mode: mode) else { return nil }
        return .rejected(code: rejection.code, message: rejection.message)
    }

    func reserve(prompt: String, mode: String?) -> ReservationAdmission {
        guard !isShuttingDown else {
            return .rejected(code: "daemon_shutting_down", message: "The daemon is shutting down.")
        }
        if let rejection = payloadRejection(prompt: prompt, mode: mode) {
            return .rejected(code: rejection.code, message: rejection.message)
        }
        let bytes = Self.retainedBytes(prompt: prompt, mode: mode)
        let reservedBytes = reservations.values.reduce(0, +)
        guard pending.count + reservations.count < maxPendingJobs,
              pendingBytes + reservedBytes <= maxPendingBytes - bytes else {
            return .rejected(
                code: "run_queue_full",
                message: "Too many prompts are waiting. Try again after another run finishes."
            )
        }
        let reservation = Reservation(id: UUID())
        reservations[reservation.id] = bytes
        return .reserved(reservation)
    }

    func cancelReservation(_ reservation: Reservation) {
        reservations.removeValue(forKey: reservation.id)
    }

    /// True if a job for this thread is already running or already waiting its turn \u2014 the
    /// signal `skipIfRunning`/heartbeat-gated triggers consult before enqueueing another one.
    func isThreadBusy(_ thread: ThreadInstanceKey) -> Bool {
        runningThreadKeys.contains(thread) || reservedThreadKeys.contains(thread)
            || pending.contains { $0.target.threadInstanceKey == thread }
    }

    func reserveRuntime(thread: ThreadInstanceKey) -> Bool {
        guard !isThreadBusy(thread) else { return false }
        reservedThreadKeys.insert(thread)
        return true
    }

    func releaseRuntime(thread: ThreadInstanceKey) {
        reservedThreadKeys.remove(thread)
        pump()
    }

    /// `POST /v1/threads/{id}/abort`. Drops queued jobs and cancels the running task; the real
    /// executor then terminates its Pi process, so nothing for this thread can restart afterward.
    @discardableResult
    func abort(thread: ThreadInstanceKey) async -> Bool {
        let cancelled = pending.filter { $0.target.threadInstanceKey == thread }
        pending.removeAll { $0.target.threadInstanceKey == thread }
        pendingBytes = max(0, pendingBytes - cancelled.reduce(0) { $0 + Self.retainedBytes($1) })
        awaitingQueuedRecord.subtract(cancelled.map(\.id))
        let running = runningTasks.first { $0.value.threadKey == thread }
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
        reservations.removeAll()
        let neverStarted = pending
        pending.removeAll()
        pendingBytes = 0
        awaitingQueuedRecord.subtract(neverStarted.map(\.id))
        for job in neverStarted {
            let error = "Pi Desktop closed before this queued run started."
            let outcome = RunOutcome(
                status: .interrupted, error: error, summary: nil,
                retryable: job.trigger == .schedule
            )
            let run = Run(
                id: job.id, scheduleId: job.scheduleId,
                threadId: job.target.existingThreadID ?? job.initialSessionID,
                threadPath: job.target.existingThreadPath, trigger: job.trigger,
                startedAt: job.queuedAt, finishedAt: Date(), status: .interrupted,
                error: error, summary: nil, occurrenceId: job.occurrenceId,
                scheduledAt: job.scheduledAt, attempt: job.attempt,
                retryable: outcome.retryable, agent: job.target.agent
            )
            let terminalPersisted = await historyStore.record(run)
            bus.publish(.run(run))
            var completionOutcome = outcome
            completionOutcome.terminalRecordPersisted = terminalPersisted
            await job.onCompletion?(completionOutcome)
        }
        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while runningCount > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stillRunning = runningTasks.map { ($0.key, $0.value.task) }
        shutdownRunIDs.formUnion(stillRunning.map(\.0))
        for (_, task) in stillRunning { task.cancel() }
        for (_, task) in stillRunning { await task.value }
    }

    @discardableResult
    func enqueue(_ job: RunJob, reservation: Reservation? = nil) async -> Admission {
        let reserved = reservation.flatMap { reservations.removeValue(forKey: $0.id) }
        let admissionToken: LeaseStore.RunAdmissionToken?
        if let thread = job.target.threadInstanceKey {
            guard let token = await leaseStore.beginRunAdmission(thread: thread) else {
                return .rejected(
                    code: "thread_leased",
                    message: "Another runtime is currently attached to this thread."
                )
            }
            admissionToken = token
        } else {
            admissionToken = nil
        }

        let admission = await enqueueAdmitted(job, reserved: reserved)
        if let admissionToken {
            await leaseStore.endRunAdmission(admissionToken)
        }
        return admission
    }

    private func enqueueAdmitted(_ job: RunJob, reserved: Int?) async -> Admission {
        guard !isShuttingDown else {
            return .rejected(code: "daemon_shutting_down", message: "The daemon is shutting down.")
        }
        if let rejection = payloadRejection(prompt: job.prompt, mode: job.mode) {
            return .rejected(code: rejection.code, message: rejection.message)
        }
        let retainedBytes = Self.retainedBytes(job)
        let reservedBytes = reservations.values.reduce(0, +)
        let reservationMatches = reserved == retainedBytes
        guard reservationMatches || (
            pending.count + reservations.count < maxPendingJobs
                && pendingBytes + reservedBytes <= maxPendingBytes - retainedBytes
        ) else {
            return .rejected(
                code: "run_queue_full",
                message: "Too many prompts are waiting. Try again after another run finishes."
            )
        }
        let queued = Run(
            id: job.id, scheduleId: job.scheduleId,
            threadId: job.target.existingThreadID ?? job.initialSessionID,
            threadPath: job.target.existingThreadPath,
            trigger: job.trigger, startedAt: job.queuedAt, status: .queued,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt,
            agent: job.target.agent
        )
        pending.append(job)
        pendingBytes += retainedBytes
        awaitingQueuedRecord.insert(job.id)
        let queuedPersisted = await historyStore.record(queued)

        guard queuedPersisted else {
            if let index = pending.firstIndex(where: { $0.id == job.id }) {
                pendingBytes = max(0, pendingBytes - Self.retainedBytes(pending.remove(at: index)))
            }
            awaitingQueuedRecord.remove(job.id)
            await historyStore.discardIfUnpersisted(id: job.id)
            return .rejected(
                code: "run_history_unavailable",
                message: "Run history is temporarily unavailable. The prompt was not started."
            )
        }

        // Abort or shutdown can run while the history actor is recording. Do not publish a stale
        // queued event or revive a job that was removed during that hop.
        guard pending.contains(where: { $0.id == job.id }), !isShuttingDown else {
            awaitingQueuedRecord.remove(job.id)
            return .rejected(code: "run_cancelled", message: "The run was cancelled before it started.")
        }
        bus.publish(.run(queued))
        awaitingQueuedRecord.remove(job.id)
        pump()
        return runningTasks[job.id] == nil ? .queued : .started
    }

    private func payloadRejection(prompt: String, mode: String?) -> (code: String, message: String)? {
        let promptBytes = prompt.lengthOfBytes(using: .utf8)
        if promptBytes > maxPromptBytes {
            return (
                code: "prompt_too_large",
                message: "The prompt exceeds the \(maxPromptBytes)-byte limit."
            )
        }
        if (mode?.lengthOfBytes(using: .utf8) ?? 0) > 256 {
            return (code: "mode_too_large", message: "The mode exceeds the 256-byte limit.")
        }
        return nil
    }

    /// Records a run that never entered the queue at all (skipped by policy before it could
    /// collide with anything), so there is still a visible, queryable history entry for it.
    func recordSkipped(_ job: RunJob, reason: String) async {
        let run = Run(
            id: job.id, scheduleId: job.scheduleId,
            threadId: job.target.existingThreadID ?? job.initialSessionID,
            threadPath: job.target.existingThreadPath,
            trigger: job.trigger, startedAt: job.queuedAt, finishedAt: job.queuedAt,
            status: .skipped, error: reason, summary: nil,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt,
            agent: job.target.agent
        )
        let terminalPersisted = await historyStore.record(run)
        bus.publish(.run(run))
        logger.info("Run \(job.id) skipped: \(reason)")
        await job.onCompletion?(RunOutcome(
            status: .skipped, error: reason, summary: nil,
            terminalRecordPersisted: terminalPersisted
        ))
    }

    private func pump() {
        guard !isShuttingDown else { return }
        while runningCount < concurrencyLimit, let index = nextRunnableIndex() {
            let job = pending.remove(at: index)
            pendingBytes = max(0, pendingBytes - Self.retainedBytes(job))
            start(job)
        }
    }

    private func nextRunnableIndex() -> Int? {
        for (index, job) in pending.enumerated() {
            if awaitingQueuedRecord.contains(job.id) { continue }
            if let key = job.target.threadInstanceKey,
               runningThreadKeys.contains(key) || reservedThreadKeys.contains(key) { continue }
            return index
        }
        return nil
    }

    private func start(_ job: RunJob) {
        runningCount += 1
        if let key = job.target.threadInstanceKey { runningThreadKeys.insert(key) }

        var executingJob = job
        let externalIdentityResolved = job.onThreadIdentityResolved
        executingJob.onThreadIdentityResolved = { [weak self] threadID, path in
            guard await self?.promoteRunningRun(
                jobID: job.id, threadID: threadID, path: path
            ) == true else {
                return false
            }
            return await externalIdentityResolved?(threadID, path) ?? true
        }

        let startedRun = Run(
            id: job.id, scheduleId: job.scheduleId,
            threadId: job.target.existingThreadID ?? job.initialSessionID,
            threadPath: job.target.existingThreadPath,
            trigger: job.trigger, startedAt: Date(), status: .running,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt,
            agent: job.target.agent
        )
        logger.info("Run \(job.id) started (\(job.trigger.rawValue), agent=\(job.target.agent.rawValue), target=\(job.target.existingThreadID ?? "new thread in \(job.target.cwd)"))")

        let task = Task {
            let runningPersisted = await historyStore.record(startedRun)
            bus.publish(.run(startedRun))
            let outcome: RunOutcome
            if !runningPersisted {
                outcome = RunOutcome(
                    status: .failed,
                    error: "Could not persist this run before starting its agent.",
                    summary: nil, retryable: true
                )
            } else {
                let preparation = await executingJob.onExecutionStart?() ?? .ready
                switch preparation {
                case .ready:
                    outcome = await manager.run(executingJob)
                case .retry:
                    outcome = RunOutcome(
                        status: .failed,
                        error: "Could not persist this automation before starting its agent.",
                        summary: nil, retryable: true
                    )
                case .cancelled:
                    outcome = RunOutcome(
                        status: .interrupted,
                        error: "This automation was removed before its agent started.",
                        summary: nil
                    )
                }
            }
            await finish(job: job, outcome: outcome)
        }
        runningTasks[job.id] = (job.target.threadInstanceKey, task)
    }

    private func promoteRunningRun(jobID: String, threadID: String, path: String) async -> Bool {
        let key = ThreadInstanceKey(path: path)
        guard var running = runningTasks[jobID] else { return false }
        if running.threadKey == key { return true }
        guard running.threadKey == nil,
              !runningThreadKeys.contains(key),
              !reservedThreadKeys.contains(key) else {
            logger.warn("Run \(jobID) resolved to a thread already owned by another runtime: \(key.path)")
            return false
        }

        // Close both sides of the cross-actor admission race before consulting persistent runtime
        // leases. The queue reservation blocks a lease endpoint entering from this actor, while
        // LeaseStore's token blocks an acquire already between that endpoint's two actor hops.
        reservedThreadKeys.insert(key)
        guard let admission = await leaseStore.beginRunAdmission(thread: key) else {
            reservedThreadKeys.remove(key)
            pump()
            logger.warn("Run \(jobID) resolved to a thread leased by another runtime: \(key.path)")
            return false
        }
        guard let current = runningTasks[jobID], current.threadKey == nil,
              reservedThreadKeys.contains(key), !Task.isCancelled,
              !cancelledRunIDs.contains(jobID), !shutdownRunIDs.contains(jobID) else {
            reservedThreadKeys.remove(key)
            await leaseStore.endRunAdmission(admission)
            pump()
            return false
        }
        running = current
        reservedThreadKeys.remove(key)
        running.threadKey = key
        runningTasks[jobID] = running
        runningThreadKeys.insert(key)
        await leaseStore.endRunAdmission(admission)

        // Identity is useful state, not merely an exclusion key. Persist and publish it before the
        // first prompt byte so run queries and every client can associate the active pulse with a
        // newly created transcript immediately.
        if var run = await historyStore.get(id: jobID) {
            run.threadId = threadID
            run.threadPath = key.path
            await historyStore.record(run)
            bus.publish(.run(run))
        }
        return true
    }

    private func finish(job: RunJob, outcome: RunOutcome) async {
        runningCount -= 1
        let runningKey = runningTasks.removeValue(forKey: job.id)?.threadKey
            ?? job.target.threadInstanceKey
        if let runningKey { runningThreadKeys.remove(runningKey) }

        var finalOutcome = outcome
        // An executor-level transport error can lose the resolved fields it learned after
        // `get_state`. The promoted running record is durable, so preserve that identity in both
        // the terminal record and the scheduler completion callback.
        let promotedRun = await historyStore.get(id: job.id)
        if finalOutcome.resolvedThreadId == nil {
            finalOutcome.resolvedThreadId = promotedRun?.threadId
        }
        if finalOutcome.resolvedThreadPath == nil {
            finalOutcome.resolvedThreadPath = promotedRun?.threadPath
        }
        if cancelledRunIDs.remove(job.id) != nil {
            finalOutcome = RunOutcome(
                status: .interrupted, error: "The run was stopped before it finished.",
                summary: finalOutcome.summary, resolvedThreadId: finalOutcome.resolvedThreadId,
                resolvedThreadPath: finalOutcome.resolvedThreadPath,
                promptStartedAt: finalOutcome.promptStartedAt,
                promptAcceptedAt: finalOutcome.promptAcceptedAt
            )
        } else if shutdownRunIDs.remove(job.id) != nil {
            finalOutcome = RunOutcome(
                status: .interrupted, error: "Pi Desktop closed before the run finished.",
                summary: finalOutcome.summary, resolvedThreadId: finalOutcome.resolvedThreadId,
                resolvedThreadPath: finalOutcome.resolvedThreadPath,
                retryable: job.trigger == .schedule && finalOutcome.promptStartedAt == nil,
                promptStartedAt: finalOutcome.promptStartedAt,
                promptAcceptedAt: finalOutcome.promptAcceptedAt
            )
        }

        let finished = Run(
            id: job.id, scheduleId: job.scheduleId,
            threadId: finalOutcome.resolvedThreadId
                ?? job.target.existingThreadID ?? job.initialSessionID,
            threadPath: finalOutcome.resolvedThreadPath ?? job.target.existingThreadPath,
            trigger: job.trigger, startedAt: job.queuedAt, finishedAt: Date(),
            status: finalOutcome.status, error: finalOutcome.error, summary: finalOutcome.summary,
            occurrenceId: job.occurrenceId, scheduledAt: job.scheduledAt, attempt: job.attempt,
            promptStartedAt: finalOutcome.promptStartedAt,
            promptAcceptedAt: finalOutcome.promptAcceptedAt, retryable: finalOutcome.retryable,
            agent: job.target.agent
        )
        let terminalPersisted = await historyStore.record(finished)
        finalOutcome.terminalRecordPersisted = terminalPersisted
        bus.publish(.run(finished))
        logger.info("Run \(job.id) finished: \(finalOutcome.status.rawValue)\(finalOutcome.error.map { " (\($0))" } ?? "")")

        await job.onCompletion?(finalOutcome)
        pump()
    }

    private static func retainedBytes(_ job: RunJob) -> Int {
        retainedBytes(prompt: job.prompt, mode: job.mode)
    }

    private static func retainedBytes(prompt: String, mode: String?) -> Int {
        prompt.lengthOfBytes(using: .utf8) + (mode?.lengthOfBytes(using: .utf8) ?? 0)
    }
}
