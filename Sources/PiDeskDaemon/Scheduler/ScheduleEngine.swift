import Foundation
import PiDeskKit

/// The scheduler's decision logic, kept entirely pure (no I/O, no actor, a plain synchronous
/// `isThreadBusy` closure) specifically so it can be tested exhaustively \u2014 sleep/wake, quiet
/// hours, catch-up, skip-if-running \u2014 without a running daemon, a real clock, or a fake
/// process. `Scheduler` is the thin, effectful shell around this.
enum ScheduleEngine {
    enum Action: Equatable {
        /// Enqueue a run against `target`. `updatedSchedule.nextRunAt`/`lastRunAt` are already
        /// advanced; `lastStatus` is left for the caller to fill in once the run finishes.
        case fire(target: ScheduleTarget, prompt: String, mode: String?)
        /// Record a skipped run (the target thread was already busy and `skipIfRunning` is on).
        case skip(reason: String)
        /// Nothing happens this tick: heartbeat found the thread busy or quiet hours are active.
        /// No `Run` is recorded.
        case none
    }

    struct Decision {
        var updatedSchedule: Schedule
        var action: Action
    }

    static let defaultTimeoutSeconds = 3_600
    static let maximumTimeoutSeconds = 366 * 86_400

    static func boundedTimeoutSeconds(_ seconds: Int) -> Int {
        min(max(1, seconds), maximumTimeoutSeconds)
    }

    /// `nil` means "nothing to do for this schedule right now": disabled, not yet due, or an
    /// unresolvable trigger kind (rejected at creation time; this is defense in depth).
    static func evaluate(schedule: Schedule, now: Date, isThreadBusy: (String) -> Bool) -> Decision? {
        guard schedule.enabled else { return nil }
        if case .other = schedule.trigger { return nil }

        let due = schedule.nextRunAt ?? TriggerEngine.nextRunAt(for: schedule.trigger, after: schedule.updatedAt, lastRunAt: schedule.lastRunAt)
        guard let due else { return nil }
        guard due <= now else {
            // Not due yet. Only worth a write if `nextRunAt` had never been computed at all.
            guard schedule.nextRunAt == nil else { return nil }
            return Decision(updatedSchedule: applying(schedule, nextRunAt: due), action: .none)
        }

        let isHeartbeat: Bool = { if case .heartbeat = schedule.trigger { return true }; return false }()
        let threadID = schedule.target.existingThreadID

        // Heartbeat while busy: silent, no history entry, no "missed" bookkeeping \u2014 it simply
        // tries again next period.
        if isHeartbeat, let threadID, isThreadBusy(threadID) {
            let next = TriggerEngine.nextRunAt(for: schedule.trigger, after: now, lastRunAt: schedule.lastRunAt)
            return Decision(updatedSchedule: applying(schedule, nextRunAt: next), action: .none)
        }

        // Quiet hours: defer without recording; `nextRunAt` becomes quiet-hours-end, so the very
        // next tick after the window closes re-evaluates this occurrence from scratch.
        if !isHeartbeat, let quietHours = schedule.policy.quietHours, QuietHoursEvaluator.isActive(quietHours, at: now) {
            let next = QuietHoursEvaluator.nextAllowedInstant(quietHours, after: now)
            return Decision(updatedSchedule: applying(schedule, nextRunAt: next), action: .none)
        }

        // Globally coalesce however many times were missed while Pi Desktop was closed: fire one
        // occurrence, then jump directly to the first future grid point. `once` naturally has no
        // next point, and heartbeat resumes from the current availability window.
        let next = TriggerEngine.nextRunAt(for: schedule.trigger, after: now, lastRunAt: due)

        if let threadID, isThreadBusy(threadID), schedule.policy.skipIfRunning {
            let updated = applying(schedule, nextRunAt: next, lastRunAt: due, lastStatus: .skipped)
            return Decision(updatedSchedule: updated, action: .skip(reason: "Thread was already running."))
        }

        // Either idle, or busy with `skipIfRunning == false` (the queue itself still guarantees
        // it will not run concurrently with whatever is already using that thread).
        let updated = applying(schedule, nextRunAt: next, lastRunAt: due, clearLastStatus: true)
        return Decision(updatedSchedule: updated, action: .fire(target: schedule.target, prompt: schedule.prompt, mode: schedule.mode))
    }

    /// `lastStatus`/`clearLastStatus` are deliberately two separate parameters rather than one
    /// `RunStatus??`: a bare `nil` argument cannot distinguish "leave it alone" from "set it to
    /// nil" against a doubly-optional parameter (both resolve to the same value), so a real
    /// tri-state needs a real second signal instead of relying on Optional-of-Optional.
    private static func applying(
        _ schedule: Schedule,
        nextRunAt: Date?,
        lastRunAt: Date? = nil,
        clearLastStatus: Bool = false,
        lastStatus: RunStatus? = nil
    ) -> Schedule {
        var updated = schedule
        updated.nextRunAt = nextRunAt
        if let lastRunAt { updated.lastRunAt = lastRunAt }
        if clearLastStatus || lastStatus != nil { updated.lastStatus = lastStatus }
        updated.updatedAt = Date()
        return updated
    }
}
