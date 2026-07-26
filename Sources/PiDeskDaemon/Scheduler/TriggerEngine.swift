import Foundation
import PiDeskKit

/// Computes a trigger's next fire time strictly from wall clock and the trigger's own
/// definition \u2014 never from elapsed timer ticks \u2014 which is exactly what makes sleep/wake
/// survival free: whenever the scheduler next gets to look (immediately on wake, or up to one
/// poll interval later), it asks "what does the trigger say about `now`?" and gets the right
/// answer regardless of how long the daemon was actually asleep.
enum TriggerEngine {
    /// The first fire time strictly after `after`. `nil` means this trigger cannot fire again:
    /// a `once` that already ran, an unparseable cron expression, or an unrecognised trigger
    /// kind (rejected at creation time; this is defense in depth, not the primary guard).
    static func nextRunAt(for trigger: ScheduleTrigger, after: Date, lastRunAt: Date?) -> Date? {
        switch trigger {
        case let .once(at):
            return lastRunAt == nil ? at : nil

        case let .interval(everySeconds, startAt):
            return nextGridPoint(after: after, start: startAt ?? after, everySeconds: everySeconds)

        case let .cron(expression, timeZone):
            guard let parsed = try? CronExpression(parsing: expression) else { return nil }
            let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            return parsed.nextDate(after: after, in: zone)

        case let .heartbeat(everySeconds):
            // No fixed `startAt` in this trigger's schema; anchor on the last check (or `after`
            // itself, the first time), so a brand-new heartbeat schedule does not wait a full
            // period before its first idle check.
            return nextGridPoint(after: after, start: lastRunAt ?? after, everySeconds: everySeconds)

        case .other:
            return nil
        }
    }

    /// The smallest `start + N*everySeconds` that is strictly greater than `after`.
    private static func nextGridPoint(after: Date, start: Date, everySeconds: Int) -> Date? {
        guard everySeconds > 0 else { return nil }
        if after < start { return start }
        let elapsed = after.timeIntervalSince(start)
        let steps = (elapsed / Double(everySeconds)).rounded(.down) + 1
        return start.addingTimeInterval(steps * Double(everySeconds))
    }
}
