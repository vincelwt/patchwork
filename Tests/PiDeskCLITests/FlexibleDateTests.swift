import XCTest
@testable import PiDeskCLI

final class FlexibleDateTests: XCTestCase {
    func testParsesStrictISO8601WithZ() throws {
        let date = try FlexibleDate.parse("2026-07-27T09:00:00Z")
        XCTAssertEqual(FlexibleDate.iso8601(date), "2026-07-27T09:00:00Z")
    }

    func testParsesISO8601WithNumericOffset() throws {
        let date = try FlexibleDate.parse("2026-07-27T09:00:00+02:00")
        XCTAssertEqual(FlexibleDate.iso8601(date), "2026-07-27T07:00:00Z")
    }

    func testParsesISO8601WithFractionalSeconds() throws {
        XCTAssertNoThrow(try FlexibleDate.parse("2026-07-27T09:00:00.123Z"))
    }

    func testParsesFriendlyLocalDatetimeInGivenZone() throws {
        let utc = TimeZone(identifier: "UTC")!
        let date = try FlexibleDate.parse("2026-07-27T09:00", timeZone: utc)
        XCTAssertEqual(FlexibleDate.iso8601(date), "2026-07-27T09:00:00Z")
    }

    func testParsesFriendlyLocalDatetimeWithSpaceSeparator() throws {
        let utc = TimeZone(identifier: "UTC")!
        let date = try FlexibleDate.parse("2026-07-27 09:00:00", timeZone: utc)
        XCTAssertEqual(FlexibleDate.iso8601(date), "2026-07-27T09:00:00Z")
    }

    func testParsesDateOnly() throws {
        let utc = TimeZone(identifier: "UTC")!
        let date = try FlexibleDate.parse("2026-07-27", timeZone: utc)
        XCTAssertEqual(FlexibleDate.iso8601(date), "2026-07-27T00:00:00Z")
    }

    func testFriendlyDateRespectsTimeZoneOffset() throws {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let date = try FlexibleDate.parse("2026-07-27T09:00", timeZone: paris)
        // Paris is UTC+2 in July (DST).
        XCTAssertEqual(FlexibleDate.iso8601(date), "2026-07-27T07:00:00Z")
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try FlexibleDate.parse("not a date"))
    }

    func testEmptyIsRejected() {
        XCTAssertThrowsError(try FlexibleDate.parse(""))
    }

    func testDisplayLocalFallsBackToRawStringWhenUnparseable() {
        XCTAssertEqual(FlexibleDate.displayLocal("not-a-real-timestamp"), "not-a-real-timestamp")
    }

    func testDisplayLocalFallsBackForNil() {
        XCTAssertEqual(FlexibleDate.displayLocal(nil), "—")
    }
}
