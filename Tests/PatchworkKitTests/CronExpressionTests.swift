import XCTest
@testable import PatchworkKit

final class CronExpressionTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ iso: String, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let value = formatter.date(from: iso) else { fatalError("bad fixture date \(iso)") }
        return value
    }

    private func components(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// `DateComponents` extracted with a partial unit set is Equatable, but tuples of `Int?`
    /// are not (no arity-generic `Equatable` conformance for tuples), so multi-field assertions
    /// compare through this small stand-in instead.
    private struct Stamp: Equatable, CustomStringConvertible {
        var year: Int?
        var month: Int?
        var day: Int?
        var hour: Int?
        var minute: Int?
        var description: String { "\(year.map(String.init) ?? "-")-\(month.map(String.init) ?? "-")-\(day.map(String.init) ?? "-") \(hour.map(String.init) ?? "-"):\(minute.map(String.init) ?? "-")" }
    }

    private func stamp(_ date: Date, _ timeZone: TimeZone, year: Bool = false, month: Bool = false, day: Bool = false, hour: Bool = false, minute: Bool = false) -> Stamp {
        let comps = components(date, timeZone)
        return Stamp(
            year: year ? comps.year : nil,
            month: month ? comps.month : nil,
            day: day ? comps.day : nil,
            hour: hour ? comps.hour : nil,
            minute: minute ? comps.minute : nil
        )
    }

    // MARK: - Parsing

    func testRejectsWrongFieldCount() {
        XCTAssertThrowsError(try CronExpression(parsing: "* * * *")) {
            guard case CronParseError.wrongFieldCount(let found) = $0 else { return XCTFail("wrong error: \($0)") }
            XCTAssertEqual(found, 4)
        }
        XCTAssertThrowsError(try CronExpression(parsing: "* * * * * *"))
        XCTAssertThrowsError(try CronExpression(parsing: ""))
    }

    func testRejectsOutOfRangeValues() {
        XCTAssertThrowsError(try CronExpression(parsing: "60 * * * *"), "minute 60")
        XCTAssertThrowsError(try CronExpression(parsing: "* 24 * * *"), "hour 24")
        XCTAssertThrowsError(try CronExpression(parsing: "* * 0 * *"), "day-of-month 0")
        XCTAssertThrowsError(try CronExpression(parsing: "* * 32 * *"), "day-of-month 32")
        XCTAssertThrowsError(try CronExpression(parsing: "* * * 0 *"), "month 0")
        XCTAssertThrowsError(try CronExpression(parsing: "* * * 13 *"), "month 13")
        XCTAssertThrowsError(try CronExpression(parsing: "* * * * 8"), "day-of-week 8")
    }

    func testAcceptsDayOfWeekSevenAsSunday() throws {
        XCTAssertNoThrow(try CronExpression(parsing: "0 0 * * 7"))
    }

    func testRejectsMalformedSteps() {
        XCTAssertThrowsError(try CronExpression(parsing: "*/0 * * * *"), "zero step")
        XCTAssertThrowsError(try CronExpression(parsing: "*/-5 * * * *"), "negative step")
        XCTAssertThrowsError(try CronExpression(parsing: "*/abc * * * *"), "non-numeric step")
        XCTAssertThrowsError(try CronExpression(parsing: "1/2/3 * * * *"), "too many slashes")
    }

    func testRejectsMalformedRanges() {
        XCTAssertThrowsError(try CronExpression(parsing: "10- * * * *"), "dangling range")
        XCTAssertThrowsError(try CronExpression(parsing: "-10 * * * *"), "dangling range")
        XCTAssertThrowsError(try CronExpression(parsing: "20-10 * * * *"), "start after end")
    }

    func testRejectsNonNumericGarbage() {
        XCTAssertThrowsError(try CronExpression(parsing: "foo bar baz qux zap"))
    }

    func testRejectsEmptyListItems() {
        XCTAssertThrowsError(try CronExpression(parsing: "1,,2 * * * *"))
    }

    func testAcceptsNamedMonthsAndWeekdaysCaseInsensitively() throws {
        XCTAssertNoThrow(try CronExpression(parsing: "0 9 * JAN,JUL MON-FRI"))
        XCTAssertNoThrow(try CronExpression(parsing: "0 9 * jan,jul mon-fri"))
    }

    func testRejectsReversedNamedRange() {
        // FRI(5)-MON(1): wraparound ranges are not supported, matching the standard 5-field form.
        XCTAssertThrowsError(try CronExpression(parsing: "0 9 * * FRI-MON"))
    }

    func testToleratesExtraWhitespaceBetweenFields() throws {
        let expr = try CronExpression(parsing: "0\t9   *  *\t*")
        let next = expr.nextDate(after: date("2026-01-01 00:00", timeZone: utc), in: utc)
        XCTAssertEqual(components(next!, utc).hour, 9)
    }

    // MARK: - Basic evaluation

    func testEveryMinuteAdvancesByExactlyOneMinuteFromAnySecond() throws {
        let expr = try CronExpression(parsing: "* * * * *")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let after = calendar.date(byAdding: .second, value: 47, to: date("2026-03-01 10:00", timeZone: utc))!
        let next = expr.nextDate(after: after, in: utc)!
        XCTAssertEqual(components(next, utc).minute, 1)
        XCTAssertEqual(calendar.component(.second, from: next), 0)
    }

    func testNeverReturnsTheSameMinuteAsAfterEvenOnExactBoundary() throws {
        let expr = try CronExpression(parsing: "0 9 * * *")
        let exact = date("2026-03-01 09:00", timeZone: utc)
        let next = expr.nextDate(after: exact, in: utc)!
        XCTAssertGreaterThan(next, exact)
        XCTAssertEqual(components(next, utc).day, 2)
    }

    func testDailyAtSpecificTime() throws {
        let expr = try CronExpression(parsing: "30 9 * * *")
        let next = expr.nextDate(after: date("2026-03-01 08:00", timeZone: utc), in: utc)!
        XCTAssertEqual(stamp(next, utc, year: true, month: true, day: true, hour: true, minute: true), Stamp(year: 2026, month: 3, day: 1, hour: 9, minute: 30))
    }

    func testStepMinutes() throws {
        let expr = try CronExpression(parsing: "*/15 * * * *")
        let next = expr.nextDate(after: date("2026-03-01 10:05", timeZone: utc), in: utc)!
        XCTAssertEqual(components(next, utc).minute, 15)
    }

    func testStepWithoutRangeRunsFromValueToFieldMax() throws {
        // "5/15" minute means 5,20,35,50 — value to field max, matching vixie-cron.
        let expr = try CronExpression(parsing: "5/15 * * * *")
        let next = expr.nextDate(after: date("2026-03-01 10:06", timeZone: utc), in: utc)!
        XCTAssertEqual(components(next, utc).minute, 20)
    }

    func testCommaSeparatedList() throws {
        let expr = try CronExpression(parsing: "0 9,13,18 * * *")
        var after = date("2026-03-01 00:00", timeZone: utc)
        for expectedHour in [9, 13, 18] {
            let next = expr.nextDate(after: after, in: utc)!
            XCTAssertEqual(components(next, utc).hour, expectedHour)
            after = next
        }
    }

    func testWeekdayRange() throws {
        // 9am Mon-Fri starting from a Saturday must land on Monday.
        let expr = try CronExpression(parsing: "0 9 * * 1-5")
        let saturday = date("2026-02-28 10:00", timeZone: utc) // 2026-02-28 is a Saturday
        let next = expr.nextDate(after: saturday, in: utc)!
        XCTAssertEqual(stamp(next, utc, month: true, day: true, hour: true), Stamp(month: 3, day: 2, hour: 9)) // following Monday
    }

    // MARK: - Day-of-month / day-of-week interaction

    func testBothRestrictedUsesOrSemantics() throws {
        // "1st of the month, or any Friday" at 09:00.
        let expr = try CronExpression(parsing: "0 9 1 * 5")
        // 2026-03-02 is a Monday, neither the 1st nor a Friday from there forward until...
        let start = date("2026-03-02 10:00", timeZone: utc)
        let next = expr.nextDate(after: start, in: utc)!
        // 2026-03-06 is the first Friday on/after March 2; it comes before April 1st.
        XCTAssertEqual(stamp(next, utc, month: true, day: true), Stamp(month: 3, day: 6))
    }

    func testDayOfMonthWildcardLeavesOnlyDayOfWeekRestriction() throws {
        let expr = try CronExpression(parsing: "0 9 * * 5") // every Friday
        let start = date("2026-03-02 10:00", timeZone: utc) // Monday
        let next = expr.nextDate(after: start, in: utc)!
        XCTAssertEqual(components(next, utc).day, 6)
    }

    func testDayOfWeekWildcardLeavesOnlyDayOfMonthRestriction() throws {
        let expr = try CronExpression(parsing: "0 9 15 * *") // 15th of every month
        let start = date("2026-03-02 10:00", timeZone: utc)
        let next = expr.nextDate(after: start, in: utc)!
        XCTAssertEqual(components(next, utc).day, 15)
    }

    func testStarSlashOneIsStillRestrictedForOrSemantics() throws {
        // "*/1" is not the literal "*", so it still participates in the OR with day-of-week,
        // even though the value set it produces (every day) is identical to a wildcard.
        let everyDayOr = try CronExpression(parsing: "0 9 */1 * 5")
        let fridayOnly = try CronExpression(parsing: "0 9 * * 5")
        let start = date("2026-03-02 10:00", timeZone: utc) // Monday
        // "*/1" is restricted (not the literal "*"), even though it expands to every day, so it
        // OR's with Friday and matches the very next day. A true wildcard "*" instead drops out
        // of the match entirely, leaving only "every Friday".
        XCTAssertEqual(everyDayOr.nextDate(after: start, in: utc), date("2026-03-03 09:00", timeZone: utc))
        XCTAssertEqual(fridayOnly.nextDate(after: start, in: utc), date("2026-03-06 09:00", timeZone: utc))
    }

    // MARK: - Month-end and leap years

    func test31stSkipsShortMonths() throws {
        let expr = try CronExpression(parsing: "0 0 31 * *")
        let next = expr.nextDate(after: date("2026-02-01 00:00", timeZone: utc), in: utc)!
        // February has no 31st; March does.
        XCTAssertEqual(stamp(next, utc, month: true, day: true), Stamp(month: 3, day: 31))
    }

    func testFebruary30thNeverMatchesWithinHorizon() throws {
        let expr = try CronExpression(parsing: "0 0 30 2 *")
        XCTAssertNil(expr.nextDate(after: date("2026-01-01 00:00", timeZone: utc), in: utc))
    }

    func testLeapDayFindsTheNextLeapYear() throws {
        let expr = try CronExpression(parsing: "0 0 29 2 *")
        // 2026-2027-2028: 2028 is the next leap year (2024 was; 2028 is next divisible-by-4).
        let next = expr.nextDate(after: date("2026-03-01 00:00", timeZone: utc), in: utc)!
        XCTAssertEqual(stamp(next, utc, year: true, month: true, day: true), Stamp(year: 2028, month: 2, day: 29))
    }

    // MARK: - DST (America/New_York)

    /// 2026-03-08 02:00 local clocks spring forward to 03:00; the 2 o'clock hour does not exist.
    func testSpringForwardDailyTimeUnaffectedByTheJumpStaysAtTheSameLocalHour() throws {
        let expr = try CronExpression(parsing: "0 9 * * *")
        let dayBefore = expr.nextDate(after: date("2026-03-07 00:00", timeZone: newYork), in: newYork)!
        let transitionDay = expr.nextDate(after: dayBefore, in: newYork)!
        XCTAssertEqual(components(dayBefore, newYork).day, 7)
        XCTAssertEqual(components(transitionDay, newYork).day, 8)
        // Both stay at local 09:00 even though the transition day itself is only 23 hours long.
        XCTAssertEqual(components(dayBefore, newYork).hour, 9)
        XCTAssertEqual(components(transitionDay, newYork).hour, 9)
        let gap = transitionDay.timeIntervalSince(dayBefore)
        XCTAssertEqual(gap, 23 * 3600, "the wall-clock day it crossed is 23 hours, not 24")
    }

    /// A time inside the skipped hour must not crash and must resolve to a real, later instant.
    func testSpringForwardSkippedHourResolvesToARealInstant() throws {
        let expr = try CronExpression(parsing: "30 2 * * *")
        let before = date("2026-03-07 12:00", timeZone: newYork)
        let next = expr.nextDate(after: before, in: newYork)!
        XCTAssertGreaterThan(next, before)
        // Whatever Calendar normalizes 02:30 (nonexistent) to, it must round-trip: asking again
        // from just before the result must not find an earlier match we skipped over.
        let earlier = next.addingTimeInterval(-1)
        let second = expr.nextDate(after: earlier, in: newYork)!
        XCTAssertEqual(second, next)
    }

    /// 2026-11-01 02:00 local clocks fall back to 01:00; 01:00-02:00 occurs twice.
    func testFallBackDailyTimeUnaffectedByTheRepeatedHourStaysAtTheSameLocalHour() throws {
        let expr = try CronExpression(parsing: "0 9 * * *")
        let dayBefore = expr.nextDate(after: date("2026-10-31 00:00", timeZone: newYork), in: newYork)!
        let transitionDay = expr.nextDate(after: dayBefore, in: newYork)!
        XCTAssertEqual(components(transitionDay, newYork).hour, 9)
        let gap = transitionDay.timeIntervalSince(dayBefore)
        XCTAssertEqual(gap, 25 * 3600, "the wall-clock day it crossed is 25 hours, not 24")
    }

    func testFallBackAmbiguousHourNeverGoesBackwardsAndReachesTheNextDay() throws {
        let expr = try CronExpression(parsing: "30 1 * * *")
        var cursor = date("2026-10-31 00:00", timeZone: newYork)
        var seenNovember2 = false
        for _ in 0..<4 {
            guard let next = expr.nextDate(after: cursor, in: newYork) else { break }
            XCTAssertGreaterThan(next, cursor)
            if components(next, newYork).day == 2, components(next, newYork).month == 11 { seenNovember2 = true }
            cursor = next
        }
        XCTAssertTrue(seenNovember2, "must reach Nov 2 within a few calls even with a repeated local hour on Nov 1")
    }

    // MARK: - Determinism / idempotence

    func testParsingIsDeterministicAndEquatable() throws {
        let a = try CronExpression(parsing: "0 9 * * 1-5")
        let b = try CronExpression(parsing: "0 9 * * 1-5")
        XCTAssertEqual(a, b)
    }
}
