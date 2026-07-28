import Foundation
import PiDeskKit

/// Persists one owed occurrence per schedule, then feeds eligible attempts into `RunQueue`.
/// The daemon may disappear whenever Pi Desktop closes; `Schedule.pendingOccurrence` is therefore
/// the source of truth, while this actor's sets only prevent duplicate enqueueing within one run.
actor Scheduler {
    static let defaultRetryDelays: [TimeInterval] = [60, 5 * 60, 30 * 60, 2 * 3_600, 8 * 3_600]
    private static let unknownWarningLimit = 256

    private let scheduleStore: ScheduleStore
    private let runHistoryStore: RunHistoryStore
    private let runQueue: RunQueue
    private let threadStore: ThreadStore
    private let leaseStore: LeaseStore
    private let bus: EventBus
    private let logger: DaemonLogger
    private let pollInterval: TimeInterval
    private let retryDelays: [TimeInterval]
    private let networkAvailable: @Sendable () -> Bool
    private var loopTask: Task<Void, Never>?
    private var isStopping = false
    private var enqueuedOccurrenceIDs: Set<String> = []
    private var warnedUnknownOccurrenceIDs: Set<String> = []
    private(set) var enabled: Bool

    init(
        scheduleStore: ScheduleStore,
        runHistoryStore: RunHistoryStore,
        runQueue: RunQueue,
        threadStore: ThreadStore,
        leaseStore: LeaseStore = LeaseStore(),
        bus: EventBus,
        logger: DaemonLogger,
        pollInterval: TimeInterval = 1,
        retryDelays: [TimeInterval] = Scheduler.defaultRetryDelays,
        networkAvailable: @escaping @Sendable () -> Bool = { true },
        enabled: Bool = true
    ) {
        self.scheduleStore = scheduleStore
        self.runHistoryStore = runHistoryStore
        self.runQueue = runQueue
        self.threadStore = threadStore
        self.leaseStore = leaseStore
        self.bus = bus
        self.logger = logger
        self.pollInterval = pollInterval
        self.retryDelays = retryDelays.map { max(0, $0) }
        self.networkAvailable = networkAvailable
        self.enabled = enabled
    }

    func start() async {
        guard loopTask == nil, !Task.isCancelled else { return }
        isStopping = false
        await recoverPendingOccurrences(now: Date())
        guard !isStopping, !Task.isCancelled else { return }
        logger.info("Scheduler started (poll interval \(pollInterval)s).")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(max(self.pollInterval, 0.1) * 1_000_000_000))
            }
        }
    }

    func stop() async {
        isStopping = true
        let task = loopTask
        task?.cancel()
        await task?.value
        loopTask = nil
    }

    /// Materializes every due intent before enqueueing any of them. The second pass is ordered by
    /// nominal due time, so opening the app after a long absence stays FIFO without replaying a
    /// backlog for any single automation.
    @discardableResult
    func tick(now: Date = Date()) async -> Int {
        guard enabled, !isStopping else { return 0 }
        await recoverPendingOccurrences(now: now)
        var busy = await runQueue.activeThreadIDs()
        busy.formUnion(await runQueue.pendingThreadIDs())
        busy.formUnion(await leaseStore.leasedThreadIDs(now: now))

        let schedules = await scheduleStore.all().sorted { dueDate($0) < dueDate($1) }
        for schedule in schedules where schedule.pendingOccurrence == nil {
            guard let decision = ScheduleEngine.evaluate(
                schedule: schedule, now: now, isThreadBusy: { busy.contains($0) }
            ) else { continue }

            let decided = decision.updatedSchedule
            let expectedNextRunAt = schedule.nextRunAt
            switch decision.action {
            case .none:
                _ = await updateSchedule(id: schedule.id) { current in
                    guard current.enabled == schedule.enabled,
                          current.pendingOccurrence == nil,
                          current.nextRunAt == expectedNextRunAt,
                          current.trigger == schedule.trigger else { return false }
                    Self.applyTiming(from: decided, to: &current)
                    return true
                }
            case let .skip(reason):
                guard let saved = await updateSchedule(id: schedule.id, { current in
                    guard current.enabled == schedule.enabled,
                          current.pendingOccurrence == nil,
                          current.nextRunAt == expectedNextRunAt,
                          current.trigger == schedule.trigger else { return false }
                    Self.applyTiming(from: decided, to: &current)
                    return true
                }) else { continue }
                let job = await makeJob(
                    id: "run_\(UUID().uuidString)", schedule: saved,
                    trigger: .schedule, queuedAt: now
                )
                await runQueue.recordSkipped(job, reason: reason)
            case .fire:
                let scheduledAt = decided.lastRunAt ?? schedule.nextRunAt ?? now
                let occurrence = ScheduleOccurrence(
                    id: "occ_\(UUID().uuidString)", scheduledAt: scheduledAt,
                    notBefore: now
                )
                if let saved = await updateSchedule(id: schedule.id, { current in
                    guard current.enabled == schedule.enabled,
                          current.pendingOccurrence == nil,
                          current.nextRunAt == expectedNextRunAt,
                          current.trigger == schedule.trigger else { return false }
                    Self.applyTiming(from: decided, to: &current)
                    current.pendingOccurrence = occurrence
                    return true
                }), let threadID = saved.target.existingThreadID {
                    busy.insert(threadID) // predictive for later due schedules in this pass
                }
            }
        }

        // Materialization is durable while offline; attempts wait for macOS to report a usable
        // network path and begin on the next poll after connectivity returns.
        guard networkAvailable() else { return 0 }

        // Predictive first-pass busy state enforces skip policy, but actual enqueueing starts from
        // real queue/lease state so the oldest materialized occurrence gets the thread first.
        busy = await runQueue.activeThreadIDs()
        busy.formUnion(await runQueue.pendingThreadIDs())
        busy.formUnion(await leaseStore.leasedThreadIDs(now: now))

        var fired = 0
        let owed = await scheduleStore.all().filter { $0.enabled && $0.pendingOccurrence != nil }
            .sorted {
                let lhs = $0.pendingOccurrence?.scheduledAt ?? .distantFuture
                let rhs = $1.pendingOccurrence?.scheduledAt ?? .distantFuture
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }

        for schedule in owed {
            guard var occurrence = schedule.pendingOccurrence,
                  occurrence.phase == .pending,
                  occurrence.runId == nil,
                  occurrence.notBefore <= now,
                  !enqueuedOccurrenceIDs.contains(occurrence.id) else {
                if let occurrence = schedule.pendingOccurrence {
                    warnIfUnknown(occurrence, scheduleID: schedule.id)
                }
                continue
            }

            guard let target = await resolve(schedule.target) else {
                await failUnresolvable(schedule, occurrence: occurrence, now: now)
                continue
            }
            if let threadID = target.existingThreadID, busy.contains(threadID) {
                continue // durable occurrence waits rather than being lost while its thread is busy
            }

            occurrence.attemptCount = max(0, occurrence.attemptCount)
            guard occurrence.attemptCount < maxAttempts else {
                await finishExhausted(schedule, occurrence: occurrence, now: now)
                continue
            }
            occurrence.attemptCount += 1
            let runID = "run_\(UUID().uuidString)"
            occurrence.runId = runID
            guard let saved = await updateSchedule(id: schedule.id, { current in
                guard current.enabled, current.target == schedule.target,
                      current.pendingOccurrence?.id == occurrence.id,
                      current.pendingOccurrence?.phase == .pending,
                      current.pendingOccurrence?.runId == nil else { return false }
                current.pendingOccurrence = occurrence
                current.lastStatus = .queued
                current.updatedAt = now
                return true
            }) else { continue }

            enqueuedOccurrenceIDs.insert(occurrence.id)
            if let threadID = target.existingThreadID { busy.insert(threadID) }
            let scheduleID = saved.id
            let occurrenceID = occurrence.id
            let job = RunJob(
                id: runID, scheduleId: scheduleID, occurrenceId: occurrenceID,
                scheduledAt: occurrence.scheduledAt, attempt: occurrence.attemptCount,
                trigger: .schedule, target: target, prompt: saved.prompt, mode: saved.mode,
                timeoutSeconds: saved.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
                queuedAt: now,
                onPromptDispatch: { [weak self] at in
                    guard let self else { return .cancelled }
                    return await self.markOccurrence(
                        scheduleID: scheduleID, occurrenceID: occurrenceID, runID: runID,
                        phase: .dispatching, at: at
                    )
                },
                onPromptAccepted: { [weak self] at in
                    _ = await self?.markOccurrence(
                        scheduleID: scheduleID, occurrenceID: occurrenceID, runID: runID,
                        phase: .accepted, at: at
                    )
                },
                onCompletion: { [weak self] outcome in
                    await self?.complete(
                        scheduleID: scheduleID, occurrenceID: occurrenceID,
                        runID: runID, outcome: outcome
                    )
                }
            )
            await runQueue.enqueue(job)
            fired += 1
        }
        return fired
    }

    /// Manual runs do not consume or create the schedule's one durable occurrence; they still
    /// update its visible last status when they finish.
    func runNow(scheduleId: String) async throws -> String {
        guard let schedule = await scheduleStore.get(id: scheduleId) else {
            throw DaemonHTTPError.notFound("Schedule \(scheduleId)")
        }
        guard let target = await resolve(schedule.target) else {
            throw DaemonHTTPError.badRequest(code: "unresolvable_target", message: "Could not resolve this schedule's target thread.")
        }
        let runID = "run_\(UUID().uuidString)"
        let job = RunJob(
            id: runID, scheduleId: schedule.id, trigger: .manual,
            target: target, prompt: schedule.prompt, mode: schedule.mode,
            timeoutSeconds: schedule.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
            queuedAt: Date(), onCompletion: { [weak self] outcome in
                await self?.finishManual(scheduleID: scheduleId, outcome: outcome)
            }
        )
        await runQueue.enqueue(job)

        let startedAt = Date()
        _ = await updateSchedule(id: schedule.id) { current in
            current.lastRunAt = startedAt
            current.updatedAt = startedAt
            return true
        }
        return runID
    }

    func computeInitialNextRunAt(for trigger: ScheduleTrigger) -> Date? {
        TriggerEngine.nextRunAt(for: trigger, after: Date(), lastRunAt: nil)
    }

    // MARK: - Durable occurrence lifecycle

    private var maxAttempts: Int { retryDelays.count + 1 }

    private func markOccurrence(
        scheduleID: String, occurrenceID: String, runID: String,
        phase: ScheduleOccurrence.Phase, at: Date
    ) async -> PromptDispatchPreparation {
        let saved: Schedule?
        do {
            saved = try await scheduleStore.update(id: scheduleID) { schedule in
                guard var occurrence = schedule.pendingOccurrence,
                      occurrence.id == occurrenceID, occurrence.runId == runID else { return false }
                occurrence.phase = phase
                schedule.pendingOccurrence = occurrence
                schedule.updatedAt = at
                return true
            }
        } catch {
            logger.error("Could not persist schedule \(scheduleID) before prompt delivery: \(error)")
            return .retry
        }
        guard let saved else { return .cancelled }
        bus.publish(.schedule(saved))

        if var run = await runHistoryStore.get(id: runID) {
            if phase == .dispatching { run.promptStartedAt = at }
            if phase == .accepted { run.promptAcceptedAt = at }
            await record(run)
        }
        return .ready
    }

    private func complete(
        scheduleID: String, occurrenceID: String, runID: String, outcome: RunOutcome
    ) async {
        enqueuedOccurrenceIDs.remove(occurrenceID)
        guard let snapshot = await scheduleStore.get(id: scheduleID),
              let occurrence = snapshot.pendingOccurrence,
              occurrence.id == occurrenceID, occurrence.runId == runID else { return }
        let now = Date()

        if outcome.retryable, occurrence.phase == .pending,
           occurrence.attemptCount < maxAttempts,
           !isHeartbeat(snapshot.trigger) {
            let retryAt = now.addingTimeInterval(retryDelays[occurrence.attemptCount - 1])
            let saved = await updateSchedule(id: scheduleID) { schedule in
                guard var current = schedule.pendingOccurrence,
                      current.id == occurrenceID, current.runId == runID else { return false }
                current.runId = nil
                current.notBefore = retryAt
                schedule.pendingOccurrence = current
                schedule.lastStatus = outcome.status
                schedule.updatedAt = now
                return true
            }
            if saved != nil, var run = await runHistoryStore.get(id: runID) {
                run.nextAttemptAt = retryAt
                await record(run)
            }
            return
        }

        _ = await updateSchedule(id: scheduleID) { schedule in
            guard schedule.pendingOccurrence?.id == occurrenceID,
                  schedule.pendingOccurrence?.runId == runID else { return false }
            schedule.pendingOccurrence = nil
            schedule.lastStatus = outcome.status
            schedule.updatedAt = now
            Self.resyncNextRun(&schedule, after: now)
            return true
        }
    }

    private func recoverPendingOccurrences(now: Date) async {
        for schedule in await scheduleStore.all() {
            if isHeartbeat(schedule.trigger) {
                if let occurrence = schedule.pendingOccurrence,
                   enqueuedOccurrenceIDs.contains(occurrence.id) { continue }
                if let occurrence = schedule.pendingOccurrence {
                    await interruptCurrentRun(
                        schedule: schedule, occurrence: occurrence,
                        message: "Heartbeat checks are not replayed after Pi Desktop reopens.", now: now
                    )
                }
                if schedule.pendingOccurrence != nil || (schedule.nextRunAt.map { $0 <= now } ?? false) {
                    _ = await updateSchedule(id: schedule.id) { current in
                        guard case .heartbeat = current.trigger else { return false }
                        current.pendingOccurrence = nil
                        current.nextRunAt = TriggerEngine.nextRunAt(
                            for: current.trigger, after: now, lastRunAt: current.lastRunAt
                        )
                        current.updatedAt = now
                        return true
                    }
                }
                continue
            }

            guard let occurrence = schedule.pendingOccurrence,
                  !enqueuedOccurrenceIDs.contains(occurrence.id) else { continue }

            var persistedRun: Run?
            if let runID = occurrence.runId {
                persistedRun = await runHistoryStore.get(id: runID)
            }

            if let persistedRun, isTerminal(persistedRun.status) {
                if persistedRun.retryable == true, occurrence.phase == .pending,
                   occurrence.attemptCount < maxAttempts {
                    let retryAt = retryDate(
                        afterAttempt: occurrence.attemptCount,
                        existing: persistedRun.nextAttemptAt ?? occurrence.notBefore,
                        now: now
                    )
                    let saved = await updateSchedule(id: schedule.id) { current in
                        guard var pending = current.pendingOccurrence,
                              pending.id == occurrence.id, pending.runId == occurrence.runId,
                              pending.phase == .pending else { return false }
                        pending.runId = nil
                        pending.notBefore = retryAt
                        current.pendingOccurrence = pending
                        current.updatedAt = now
                        return true
                    }
                    if saved != nil {
                        var retryingRun = persistedRun
                        retryingRun.nextAttemptAt = retryAt
                        await record(retryingRun)
                    }
                } else {
                    _ = await updateSchedule(id: schedule.id) { current in
                        guard current.pendingOccurrence?.id == occurrence.id,
                              current.pendingOccurrence?.runId == occurrence.runId else { return false }
                        current.pendingOccurrence = nil
                        current.lastStatus = persistedRun.status
                        current.updatedAt = now
                        Self.resyncNextRun(&current, after: now)
                        return true
                    }
                }
                continue
            }

            switch occurrence.phase {
            case .pending:
                if occurrence.runId != nil {
                    let neverStarted = persistedRun == nil || persistedRun?.status == .queued
                    let retryAt = neverStarted ? now : retryDate(
                        afterAttempt: occurrence.attemptCount,
                        existing: persistedRun?.nextAttemptAt ?? occurrence.notBefore,
                        now: now
                    )
                    let saved = await updateSchedule(id: schedule.id) { current in
                        guard var pending = current.pendingOccurrence,
                              pending.id == occurrence.id, pending.runId == occurrence.runId,
                              pending.phase == .pending else { return false }
                        // A queued record means the executor never began, so merely opening and
                        // closing the app cannot consume the bounded retry budget.
                        if neverStarted { pending.attemptCount = max(0, pending.attemptCount - 1) }
                        pending.runId = nil
                        pending.notBefore = retryAt
                        current.pendingOccurrence = pending
                        current.updatedAt = now
                        return true
                    }
                    if saved != nil {
                        await interruptCurrentRun(
                            schedule: schedule, occurrence: occurrence,
                            message: "Pi Desktop closed before prompt delivery; this occurrence will retry.", now: now,
                            retryable: true, nextAttemptAt: retryAt
                        )
                    }
                }
            case .dispatching, .accepted:
                let saved = await updateSchedule(id: schedule.id) { current in
                    guard current.pendingOccurrence?.id == occurrence.id,
                          current.pendingOccurrence?.runId == occurrence.runId else { return false }
                    current.pendingOccurrence = nil
                    current.lastStatus = .interrupted
                    current.updatedAt = now
                    Self.resyncNextRun(&current, after: now)
                    return true
                }
                if saved != nil {
                    await interruptCurrentRun(
                        schedule: schedule, occurrence: occurrence,
                        message: "Pi Desktop closed after prompt delivery began; the run was not resent.", now: now
                    )
                }
            default:
                warnIfUnknown(occurrence, scheduleID: schedule.id)
            }
        }
    }

    private func interruptCurrentRun(
        schedule: Schedule, occurrence: ScheduleOccurrence, message: String,
        now: Date, retryable: Bool = false, nextAttemptAt: Date? = nil
    ) async {
        let id = occurrence.runId ?? "run_\(UUID().uuidString)"
        let existing = await runHistoryStore.get(id: id)
        let run = Run(
            id: id, scheduleId: schedule.id, threadId: existing?.threadId,
            trigger: .schedule, startedAt: existing?.startedAt ?? now, finishedAt: now,
            status: .interrupted, error: message, summary: existing?.summary,
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt,
            attempt: max(occurrence.attemptCount, 1), nextAttemptAt: nextAttemptAt,
            promptStartedAt: existing?.promptStartedAt,
            promptAcceptedAt: existing?.promptAcceptedAt, retryable: retryable
        )
        await record(run)
    }

    private func failUnresolvable(_ schedule: Schedule, occurrence: ScheduleOccurrence, now: Date) async {
        guard await updateSchedule(id: schedule.id, { current in
            guard current.target == schedule.target,
                  current.pendingOccurrence?.id == occurrence.id else { return false }
            current.pendingOccurrence = nil
            current.lastStatus = .failed
            current.updatedAt = now
            Self.resyncNextRun(&current, after: now)
            return true
        }) != nil else { return }

        let run = Run(
            id: "run_\(UUID().uuidString)", scheduleId: schedule.id, trigger: .schedule,
            startedAt: now, finishedAt: now, status: .failed,
            error: "Could not resolve the schedule's target thread.",
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt,
            attempt: occurrence.attemptCount + 1, retryable: false
        )
        await record(run)
    }

    private func finishExhausted(_ schedule: Schedule, occurrence: ScheduleOccurrence, now: Date) async {
        _ = await updateSchedule(id: schedule.id) { current in
            guard current.pendingOccurrence?.id == occurrence.id,
                  current.pendingOccurrence?.runId == occurrence.runId else { return false }
            current.pendingOccurrence = nil
            current.lastStatus = .failed
            current.updatedAt = now
            Self.resyncNextRun(&current, after: now)
            return true
        }
    }

    private func finishManual(scheduleID: String, outcome: RunOutcome) async {
        let now = Date()
        _ = await updateSchedule(id: scheduleID) { schedule in
            schedule.lastStatus = outcome.status
            schedule.updatedAt = now
            return true
        }
    }

    // MARK: - Helpers

    private func resolve(_ target: ScheduleTarget) async -> RunTarget? {
        switch target {
        case let .existingThread(threadId):
            guard let thread = await threadStore.thread(idOrPath: threadId) else { return nil }
            return .existingThread(threadId: thread.id, path: thread.path, cwd: thread.cwd)
        case let .newThread(cwd, namePattern):
            guard !cwd.isEmpty else { return nil }
            return .newThread(cwd: cwd, namePattern: namePattern)
        case .other:
            return nil
        }
    }

    private func makeJob(id: String, schedule: Schedule, trigger: RunTrigger, queuedAt: Date) async -> RunJob {
        let target = await resolve(schedule.target) ?? .newThread(cwd: "", namePattern: nil)
        return RunJob(
            id: id, scheduleId: schedule.id, trigger: trigger, target: target,
            prompt: schedule.prompt, mode: schedule.mode,
            timeoutSeconds: schedule.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
            queuedAt: queuedAt
        )
    }

    private func warnIfUnknown(_ occurrence: ScheduleOccurrence, scheduleID: String) {
        guard !ScheduleOccurrence.Phase.knownCases.contains(occurrence.phase),
              !warnedUnknownOccurrenceIDs.contains(occurrence.id),
              warnedUnknownOccurrenceIDs.count < Self.unknownWarningLimit else { return }
        warnedUnknownOccurrenceIDs.insert(occurrence.id)
        logger.error("Schedule \(scheduleID) has unknown pending occurrence phase \(occurrence.phase.rawValue); leaving it untouched.")
    }

    private func retryDate(afterAttempt attempt: Int, existing: Date?, now: Date) -> Date {
        if let existing, existing > now { return existing }
        guard !retryDelays.isEmpty else { return now }
        let index = min(max(attempt - 1, 0), retryDelays.count - 1)
        return now.addingTimeInterval(retryDelays[index])
    }

    private func dueDate(_ schedule: Schedule) -> Date {
        schedule.pendingOccurrence?.scheduledAt ?? schedule.nextRunAt ?? .distantFuture
    }

    private func isHeartbeat(_ trigger: ScheduleTrigger) -> Bool {
        if case .heartbeat = trigger { return true }
        return false
    }

    private func isTerminal(_ status: RunStatus) -> Bool {
        ![RunStatus.queued, .running].contains(status)
    }

    private static func applyTiming(from decided: Schedule, to schedule: inout Schedule) {
        schedule.nextRunAt = decided.nextRunAt
        schedule.lastRunAt = decided.lastRunAt
        schedule.lastStatus = decided.lastStatus
        schedule.updatedAt = decided.updatedAt
    }

    private static func resyncNextRun(_ schedule: inout Schedule, after now: Date) {
        guard let next = schedule.nextRunAt, next <= now else { return }
        schedule.nextRunAt = TriggerEngine.nextRunAt(
            for: schedule.trigger, after: now, lastRunAt: schedule.lastRunAt
        )
    }

    @discardableResult
    private func updateSchedule(
        id: String, _ transform: @escaping (inout Schedule) -> Bool
    ) async -> Schedule? {
        do {
            let saved = try await scheduleStore.update(id: id, transform)
            if let saved { bus.publish(.schedule(saved)) }
            return saved
        } catch {
            logger.error("Could not persist schedule \(id): \(error)")
            return nil
        }
    }

    private func record(_ run: Run) async {
        await runHistoryStore.record(run)
        bus.publish(.run(run))
    }
}
