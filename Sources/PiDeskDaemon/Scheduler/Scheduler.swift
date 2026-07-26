import Foundation
import PiDeskKit

/// The effectful shell around `ScheduleEngine`: one poll loop (never one timer per schedule),
/// wired to the real store/queue/thread-lookup. Every decision is still made by the pure engine;
/// this actor's job is fetching schedules, resolving targets, persisting the result, publishing
/// SSE events, and enqueueing onto `RunQueue`.
actor Scheduler {
    private let scheduleStore: ScheduleStore
    private let runQueue: RunQueue
    private let threadStore: ThreadStore
    private let leaseStore: LeaseStore
    private let bus: EventBus
    private let logger: DaemonLogger
    private let pollInterval: TimeInterval
    private var loopTask: Task<Void, Never>?
    /// Set once, read by `/v1/health`; disabling schedules (a future `daemon.json` knob) would
    /// flip this instead of stopping the loop, so `nextRunAt` bookkeeping stays accurate.
    private(set) var enabled: Bool

    init(
        scheduleStore: ScheduleStore,
        runQueue: RunQueue,
        threadStore: ThreadStore,
        leaseStore: LeaseStore = LeaseStore(),
        bus: EventBus,
        logger: DaemonLogger,
        pollInterval: TimeInterval = 1,
        enabled: Bool = true
    ) {
        self.scheduleStore = scheduleStore
        self.runQueue = runQueue
        self.threadStore = threadStore
        self.leaseStore = leaseStore
        self.bus = bus
        self.logger = logger
        self.pollInterval = pollInterval
        self.enabled = enabled
    }

    func start() {
        guard loopTask == nil else { return }
        logger.info("Scheduler started (poll interval \(pollInterval)s).")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                // `pollInterval` is an immutable `Sendable` `let`, so this reads synchronously
                // without hopping onto the actor.
                try? await Task.sleep(nanoseconds: UInt64(max(self.pollInterval, 0.1) * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One pass over every schedule. Public (not just the internal loop) so tests can drive it
    /// deterministically with an injected `now` instead of racing a real timer.
    @discardableResult
    func tick(now: Date = Date()) async -> Int {
        guard enabled else { return 0 }
        let schedules = await scheduleStore.all()
        var busy = await runQueue.activeThreadIDs()
        busy.formUnion(await runQueue.pendingThreadIDs())
        // A thread the app has leased must never receive a scheduled prompt from the daemon.
        busy.formUnion(await leaseStore.leasedThreadIDs(now: now))
        var fired = 0

        for schedule in schedules {
            guard let decision = ScheduleEngine.evaluate(schedule: schedule, now: now, isThreadBusy: { busy.contains($0) }) else { continue }

            if decision.updatedSchedule != schedule, let saved = try? await scheduleStore.upsert(decision.updatedSchedule) {
                bus.publish(.schedule(saved))
            }

            switch decision.action {
            case .none:
                continue
            case let .skip(reason):
                let job = await makeJob(scheduleId: schedule.id, target: schedule.target, prompt: schedule.prompt, mode: schedule.mode, timeoutSeconds: schedule.policy.timeoutSeconds, now: now)
                await runQueue.recordSkipped(job, reason: reason)
            case let .fire(target, prompt, mode):
                guard let runTarget = await resolve(target) else {
                    logger.error("Schedule \(schedule.id) could not resolve its target thread; recording a failed attempt.")
                    let job = await makeJob(scheduleId: schedule.id, target: target, prompt: prompt, mode: mode, timeoutSeconds: schedule.policy.timeoutSeconds, now: now)
                    await runQueue.recordSkipped(job, reason: "Could not resolve the schedule's target thread.")
                    continue
                }
                if let threadID = runTarget.existingThreadID { busy.insert(threadID) } // predictive within this tick
                let job = RunJob(
                    id: "run_\(UUID().uuidString)", scheduleId: schedule.id, trigger: .schedule,
                    target: runTarget, prompt: prompt, mode: mode,
                    timeoutSeconds: schedule.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
                    queuedAt: now
                )
                await runQueue.enqueue(job)
                fired += 1
            }
        }
        return fired
    }

    /// `POST /v1/schedules/{id}/run`: fires immediately regardless of `nextRunAt`, still subject
    /// to the queue's own per-thread exclusivity (it waits its turn rather than stacking), and
    /// updates `lastRunAt`/`lastStatus` without disturbing the schedule's own automatic cadence.
    func runNow(scheduleId: String) async throws -> String {
        guard let schedule = await scheduleStore.get(id: scheduleId) else {
            throw DaemonHTTPError.notFound("Schedule \(scheduleId)")
        }
        guard let runTarget = await resolve(schedule.target) else {
            throw DaemonHTTPError.badRequest(code: "unresolvable_target", message: "Could not resolve this schedule's target thread.")
        }
        let job = RunJob(
            id: "run_\(UUID().uuidString)", scheduleId: schedule.id, trigger: .manual,
            target: runTarget, prompt: schedule.prompt, mode: schedule.mode,
            timeoutSeconds: schedule.policy.timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
            queuedAt: Date()
        )
        await runQueue.enqueue(job)

        var updated = schedule
        updated.lastRunAt = Date()
        updated.updatedAt = Date()
        if let saved = try? await scheduleStore.upsert(updated) { bus.publish(.schedule(saved)) }
        return job.id
    }

    /// Used by the create/update handlers so a fresh `POST /v1/schedules` response already shows
    /// a correct `nextRunAt` instead of `nil` until the next poll tick fills it in.
    func computeInitialNextRunAt(for trigger: ScheduleTrigger) -> Date? {
        TriggerEngine.nextRunAt(for: trigger, after: Date(), lastRunAt: nil)
    }

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

    /// A `Run` record for an outcome that never reaches `RunQueue`'s normal start/finish path.
    private func makeJob(scheduleId: String, target: ScheduleTarget, prompt: String, mode: String?, timeoutSeconds: Int?, now: Date) async -> RunJob {
        let runTarget = await resolve(target) ?? .newThread(cwd: "", namePattern: nil)
        return RunJob(
            id: "run_\(UUID().uuidString)", scheduleId: scheduleId, trigger: .schedule,
            target: runTarget, prompt: prompt, mode: mode,
            timeoutSeconds: timeoutSeconds ?? ScheduleEngine.defaultTimeoutSeconds,
            queuedAt: now
        )
    }
}
