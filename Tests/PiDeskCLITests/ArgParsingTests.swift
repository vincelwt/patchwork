import XCTest
@testable import PiDeskCLI

final class ArgParsingTests: XCTestCase {
    private let specs: [FlagSpec] = [
        FlagSpec("--name", short: "-n", takesValue: true, placeholder: "N", help: ""),
        FlagSpec("--json", takesValue: false, help: ""),
        FlagSpec("--quiet", short: "-q", takesValue: false, help: "")
    ]

    func testLongFlagWithSeparateValue() throws {
        let parsed = try parseArgs(["--name", "Alice"], specs: specs)
        XCTAssertEqual(parsed.value("--name"), "Alice")
    }

    func testLongFlagWithEqualsValue() throws {
        let parsed = try parseArgs(["--name=Alice"], specs: specs)
        XCTAssertEqual(parsed.value("--name"), "Alice")
    }

    func testShortFlagWithSeparateValue() throws {
        let parsed = try parseArgs(["-n", "Alice"], specs: specs)
        XCTAssertEqual(parsed.value("--name"), "Alice")
    }

    func testBooleanSwitch() throws {
        let parsed = try parseArgs(["--json"], specs: specs)
        XCTAssertTrue(parsed.flag("--json"))
        XCTAssertFalse(parsed.flag("--quiet"))
    }

    func testShortBooleanSwitch() throws {
        let parsed = try parseArgs(["-q"], specs: specs)
        XCTAssertTrue(parsed.flag("--quiet"))
    }

    func testPositionalsInterleavedWithFlags() throws {
        let parsed = try parseArgs(["id123", "--json", "hello world"], specs: specs)
        XCTAssertEqual(parsed.positionals, ["id123", "hello world"])
        XCTAssertTrue(parsed.flag("--json"))
    }

    func testFlagsBeforeAndAfterPositionals() throws {
        let parsed = try parseArgs(["--json", "id123", "--name", "Alice"], specs: specs)
        XCTAssertEqual(parsed.positionals, ["id123"])
        XCTAssertEqual(parsed.value("--name"), "Alice")
    }

    func testDoubleDashStopsFlagParsing() throws {
        let parsed = try parseArgs(["id123", "--", "--json", "-5 degrees"], specs: specs)
        XCTAssertEqual(parsed.positionals, ["id123", "--json", "-5 degrees"])
        XCTAssertFalse(parsed.flag("--json"))
    }

    func testBareDashIsPositional() throws {
        let parsed = try parseArgs(["id123", "-"], specs: specs)
        XCTAssertEqual(parsed.positionals, ["id123", "-"])
    }

    func testNegativeNumberIsPositionalNotFlag() throws {
        let parsed = try parseArgs(["-5"], specs: specs)
        XCTAssertEqual(parsed.positionals, ["-5"])
    }

    func testUnknownLongFlagThrows() {
        XCTAssertThrowsError(try parseArgs(["--bogus"], specs: specs)) { error in
            guard case let UsageError.unknownFlag(name) = error else { return XCTFail("expected unknownFlag, got \(error)") }
            XCTAssertEqual(name, "--bogus")
        }
    }

    func testUnknownShortFlagThrows() {
        XCTAssertThrowsError(try parseArgs(["-z"], specs: specs)) { error in
            guard case UsageError.unknownFlag = error else { return XCTFail("expected unknownFlag, got \(error)") }
        }
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(try parseArgs(["--name"], specs: specs)) { error in
            guard case UsageError.missingValue = error else { return XCTFail("expected missingValue, got \(error)") }
        }
    }

    func testValueOnBooleanFlagViaEqualsThrows() {
        XCTAssertThrowsError(try parseArgs(["--json=yes"], specs: specs)) { error in
            guard case UsageError.flagTakesNoValue = error else { return XCTFail("expected flagTakesNoValue, got \(error)") }
        }
    }

    func testMalformedInputDoesNotCrash() {
        // A grab-bag of edge cases that must fail cleanly, never trap/crash.
        for args in [["--"], ["--="], ["-"], [""], ["--name="], ["---triple"]] {
            _ = try? parseArgs(args, specs: specs)
        }
    }

    func testRequirePositionalsExactCount() throws {
        let parsed = try parseArgs(["a", "b"], specs: [])
        XCTAssertEqual(try requirePositionals(parsed, names: ["id", "name"]), ["a", "b"])
    }

    func testRequirePositionalsMissingNamesTheMissingOne() {
        let parsed = try! parseArgs(["a"], specs: [])
        XCTAssertThrowsError(try requirePositionals(parsed, names: ["id", "name"])) { error in
            guard case let UsageError.missingPositional(name) = error else { return XCTFail("expected missingPositional, got \(error)") }
            XCTAssertEqual(name, "name")
        }
    }

    func testRequirePositionalsTooMany() {
        let parsed = try! parseArgs(["a", "b", "c"], specs: [])
        XCTAssertThrowsError(try requirePositionals(parsed, names: ["id", "name"])) { error in
            guard case UsageError.tooManyPositionals = error else { return XCTFail("expected tooManyPositionals, got \(error)") }
        }
    }

    func testRequestsHelpDetectsLongAndShortForm() {
        XCTAssertTrue(requestsHelp(["threads", "--help"]))
        XCTAssertTrue(requestsHelp(["-h"]))
        XCTAssertFalse(requestsHelp(["threads", "list"]))
    }

    func testRequestsHelpIgnoredAfterDoubleDash() {
        XCTAssertFalse(requestsHelp(["send", "id", "--", "--help"]))
    }

    func testTruncatedLeavesShortStringsAlone() {
        XCTAssertEqual(truncated("hello", max: 10), "hello")
    }

    func testTruncatedShortensLongStrings() {
        XCTAssertEqual(truncated(String(repeating: "a", count: 20), max: 5), "aaaaa…")
    }
}
