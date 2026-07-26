import Foundation
import PiDeskKit

/// Pure wall-clock evaluation of `SchedulePolicy.quietHours`. `from`/`to` are `HH:mm` in
/// `timeZone`; `to <= from` wraps past midnight, which is the normal case ("quiet 23:00\u201307:00").
enum QuietHoursEvaluator {
    static func isActive(_ quietHours: QuietHours, at date: Date) -> Bool {
        guard let zone = TimeZone(identifier: quietHours.timeZone),
              let fromMinutes = minutesSinceMidnight(quietHours.from),
              let toMinutes = minutesSinceMidnight(quietHours.to),
              fromMinutes != toMinutes else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return false }
        let nowMinutes = hour * 60 + minute

        if fromMinutes < toMinutes {
            return nowMinutes >= fromMinutes && nowMinutes < toMinutes
        }
        return nowMinutes >= fromMinutes || nowMinutes < toMinutes
    }

    /// The next instant, at or after `date`, that is outside quiet hours \u2014 `date` itself if
    /// quiet hours are not currently active.
    static func nextAllowedInstant(_ quietHours: QuietHours, after date: Date) -> Date {
        guard isActive(quietHours, at: date) else { return date }
        guard let zone = TimeZone(identifier: quietHours.timeZone), let toMinutes = minutesSinceMidnight(quietHours.to) else { return date }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = toMinutes / 60
        comps.minute = toMinutes % 60
        comps.second = 0
        guard let sameDayEnd = calendar.date(from: comps) else { return date.addingTimeInterval(60) }
        if sameDayEnd > date { return sameDayEnd }
        return calendar.date(byAdding: .day, value: 1, to: sameDayEnd) ?? date.addingTimeInterval(86_400)
    }

    private static func minutesSinceMidnight(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
