import XCTest
@testable import PiDeskCLI

final class DurationParsingTests: XCTestCase {
    func testSingleUnits() throws {
        XCTAssertEqual(try parseDuration("45s"), 45)
        XCTAssertEqual(try parseDuration("15m"), 900)
        XCTAssertEqual(try parseDuration("2h"), 7200)
        XCTAssertEqual(try parseDuration("1d"), 86_400)
    }

    func testCompoundDuration() throws {
        XCTAssertEqual(try parseDuration("1h30m"), 5400)
        XCTAssertEqual(try parseDuration("1d2h3m4s"), 86_400 + 7200 + 180 + 4)
    }

    func testFractionalValue() throws {
        XCTAssertEqual(try parseDuration("1.5h"), 5400)
    }

    func testWhitespaceIsTrimmed() throws {
        XCTAssertEqual(try parseDuration("  15m  "), 900)
    }

    func testMissingUnitIsRejected() {
        XCTAssertThrowsError(try parseDuration("45")) { error in
            guard case UsageError.invalidValue = error else { return XCTFail("expected invalidValue, got \(error)") }
        }
    }

    func testEmptyStringIsRejected() {
        XCTAssertThrowsError(try parseDuration(""))
    }

    func testUnknownUnitIsRejected() {
        XCTAssertThrowsError(try parseDuration("15x"))
    }

    func testNegativeIsRejected() {
        XCTAssertThrowsError(try parseDuration("-5m"))
    }

    func testZeroIsRejected() {
        XCTAssertThrowsError(try parseDuration("0s"))
    }

    func testAbsurdlyLargeIsRejected() {
        XCTAssertThrowsError(try parseDuration("999d"))
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try parseDuration("fifteen minutes"))
    }

    func testFormatDurationRoundTripsCommonValues() {
        XCTAssertEqual(formatDuration(45), "45s")
        XCTAssertEqual(formatDuration(900), "15m")
        XCTAssertEqual(formatDuration(7200), "2h")
        XCTAssertEqual(formatDuration(86_400), "1d")
        XCTAssertEqual(formatDuration(5400), "1h30m")
        XCTAssertEqual(formatDuration(0), "0s")
    }
}
