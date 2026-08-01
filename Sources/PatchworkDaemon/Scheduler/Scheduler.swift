import Foundation
import PatchworkKit

/// Persists one owed occurrence per schedule, then feeds eligible attempts into `RunQueue`.
/// The daemon may disappear whenever Patchwork closes; `Schedule.pendingOccurrence` is therefore
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
    private var didRecoverPersistedOccurrences = false
    private var enqueuedOccurrenceIDs: Set<String> = []
    /// A heartbeat rejected by transient admission pressure remains retryable during this daemon
    /// lifetime. On relaunch this set is empty, preserving the no-replay heartbeat policy.
    private var admissionDeferredOccurrenceIDs: Set<String> = []
    /// Successful fresh-thread publications waiting for that run's completion callback. Keeping
    /// this keyed by run id makes the accepted-path completion retry idempotent without retaining
    /// transcript identities after the run has settled.
    private var publishedCreatedThreadRunIDs: Set<String> = []
    private struct DeferredFreshThreadRecovery {
        var attempt: Int
        var notBefore: Date
        var alreadyPublished: Bool
    }
    private enum FreshThreadPublication: Equatable {
        case notRequired
        case published
        case unavailable
        case failed
    }
    private var deferredFreshThreadRecoveries: [String: DeferredFreshThreadRecovery] = [:]
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
        await recoverPersistedOccurrencesIfNeeded(now: Date())
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
        await recoverPersistedOccurrencesIfNeeded(now: now)
        await retryDeferredFreshThreadRecoveries(now: now)
        var busy = await runQueue.activeThreadKeys()
        busy.formUnion(await runQueue.pendingThreadKeys())
        busy.formUnion(await leaseStore.leasedThreadKeys(now: now))
        var resolvedTargets: [ScheduleTarget: RunTarget] = [:]
        var unresolvedTargets: Set<ScheduleTarget> = []

        let schedules = await scheduleStore.all().sorted { dueDate($0) < dueDate($1) }
        admissionDeferredOccurrenceIDs.formIntersection(
            Set(schedules.compactMap { $0.pendingOccurrence?.id })
        )
        for schedule in schedules where schedule.pendingOccurrence == nil {
            guard let baseline = ScheduleEngine.evaluate(
                schedule: schedule, now: now, isThreadBusy: { _ in false }
            ) else { continue }

            var resolvedTarget: RunTarget?
            var decision = baseline
            if case .fire = baseline.action, schedule.target.existingThreadID != nil {
                if let cached = resolvedTargets[schedule.target] {
                    resolvedTarget = cached
                } else if !unresolvedTargets.contains(schedule.target) {
                    resolvedTarget = await resolve(schedule.target, agent: schedule.agent)
                    if let resolvedTarget {
                        resolvedTargets[schedule.target] = resolvedTarget
                    } else {
                        unresolvedTargets.insert(schedule.target)
                    }
                }
                let targetIsBusy = resolvedTarget?.threadInstanceKey.map(busy.contains) ?? false
                if targetIsBusy {
                    guard let busyDecision = ScheduleEngine.evaluate(
                        schedule: schedule, now: now, isThreadBusy: { _ in true }
                    ) else { continue }
                    decision = busyDecision
                }
            }

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
                guard let resolvedTarget else { continue }
                guard let saved = await updateSchedule(id: schedule.id, { current in
                    guard current.enabled == schedule.enabled,
                          current.pendingOccurrence == nil,
                          current.nextRunAt == expectedNextRunAt,
                          current.trigger == schedule.trigger else { return false }
                    Self.applyTiming(from: decided, to: &current)
                    return true
                }) else { continue }
                let job = makeJob(
                    id: "run_\(UUID().uuidString)", schedule: saved,
                    trigger: .schedule, queuedAt: now, target: resolvedTarget
                )
                await runQueue.recordSkipped(job, reason: reason)
            case .fire:
                let scheduledAt = decided.lastRunAt ?? schedule.nextRunAt ?? now
                let preallocated = Self.preallocatedFreshIdentity(
                    target: schedule.target, agent: schedule.agent ?? .pi
                )
                let occurrence = ScheduleOccurrence(
                    id: "occ_\(UUID().uuidString)", scheduledAt: scheduledAt,
                    notBefore: now, threadId: preallocated?.id,
                    threadPath: preallocated?.path
                )
                if await updateSchedule(id: schedule.id, { current in
                    guard current.enabled == schedule.enabled,
                          current.pendingOccurrence == nil,
                          current.nextRunAt == expectedNextRunAt,
                          current.trigger == schedule.trigger else { return false }
                    Self.applyTiming(from: decided, to: &current)
                    // Materializing owed work is not yet a queue transition. Keep the last
                    // completed result visible until admission actually succeeds below.
                    current.lastStatus = schedule.lastStatus
                    current.pendingOccurrence = occurrence
                    return true
                }) != nil, let threadKey = resolvedTarget?.threadInstanceKey {
                    busy.insert(threadKey) // predictive for later due schedules in this pass
                }
            }
        }

        // Materialization is durable while offline; attempts wait for macOS to report a usable
        // network path and begin on the next poll after connectivity returns.
        guard networkAvailable() else { return 0 }

        // Predictive first-pass busy state enforces skip policy, but actual enqueueing starts from
        // real queue/lease state so the oldest materialized occurrence gets the thread first.
        busy = await runQueue.activeThreadKeys()
        busy.formUnion(await runQueue.pendingThreadKeys())
        busy.formUnion(await leaseStore.leasedThreadKeys(now: now))

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

            let target: RunTarget?
            if schedule.target.existingThreadID == nil {
                target = await resolveAttemptTarget(schedule: schedule, occurrence: occurrence)
            } else if let cached = resolvedTargets[schedule.target] {
                target = cached
            } else if unresolvedTargets.contains(schedule.target) {
                target = nil
            } else {
                target = await resolve(schedule.target, agent: schedule.agent)
                if let target {
                    resolvedTargets[schedule.target] = target
                } else {
                    unresolvedTargets.insert(schedule.target)
                }
            }
            guard let target else {
                await failUnresolvable(schedule, occurrence: occurrence, now: now)
                continue
            }
            if let threadKey = target.threadInstanceKey, busy.contains(threadKey) {
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
            if let threadKey = target.threadInstanceKey { busy.insert(threadKey) }
            let scheduleID = saved.id
            let occurrenceID = occurrence.id
            let freshAgent: AgentKind?
            if case .newThread = saved.target {
                freshAgent = saved.agent ?? target.agent
            } else {
                freshAgent = nil
            }
            let resumesPublishedFreshThread = freshAgent != nil
                && target.existingThreadPath != nil
            if resumesPublishedFreshThread {
                publishedCreatedThreadRunIDs.insert(runID)
            }
            let onThreadReady = resumesPublishedFreshThread ? nil : createdThreadCallback(
                forFreshAgent: freshAgent, runID: runID
            )
            let onExecutionStart: (@Sendable () async -> PromptDispatchPreparation)?
            let onThreadIdentityResolved: (@Sendable (String, String) async -> Bool)?
            if freshAgent != nil {
                onExecutionStart = { [weak self] in
                    guard let self else { return .cancelled }
                    return await self.markOccurrence(
                        scheduleID: scheduleID, occurrenceID: occurrenceID, runID: runID,
                        phase: .starting, at: Date()
                    )
                }
                onThreadIdentityResolved = { [weak self] threadID, path in
                    guard let self else { return false }
                    return await self.markFreshThreadIdentity(
                        scheduleID: scheduleID, occurrenceID: occurrenceID,
                        runID: runID, threadID: threadID, path: path
                    )
                }
            } else {
                onExecutionStart = nil
                onThreadIdentityResolved = nil
            }
            let job = RunJob(
                id: runID, scheduleId: scheduleID, occurrenceId: occurrenceID,
                scheduledAt: occurrence.scheduledAt, attempt: occurrence.attemptCount,
                trigger: .schedule, target: target, prompt: saved.prompt, mode: saved.mode,
                timeoutSeconds: saved.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
                queuedAt: now, initialSessionID: occurrence.threadId,
                onExecutionStart: onExecutionStart,
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
                onThreadIdentityResolved: onThreadIdentityResolved,
                onThreadReady: onThreadReady,
                onCompletion: { [weak self] outcome in
                    guard let self else { return }
                    let publication = await self.recoverCreatedThreadAtCompletion(
                        runID: runID, freshAgent: freshAgent, outcome: outcome
                    )
                    await self.complete(
                        scheduleID: scheduleID, occurrenceID: occurrenceID,
                        runID: runID, freshAgent: freshAgent, outcome: outcome,
                        publication: publication
                    )
                }
            )
            switch await runQueue.enqueue(job) {
            case .started, .queued:
                admissionDeferredOccurrenceIDs.remove(occurrenceID)
                fired += 1
            case let .rejected(code, _) where code == "run_queue_full"
                || code == "thread_leased" || code == "run_history_unavailable":
                enqueuedOccurrenceIDs.remove(occurrenceID)
                admissionDeferredOccurrenceIDs.insert(occurrenceID)
                if let threadKey = target.threadInstanceKey { busy.remove(threadKey) }
                _ = await updateSchedule(id: scheduleID) { current in
                    guard var pending = current.pendingOccurrence,
                          pending.id == occurrenceID,
                          pending.runId == runID,
                          pending.phase == .pending else { return false }
                    pending.runId = nil
                    pending.attemptCount = max(0, pending.attemptCount - 1)
                    current.pendingOccurrence = pending
                    current.lastStatus = schedule.lastStatus
                    current.updatedAt = now
                    return true
                }
            case let .rejected(_, message):
                admissionDeferredOccurrenceIDs.remove(occurrenceID)
                await runQueue.recordSkipped(job, reason: message)
            }
        }
        return fired
    }

    /// Manual runs do not consume or create the schedule's one durable occurrence; they still
    /// update its visible last status when they finish.
    func runNow(scheduleId: String) async throws -> String {
        guard let schedule = await scheduleStore.get(id: scheduleId) else {
            throw DaemonHTTPError.notFound("Schedule \(scheduleId)")
        }
        guard let target = await resolve(schedule.target, agent: schedule.agent) else {
            throw DaemonHTTPError.badRequest(code: "unresolvable_target", message: "Could not resolve this schedule's target thread.")
        }
        let runID = "run_\(UUID().uuidString)"
        let freshAgent: AgentKind?
        if case .newThread(_, _, let agent) = target { freshAgent = agent } else { freshAgent = nil }
        let onThreadReady = createdThreadCallback(forFreshAgent: freshAgent, runID: runID)
        let job = RunJob(
            id: runID, scheduleId: schedule.id, trigger: .manual,
            target: target, prompt: schedule.prompt, mode: schedule.mode,
            timeoutSeconds: schedule.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
            queuedAt: Date(), onThreadReady: onThreadReady,
            onCompletion: { [weak self] outcome in
                guard let self else { return }
                _ = await self.recoverCreatedThreadAtCompletion(
                    runID: runID, freshAgent: freshAgent, outcome: outcome
                )
                await self.finishManual(scheduleID: scheduleId, outcome: outcome)
            }
        )
        if case let .rejected(code, message) = await runQueue.enqueue(job) {
            if code == "thread_leased" {
                throw DaemonHTTPError.conflict(code: code, message: message)
            }
            throw DaemonHTTPError.serviceUnavailable(code: code, message: message)
        }

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

    private func markFreshThreadIdentity(
        scheduleID: String, occurrenceID: String, runID: String,
        threadID: String, path: String
    ) async -> Bool {
        guard !threadID.isEmpty, threadID.utf8.count <= 256,
              !path.isEmpty, path.utf8.count <= 4_096 else { return false }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return await updateSchedule(id: scheduleID) { schedule in
            guard var occurrence = schedule.pendingOccurrence,
                  occurrence.id == occurrenceID, occurrence.runId == runID,
                  occurrence.phase == .starting,
                  occurrence.threadId == nil || occurrence.threadId == threadID else {
                return false
            }
            if let expectedPath = occurrence.threadPath,
               URL(fileURLWithPath: expectedPath).standardizedFileURL.path != standardizedPath {
                return false
            }
            occurrence.threadId = threadID
            occurrence.threadPath = standardizedPath
            schedule.pendingOccurrence = occurrence
            schedule.updatedAt = Date()
            return true
        } != nil
    }

    private func complete(
        scheduleID: String, occurrenceID: String, runID: String,
        freshAgent: AgentKind?, outcome: RunOutcome,
        publication: FreshThreadPublication
    ) async {
        enqueuedOccurrenceIDs.remove(occurrenceID)
        guard let snapshot = await scheduleStore.get(id: scheduleID),
              let occurrence = snapshot.pendingOccurrence,
              occurrence.id == occurrenceID, occurrence.runId == runID else { return }
        let now = Date()

        // The occurrence remains the durable recovery breadcrumb until its terminal run snapshot
        // reaches disk. A later tick flushes RunHistoryStore's bounded dirty snapshot and resumes
        // settlement without executing the prompt again.
        guard outcome.terminalRecordPersisted else { return }

        if publication == .failed {
            deferFreshThreadRecovery(
                occurrenceID: occurrenceID, now: now, alreadyPublished: false
            )
            return
        }

        if outcome.retryable, outcome.promptStartedAt == nil, !isHeartbeat(snapshot.trigger),
           await retryReusableUnmaterializedFreshStart(
            schedule: snapshot, occurrence: occurrence,
            persistedRun: await runHistoryStore.get(id: runID), now: now
           ) {
            return
        }

        if outcome.retryable, outcome.promptStartedAt == nil,
           occurrence.phase == .pending,
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

        let saved = await updateSchedule(id: scheduleID) { schedule in
            guard schedule.pendingOccurrence?.id == occurrenceID,
                  schedule.pendingOccurrence?.runId == runID else { return false }
            schedule.pendingOccurrence = nil
            schedule.lastStatus = outcome.status
            schedule.updatedAt = now
            Self.resyncNextRun(&schedule, after: now)
            return true
        }
        if saved == nil, publication == .published, freshAgent != nil {
            deferFreshThreadRecovery(
                occurrenceID: occurrenceID, now: now, alreadyPublished: true
            )
        }
    }

    private func recoverPersistedOccurrencesIfNeeded(now: Date) async {
        let isInitialRecovery = !didRecoverPersistedOccurrences
        didRecoverPersistedOccurrences = true
        await recoverPendingOccurrences(now: now, isInitialRecovery: isInitialRecovery)
    }

    private func recoverPendingOccurrences(now: Date, isInitialRecovery: Bool) async {
        let schedules = await scheduleStore.all()
        for schedule in schedules {
            if isHeartbeat(schedule.trigger) {
                if let occurrence = schedule.pendingOccurrence,
                   enqueuedOccurrenceIDs.contains(occurrence.id)
                    || admissionDeferredOccurrenceIDs.contains(occurrence.id) { continue }
                if let occurrence = schedule.pendingOccurrence {
                    await interruptCurrentRun(
                        schedule: schedule, occurrence: occurrence,
                        message: "Heartbeat checks are not replayed after Patchwork reopens.", now: now
                    )
                }
                if schedule.pendingOccurrence != nil
                    || (isInitialRecovery && (schedule.nextRunAt.map { $0 <= now } ?? false)) {
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
            if let deferred = deferredFreshThreadRecoveries[occurrence.id],
               deferred.notBefore > now { continue }

            var persistedRun: Run?
            if let runID = occurrence.runId {
                persistedRun = await runHistoryStore.get(id: runID)
                if persistedRun != nil, !(await runHistoryStore.flush(id: runID)) {
                    continue
                }
            }

            // A fresh runtime can resolve and persist its physical transcript before the durable
            // prompt-dispatch boundary. If the daemon then exits, retrying the schedule's original
            // `.newThread` target would create a second conversation. Retire that attempt and
            // recover the exact transcript instead, whether the last Run record was still active or
            // had already become terminal just before its completion callback was lost.
            if ScheduleOccurrence.Phase.knownCases.contains(occurrence.phase),
               await recoverResolvedFreshThreadAfterRestart(
                schedule: schedule, occurrence: occurrence, persistedRun: persistedRun, now: now
               ) {
                continue
            }

            if persistedRun == nil || persistedRun.map({
                !isTerminal($0.status) || $0.retryable == true
            }) == true {
                if await retryReusableUnmaterializedFreshStart(
                    schedule: schedule, occurrence: occurrence,
                    persistedRun: persistedRun, now: now
                ) {
                    continue
                }
            }

            if let persistedRun, isTerminal(persistedRun.status) {
                if persistedRun.retryable == true, occurrence.phase == .pending,
                   occurrence.attemptCount < maxAttempts,
                   isSafePendingRetry(schedule: schedule, occurrence: occurrence) {
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
                    let safeToRetry = neverStarted
                        || isSafePendingRetry(schedule: schedule, occurrence: occurrence)
                    if !safeToRetry {
                        if await interruptCurrentRun(
                            schedule: schedule, occurrence: occurrence,
                            message: "Patchwork closed after starting a fresh conversation whose identity could not be confirmed; the run was not retried.",
                            now: now
                        ) {
                            _ = await finishInterruptedOccurrence(
                                schedule: schedule, occurrence: occurrence, now: now
                            )
                        }
                        continue
                    }
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
                            message: "Patchwork closed before prompt delivery; this occurrence will retry.", now: now,
                            retryable: true, nextAttemptAt: retryAt
                        )
                    }
                }
            case .starting:
                if await interruptCurrentRun(
                    schedule: schedule, occurrence: occurrence,
                    message: "Patchwork closed after starting a fresh conversation; the run was not retried.",
                    now: now
                ) {
                    _ = await finishInterruptedOccurrence(
                        schedule: schedule, occurrence: occurrence, now: now
                    )
                }
            case .dispatching, .accepted:
                if await interruptCurrentRun(
                    schedule: schedule, occurrence: occurrence,
                    message: "Patchwork closed after prompt delivery began; the run was not resent.", now: now
                ) {
                    _ = await finishInterruptedOccurrence(
                        schedule: schedule, occurrence: occurrence, now: now
                    )
                }
            default:
                warnIfUnknown(occurrence, scheduleID: schedule.id)
            }
        }
    }

    /// Returns true when this attempt either recovered its parseable transcript or retained the
    /// durable occurrence for a later reconciliation attempt. A reported path alone is not proof
    /// of materialization because some agents predict it before writing their first JSONL record.
    private func recoverResolvedFreshThreadAfterRestart(
        schedule: Schedule, occurrence: ScheduleOccurrence, persistedRun: Run?, now: Date
    ) async -> Bool {
        guard case let .newThread(cwd, _) = schedule.target,
              let runID = occurrence.runId,
              let threadID = occurrence.threadId ?? persistedRun?.threadId,
              !threadID.isEmpty else { return false }

        let agent = persistedRun?.agent ?? schedule.agent ?? .pi
        let path: String
        if let reportedPath = occurrence.threadPath ?? persistedRun?.threadPath,
           Self.hasMaterializedTranscript(at: reportedPath) {
            path = URL(fileURLWithPath: reportedPath).standardizedFileURL.path
        } else if let discovered = try? await threadStore.resolveForMutation(idOrPath: threadID),
                  discovered.id == threadID, discovered.agent == agent,
                  discovered.cwd == URL(fileURLWithPath: cwd).standardizedFileURL.path {
            path = discovered.path
        } else {
            return false
        }

        var recoveredRun = persistedRun ?? Run(
            id: runID, scheduleId: schedule.id, threadId: threadID, threadPath: path,
            trigger: .schedule, startedAt: occurrence.scheduledAt,
            status: .interrupted, occurrenceId: occurrence.id,
            scheduledAt: occurrence.scheduledAt, attempt: max(occurrence.attemptCount, 1),
            retryable: false, agent: agent
        )
        recoveredRun.threadId = threadID
        recoveredRun.threadPath = path
        recoveredRun.agent = agent
        recoveredRun.retryable = false
        recoveredRun.nextAttemptAt = nil
        if !isTerminal(recoveredRun.status) {
            recoveredRun.status = .interrupted
            recoveredRun.finishedAt = now
            recoveredRun.error = occurrence.phase == .pending
                ? "Patchwork closed after creating this conversation but before prompt delivery; the run was not retried."
                : "Patchwork closed after prompt delivery began; the run was not resent."
        }

        // Publish/manage first while the occurrence still owns the recovery breadcrumb.
        let alreadyPublished = deferredFreshThreadRecoveries[occurrence.id]?.alreadyPublished == true
        if !alreadyPublished,
           !(await publishCreatedThread(
            threadID: threadID, path: path, agent: agent, running: false,
            waitDespiteCancellation: true
           )) {
            deferFreshThreadRecovery(
                occurrenceID: occurrence.id, now: now, alreadyPublished: false
            )
            return true
        }

        if occurrence.phase == .starting, occurrence.attemptCount < maxAttempts,
           persistedRun == nil || persistedRun.map({
            !isTerminal($0.status) || $0.retryable == true
           }) == true {
            let retryAt = retryDate(
                afterAttempt: max(occurrence.attemptCount, 1),
                existing: persistedRun?.nextAttemptAt, now: now
            )
            recoveredRun.status = .interrupted
            recoveredRun.finishedAt = now
            recoveredRun.error = "Patchwork closed before prompt delivery; this occurrence will resume the created conversation."
            recoveredRun.retryable = true
            recoveredRun.nextAttemptAt = retryAt
            await record(recoveredRun)
            let saved = await updateSchedule(id: schedule.id) { current in
                guard var pending = current.pendingOccurrence,
                      pending.id == occurrence.id, pending.runId == runID,
                      pending.phase == .starting else { return false }
                pending.phase = .pending
                pending.runId = nil
                pending.notBefore = retryAt
                pending.threadId = threadID
                pending.threadPath = path
                current.pendingOccurrence = pending
                current.lastStatus = .interrupted
                current.updatedAt = now
                return true
            }
            guard saved != nil else {
                deferFreshThreadRecovery(
                    occurrenceID: occurrence.id, now: now, alreadyPublished: true
                )
                return true
            }
            deferredFreshThreadRecoveries.removeValue(forKey: occurrence.id)
            return true
        }
        guard await record(recoveredRun) else {
            deferFreshThreadRecovery(
                occurrenceID: occurrence.id, now: now, alreadyPublished: true
            )
            return true
        }

        let saved = await updateSchedule(id: schedule.id) { current in
            guard current.pendingOccurrence?.id == occurrence.id,
                  current.pendingOccurrence?.runId == runID else { return false }
            current.pendingOccurrence = nil
            current.lastStatus = recoveredRun.status
            current.updatedAt = now
            Self.resyncNextRun(&current, after: now)
            return true
        }
        guard saved != nil else {
            deferFreshThreadRecovery(
                occurrenceID: occurrence.id, now: now, alreadyPublished: true
            )
            return true
        }
        deferredFreshThreadRecoveries.removeValue(forKey: occurrence.id)
        return true
    }

    private func retryReusableUnmaterializedFreshStart(
        schedule: Schedule, occurrence: ScheduleOccurrence,
        persistedRun: Run?, now: Date
    ) async -> Bool {
        guard occurrence.phase == .starting,
              case .newThread = schedule.target,
              occurrence.attemptCount < maxAttempts else { return false }
        let agent = persistedRun?.agent ?? schedule.agent ?? .pi
        // Codex owns identity allocation. If its thread/start acknowledgement was lost, retrying
        // without an identity could silently create a second conversation. Keep the durable
        // starting breadcrumb for explicit reconciliation instead of guessing.
        if agent == .codex && (
            occurrence.threadId?.isEmpty != false || occurrence.threadPath?.isEmpty != false
        ) {
            logger.error(
                "Schedule \(schedule.id) may have started a Codex conversation before identity was persisted; retaining occurrence \(occurrence.id) without resending."
            )
            if persistedRun == nil || persistedRun.map({ !isTerminal($0.status) }) == true {
                await interruptCurrentRun(
                    schedule: schedule, occurrence: occurrence,
                    message: "Patchwork closed while Codex conversation identity was being assigned; the prompt was not resent.",
                    now: now
                )
            }
            _ = await updateSchedule(id: schedule.id) { current in
                guard current.pendingOccurrence?.id == occurrence.id,
                      current.pendingOccurrence?.runId == occurrence.runId,
                      current.pendingOccurrence?.phase == .starting else { return false }
                current.lastStatus = .interrupted
                current.updatedAt = now
                return true
            }
            return true
        }
        guard let threadID = occurrence.threadId, !threadID.isEmpty,
              agent == .pi || agent == .claude || agent == .codex else { return false }

        let retryAt = retryDate(
            afterAttempt: max(occurrence.attemptCount, 1),
            existing: persistedRun?.nextAttemptAt,
            now: now
        )
        let saved = await updateSchedule(id: schedule.id) { current in
            guard var pending = current.pendingOccurrence,
                  pending.id == occurrence.id, pending.runId == occurrence.runId,
                  pending.phase == .starting, pending.threadId == threadID else { return false }
            pending.phase = .pending
            pending.runId = nil
            pending.notBefore = retryAt
            current.pendingOccurrence = pending
            current.lastStatus = .interrupted
            current.updatedAt = now
            return true
        }
        // A failed write must retain the no-resend state. Returning true prevents the caller from
        // clearing or replaying the same fresh-thread attempt in this process.
        guard saved != nil else { return true }
        if var run = persistedRun, isTerminal(run.status) {
            run.retryable = true
            run.nextAttemptAt = retryAt
            await record(run)
        } else {
            await interruptCurrentRun(
                schedule: schedule, occurrence: occurrence,
                message: "Patchwork closed before prompt delivery; this occurrence will retry the same conversation identity.",
                now: now, retryable: true, nextAttemptAt: retryAt
            )
        }
        return true
    }

    private func isSafePendingRetry(
        schedule: Schedule, occurrence: ScheduleOccurrence
    ) -> Bool {
        guard case .newThread = schedule.target else { return true }
        guard let threadID = occurrence.threadId, !threadID.isEmpty else { return false }
        let agent = schedule.agent ?? .pi
        return agent == .pi || agent == .claude
    }

    @discardableResult
    private func finishInterruptedOccurrence(
        schedule: Schedule, occurrence: ScheduleOccurrence, now: Date
    ) async -> Bool {
        await updateSchedule(id: schedule.id) { current in
            guard current.pendingOccurrence?.id == occurrence.id,
                  current.pendingOccurrence?.runId == occurrence.runId else { return false }
            current.pendingOccurrence = nil
            current.lastStatus = .interrupted
            current.updatedAt = now
            Self.resyncNextRun(&current, after: now)
            return true
        } != nil
    }

    private func deferFreshThreadRecovery(
        occurrenceID: String, now: Date, alreadyPublished: Bool
    ) {
        let prior = deferredFreshThreadRecoveries[occurrenceID]
        let attempt = min((prior?.attempt ?? 0) + 1, 1_000_000)
        let delays: [TimeInterval] = [1, 5, 30, 60, 300]
        let delay = delays[min(attempt - 1, delays.count - 1)]
        deferredFreshThreadRecoveries[occurrenceID] = DeferredFreshThreadRecovery(
            attempt: attempt, notBefore: now.addingTimeInterval(delay),
            alreadyPublished: alreadyPublished || prior?.alreadyPublished == true
        )
    }

    private func retryDeferredFreshThreadRecoveries(now: Date) async {
        guard !deferredFreshThreadRecoveries.isEmpty else { return }
        let schedules = await scheduleStore.all()
        let byOccurrence = Dictionary(uniqueKeysWithValues: schedules.compactMap { schedule in
            schedule.pendingOccurrence.map { ($0.id, schedule) }
        })
        deferredFreshThreadRecoveries = deferredFreshThreadRecoveries.filter {
            byOccurrence[$0.key] != nil
        }
        let due = deferredFreshThreadRecoveries.compactMap { id, recovery in
            recovery.notBefore <= now ? id : nil
        }
        for occurrenceID in due {
            guard let schedule = byOccurrence[occurrenceID],
                  let occurrence = schedule.pendingOccurrence,
                  !enqueuedOccurrenceIDs.contains(occurrenceID) else { continue }
            let persistedRun: Run?
            if let runID = occurrence.runId {
                persistedRun = await runHistoryStore.get(id: runID)
            } else {
                persistedRun = nil
            }
            if !(await recoverResolvedFreshThreadAfterRestart(
                schedule: schedule, occurrence: occurrence,
                persistedRun: persistedRun, now: now
            )) {
                deferFreshThreadRecovery(
                    occurrenceID: occurrenceID, now: now,
                    alreadyPublished: deferredFreshThreadRecoveries[occurrenceID]?.alreadyPublished == true
                )
            }
        }
    }

    private static func hasMaterializedTranscript(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    @discardableResult
    private func interruptCurrentRun(
        schedule: Schedule, occurrence: ScheduleOccurrence, message: String,
        now: Date, retryable: Bool = false, nextAttemptAt: Date? = nil
    ) async -> Bool {
        let id = occurrence.runId ?? "run_\(UUID().uuidString)"
        let existing = await runHistoryStore.get(id: id)
        let run = Run(
            id: id, scheduleId: schedule.id,
            threadId: occurrence.threadId ?? existing?.threadId,
            threadPath: occurrence.threadPath ?? existing?.threadPath,
            trigger: .schedule, startedAt: existing?.startedAt ?? now, finishedAt: now,
            status: .interrupted, error: message, summary: existing?.summary,
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt,
            attempt: max(occurrence.attemptCount, 1), nextAttemptAt: nextAttemptAt,
            promptStartedAt: existing?.promptStartedAt,
            promptAcceptedAt: existing?.promptAcceptedAt, retryable: retryable,
            agent: existing?.agent ?? schedule.agent ?? .pi
        )
        return await record(run)
    }

    private func failUnresolvable(_ schedule: Schedule, occurrence: ScheduleOccurrence, now: Date) async {
        let run = Run(
            id: occurrence.runId ?? "run_\(occurrence.id)",
            scheduleId: schedule.id, trigger: .schedule,
            startedAt: now, finishedAt: now, status: .failed,
            error: "Could not resolve the schedule's target thread.",
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt,
            attempt: occurrence.attemptCount + 1, retryable: false
        )
        guard await record(run) else { return }
        _ = await updateSchedule(id: schedule.id) { current in
            guard current.target == schedule.target,
                  current.pendingOccurrence?.id == occurrence.id else { return false }
            current.pendingOccurrence = nil
            current.lastStatus = .failed
            current.updatedAt = now
            Self.resyncNextRun(&current, after: now)
            return true
        }
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

    /// A thread target's agent comes from the thread itself; only a `newThread` target has to
    /// remember the one the schedule was created with.
    private func resolveAttemptTarget(
        schedule: Schedule, occurrence: ScheduleOccurrence
    ) async -> RunTarget? {
        guard case let .newThread(cwd, namePattern) = schedule.target else {
            return await resolve(schedule.target, agent: schedule.agent)
        }
        let agent = schedule.agent ?? .pi
        if let threadID = occurrence.threadId, !threadID.isEmpty,
           let threadPath = occurrence.threadPath, !threadPath.isEmpty {
            let standardizedPath = URL(fileURLWithPath: threadPath).standardizedFileURL.path
            let canResume: Bool
            if agent == .codex {
                canResume = CodexProtocolAdapter.threadID(
                    fromRolloutPath: URL(fileURLWithPath: standardizedPath)
                ) == threadID
            } else {
                canResume = Self.isParseableTranscript(
                    at: standardizedPath, expectedID: threadID, agent: agent, cwd: cwd
                )
            }
            if canResume {
                return .existingThread(
                    threadId: threadID, path: standardizedPath, cwd: cwd, agent: agent
                )
            }
        }
        guard !cwd.isEmpty else { return nil }
        return .newThread(cwd: cwd, namePattern: namePattern, agent: agent)
    }

    private func resolve(_ target: ScheduleTarget, agent: AgentKind?) async -> RunTarget? {
        switch target {
        case let .existingThread(threadId):
            do {
                guard let thread = try await threadStore.resolveForMutation(idOrPath: threadId) else {
                    return nil
                }
                return .existingThread(
                    threadId: thread.id, path: thread.path, cwd: thread.cwd, agent: thread.agent
                )
            } catch {
                logger.warn("Schedule target \(threadId) could not be resolved safely: \(error)")
                return nil
            }
        case let .newThread(cwd, namePattern):
            guard !cwd.isEmpty else { return nil }
            return .newThread(cwd: cwd, namePattern: namePattern, agent: agent ?? .pi)
        case .other:
            return nil
        }
    }

    private static func isParseableTranscript(
        at path: String, expectedID: String, agent: AgentKind, cwd: String
    ) -> Bool {
        guard let thread = try? SessionThreadParser.thread(
            at: URL(fileURLWithPath: path), transcoder: .make(for: agent)
        ) else { return false }
        return thread.id == expectedID
            && thread.cwd == URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    private func makeJob(
        id: String, schedule: Schedule, trigger: RunTrigger, queuedAt: Date,
        target: RunTarget
    ) -> RunJob {
        return RunJob(
            id: id, scheduleId: schedule.id, trigger: trigger, target: target,
            prompt: schedule.prompt, mode: schedule.mode,
            timeoutSeconds: schedule.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
            queuedAt: queuedAt
        )
    }

    private func createdThreadCallback(
        forFreshAgent agent: AgentKind?, runID: String
    ) -> (@Sendable (_ threadID: String, _ path: String) async -> Void)? {
        guard let agent else { return nil }
        return { [weak self] threadID, path in
            guard let self else { return }
            if await self.publishCreatedThread(
                threadID: threadID, path: path, agent: agent, running: true,
                waitDespiteCancellation: false
            ) {
                await self.markCreatedThreadPublished(runID: runID)
            }
        }
    }

    private func markCreatedThreadPublished(runID: String) {
        publishedCreatedThreadRunIDs.insert(runID)
    }

    /// The ready callback normally publishes before execution continues. Completion is the
    /// idempotent fallback for both pre-acceptance failures and a ready callback whose bounded
    /// transcript wait lost a race with the writer. It runs after the terminal Run event, so a
    /// recovered thread must be presented idle.
    private func recoverCreatedThreadAtCompletion(
        runID: String, freshAgent agent: AgentKind?, outcome: RunOutcome
    ) async -> FreshThreadPublication {
        if publishedCreatedThreadRunIDs.remove(runID) != nil {
            if let path = outcome.resolvedThreadPath, !path.isEmpty {
                await threadStore.markTranscriptSettled(path: path)
            }
            return .published
        }
        guard let agent,
              let threadID = outcome.resolvedThreadId, !threadID.isEmpty,
              let path = outcome.resolvedThreadPath, !path.isEmpty else {
            return .notRequired
        }
        if await publishCreatedThread(
            threadID: threadID, path: path, agent: agent, running: false,
            waitDespiteCancellation: true
        ) {
            return .published
        }
        return Self.hasMaterializedTranscript(at: path) ? .failed : .unavailable
    }

    private func publishCreatedThread(
        threadID: String, path: String, agent: AgentKind, running: Bool,
        waitDespiteCancellation: Bool
    ) async -> Bool {
        do {
            let url = URL(fileURLWithPath: path)
            var thread: PatchworkThread
            if waitDespiteCancellation {
                thread = try await Task.detached {
                    try await ThreadCreationService.waitForPersistedThread(
                        at: url, expectedID: threadID, agent: agent
                    )
                }.value
            } else {
                thread = try await ThreadCreationService.waitForPersistedThread(
                    at: url, expectedID: threadID, agent: agent
                )
            }
            thread.agent = agent
            try await threadStore.recordManagedThread(path: thread.path)
            thread = await threadStore.presentCreatedThread(
                thread, runningOverride: running
            )
            bus.publish(.thread(thread))
            return true
        } catch {
            logger.warn(
                "Created scheduled thread \(threadID), but could not publish its transcript: \(error)"
            )
            return false
        }
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

    @discardableResult
    private func record(_ run: Run) async -> Bool {
        let persisted = await runHistoryStore.record(run)
        bus.publish(.run(run))
        return persisted
    }

    private static func preallocatedFreshIdentity(
        target: ScheduleTarget, agent: AgentKind
    ) -> (id: String, path: String?)? {
        guard case let .newThread(cwd, _) = target else { return nil }
        switch agent {
        case .pi:
            return (UUID().uuidString.lowercased(), nil)
        case .claude:
            let id = UUID().uuidString.lowercased()
            return (
                id,
                ClaudeProtocolAdapter.transcriptPath(
                    sessionID: id, cwd: URL(fileURLWithPath: cwd)
                )
            )
        case .codex:
            return nil
        }
    }
}
