import XCTest
@testable import PiDeskCLI

final class CronExpressionTests: XCTestCase {
    func testAcceptsWeekdayMornings() throws {
        XCTAssertEqual(try CronExpression.validate("0 9 * * 1-5"), "0 9 * * 1-5")
    }

    func testAcceptsEveryFifteenMinutes() throws {
        XCTAssertNoThrow(try CronExpression.validate("*/15 * * * *"))
    }

    func testAcceptsNamedMonthsAndDays() throws {
        XCTAssertNoThrow(try CronExpression.validate("0 9 1 JAN-MAR MON,WED,FRI"))
    }

    func testAcceptsCommaList() throws {
        XCTAssertNoThrow(try CronExpression.validate("0,15,30,45 * * * *"))
    }

    func testAcceptsSundayAsSevenOrZero() throws {
        XCTAssertNoThrow(try CronExpression.validate("0 0 * * 7"))
        XCTAssertNoThrow(try CronExpression.validate("0 0 * * 0"))
    }

    func testRejectsWrongFieldCount() {
        XCTAssertThrowsError(try CronExpression.validate("0 9 * *"))
        XCTAssertThrowsError(try CronExpression.validate("0 9 * * * *"))
    }

    func testRejectsOutOfRangeMinute() {
        XCTAssertThrowsError(try CronExpression.validate("60 * * * *"))
    }

    func testRejectsOutOfRangeMonth() {
        XCTAssertThrowsError(try CronExpression.validate("0 0 1 13 *"))
    }

    func testRejectsGarbageToken() {
        XCTAssertThrowsError(try CronExpression.validate("bogus 9 * * *"))
    }

    func testRejectsInvertedRange() {
        XCTAssertThrowsError(try CronExpression.validate("0 17-9 * * *"))
    }

    func testRejectsZeroStep() {
        XCTAssertThrowsError(try CronExpression.validate("*/0 * * * *"))
    }

    func testRejectsEmptyString() {
        XCTAssertThrowsError(try CronExpression.validate(""))
    }

    func testRejectsTrailingComma() {
        XCTAssertThrowsError(try CronExpression.validate("0, * * * *"))
    }
}
