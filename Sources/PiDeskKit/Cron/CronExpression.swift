import Foundation

public enum CronParseError: Error, LocalizedError, Equatable, Sendable {
    case wrongFieldCount(found: Int)
    case invalidField(name: String, token: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .wrongFieldCount(found):
            "Cron expressions need exactly 5 fields (minute hour day-of-month month day-of-week); found \(found)."
        case let .invalidField(name, token, reason):
            "Invalid \(name) field \"\(token)\": \(reason)."
        }
    }
}

/// A standard 5-field cron expression (`minute hour day-of-month month day-of-week`), parsed
/// and validated once so an unparseable schedule is rejected at creation time instead of
/// silently never firing. No third-party dependency: field parsing is hand-rolled, and
/// `nextDate(after:in:)` walks forward through `Calendar` (so month length, leap years, and DST
/// are all handled the way the platform itself defines them) rather than reimplementing
/// calendar math.
public struct CronExpression: Sendable, Equatable {
    public let source: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    /// Cron's day-of-month/day-of-week interaction is defined in terms of the literal text, not
    /// the resulting set: a field only counts as unrestricted when it is written as exactly `*`.
    /// `*/1` expands to the same set but still participates in the OR below, matching vixie-cron.
    let domIsWildcard: Bool
    let dowIsWildcard: Bool

    public init(parsing expression: String) throws {
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { throw CronParseError.wrongFieldCount(found: fields.count) }

        let (minutes, _) = try Self.parseField(fields[0], spec: .minute)
        let (hours, _) = try Self.parseField(fields[1], spec: .hour)
        let (daysOfMonth, domWildcard) = try Self.parseField(fields[2], spec: .dayOfMonth)
        let (months, _) = try Self.parseField(fields[3], spec: .month)
        let (daysOfWeek, dowWildcard) = try Self.parseField(fields[4], spec: .dayOfWeek)

        self.source = expression
        self.minutes = minutes
        self.hours = hours
        self.daysOfMonth = daysOfMonth
        self.months = months
        self.daysOfWeek = daysOfWeek
        domIsWildcard = domWildcard
        dowIsWildcard = dowWildcard
    }

    /// The first instant strictly after `after` that matches, evaluated in `timeZone` so "9am
    /// Monday" means the same wall-clock moment across a DST transition. `nil` means no match
    /// within a 5-year search horizon — for any expression a person would plausibly write, that
    /// is equivalent to "never" (e.g. day-of-month 31 combined with month February) rather than
    /// a real omission, so callers should treat it the same as "this schedule cannot fire".
    public func nextDate(after: Date, in timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Truncate down to the start of `after`'s minute by pure epoch arithmetic, not by
        // reconstructing a Date from extracted components. A minute boundary is timezone- and
        // DST-independent (every real-world transition lands exactly on one), so this is exact,
        // and it sidesteps `Calendar`'s components -> Date direction entirely, which is the
        // direction that is ambiguous near a fall-back transition (see the note below).
        let truncatedEpoch = (after.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let startOfMinute = Date(timeIntervalSinceReferenceDate: truncatedEpoch)
        guard var candidate = calendar.date(byAdding: .minute, value: 1, to: startOfMinute) else { return nil }
        guard let horizon = calendar.date(byAdding: .year, value: 5, to: after) else { return nil }

        var iterations = 0
        let maxIterations = 200_000

        while candidate < horizon {
            iterations += 1
            if iterations > maxIterations { return nil }

            let components = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month = components.month, let day = components.day, let hour = components.hour,
                  let minute = components.minute, let weekday = components.weekday else { return nil }
            // Calendar weekday is 1...7 (Sunday...Saturday); cron day-of-week is 0...6 (Sunday...Saturday).
            let cronWeekday = (weekday - 1) % 7

            if !months.contains(month) {
                guard let next = Self.startOfNextMonth(candidate, calendar: calendar) else { return nil }
                candidate = next
                continue
            }
            if !matchesDay(day: day, weekday: cronWeekday) {
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) else { return nil }
                candidate = next
                continue
            }
            if !hours.contains(hour) {
                // A pure relative offset from `candidate`, not a reconstruction from components:
                // see the note on `startOfNextMonth` below for why that distinction matters across
                // a fall-back transition.
                guard let next = calendar.date(byAdding: .minute, value: 60 - minute, to: candidate) else { return nil }
                candidate = next
                continue
            }
            if !minutes.contains(minute) {
                guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
                candidate = next
                continue
            }
            return candidate
        }
        return nil
    }

    /// Day match uses vixie-cron's OR rule: when both day-of-month and day-of-week are
    /// restricted, either matching is enough (e.g. "1st of the month, or any Friday").
    private func matchesDay(day: Int, weekday: Int) -> Bool {
        let domMatch = daysOfMonth.contains(day)
        let dowMatch = daysOfWeek.contains(weekday)
        if domIsWildcard && dowIsWildcard { return true }
        if domIsWildcard { return dowMatch }
        if dowIsWildcard { return domMatch }
        return domMatch || dowMatch
    }

    /// Deliberately avoids `Calendar.date(bySetting:value:of:)`/`date(bySettingHour:...)`:
    /// both search *forward* to the next date whose component equals the target when the
    /// current value is not judged to already match, and empirically that judgement is not
    /// reliable across an ambiguous fall-back hour (a value can be "reset" to the transition's
    /// earlier occurrence instead of being treated as already matching). Every jump here is
    /// instead a relative `byAdding` offset from `candidate` itself — extraction of components
    /// from a known instant is always well-defined; it is only *reconstruction* of an instant
    /// from components that is ambiguous near a transition, so reconstruction is avoided
    /// entirely once the search is under way.
    private static func startOfNextMonth(_ date: Date, calendar: Calendar) -> Date? {
        let day = calendar.component(.day, from: date)
        guard let firstOfThisMonth = calendar.date(byAdding: .day, value: 1 - day, to: calendar.startOfDay(for: date)) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: firstOfThisMonth)
    }

    // MARK: - Field parsing

    private struct FieldSpec {
        let name: String
        let range: ClosedRange<Int>
        let names: [String: Int]
        let normalize: (Int) -> Int

        static let minute = FieldSpec(name: "minute", range: 0...59, names: [:], normalize: { $0 })
        static let hour = FieldSpec(name: "hour", range: 0...23, names: [:], normalize: { $0 })
        static let dayOfMonth = FieldSpec(name: "day-of-month", range: 1...31, names: [:], normalize: { $0 })
        static let month = FieldSpec(
            name: "month", range: 1...12,
            names: ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12],
            normalize: { $0 }
        )
        // 0 and 7 both mean Sunday; normalized to 0 so set membership only ever needs one value.
        static let dayOfWeek = FieldSpec(
            name: "day-of-week", range: 0...7,
            names: ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6],
            normalize: { $0 == 7 ? 0 : $0 }
        )
    }

    /// Returns the matching values and whether the field was written as exactly `*`.
    private static func parseField(_ text: String, spec: FieldSpec) throws -> (Set<Int>, Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CronParseError.invalidField(name: spec.name, token: text, reason: "empty field") }
        if trimmed == "*" { return (Set(spec.range), true) }

        var values: Set<Int> = []
        for rawItem in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let item = String(rawItem)
            guard !item.isEmpty else { throw CronParseError.invalidField(name: spec.name, token: trimmed, reason: "empty list item") }
            values.formUnion(try parseItem(item, spec: spec))
        }
        return (values, false)
    }

    private static func parseItem(_ item: String, spec: FieldSpec) throws -> Set<Int> {
        let stepParts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard stepParts.count == 1 || stepParts.count == 2 else {
            throw CronParseError.invalidField(name: spec.name, token: item, reason: "malformed step expression")
        }
        var step = 1
        if stepParts.count == 2 {
            guard let parsedStep = Int(stepParts[1]), parsedStep > 0 else {
                throw CronParseError.invalidField(name: spec.name, token: item, reason: "step must be a positive integer")
            }
            step = parsedStep
        }

        let rangePart = stepParts[0]
        let bounds: ClosedRange<Int>
        if rangePart == "*" {
            bounds = spec.range
        } else if rangePart.contains("-") {
            let rangeParts = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard rangeParts.count == 2 else {
                throw CronParseError.invalidField(name: spec.name, token: item, reason: "malformed range")
            }
            let start = try parseValue(rangeParts[0], spec: spec, item: item)
            let end = try parseValue(rangeParts[1], spec: spec, item: item)
            guard start <= end else {
                throw CronParseError.invalidField(name: spec.name, token: item, reason: "range start must not be after its end")
            }
            bounds = start...end
        } else if stepParts.count == 2 {
            // "value/step" (no explicit range end): vixie-cron runs from `value` to the field's max.
            let start = try parseValue(rangePart, spec: spec, item: item)
            bounds = start...spec.range.upperBound
        } else {
            return [spec.normalize(try parseValue(rangePart, spec: spec, item: item))]
        }

        var result: Set<Int> = []
        var current = bounds.lowerBound
        while current <= bounds.upperBound {
            result.insert(spec.normalize(current))
            current += step
        }
        return result
    }

    private static func parseValue(_ raw: String, spec: FieldSpec, item: String) throws -> Int {
        if let named = spec.names[raw.uppercased()] { return named }
        guard let value = Int(raw) else {
            throw CronParseError.invalidField(name: spec.name, token: item, reason: "\"\(raw)\" is not a number")
        }
        guard spec.range.contains(value) else {
            throw CronParseError.invalidField(name: spec.name, token: item, reason: "\(value) is outside \(spec.range.lowerBound)-\(spec.range.upperBound)")
        }
        return value
    }
}
