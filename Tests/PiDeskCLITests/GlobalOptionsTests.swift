import XCTest
@testable import PiDeskCLI

final class GlobalOptionsTests: XCTestCase {
    func testDefaultsWhenNothingProvided() throws {
        let parsed = try parseArgs([], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: [:], commandOwnsTimeout: false)
        XCTAssertNil(options.url)
        XCTAssertNil(options.token)
        XCTAssertEqual(options.timeoutSeconds, 10)
        XCTAssertFalse(options.jsonOutput)
        XCTAssertFalse(options.quiet)
        if case .unixSocket = options.target {} else { XCTFail("expected unix socket target by default") }
    }

    func testSocketFlagOverridesDefaultPath() throws {
        let parsed = try parseArgs(["--socket", "/tmp/custom.sock"], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: [:], commandOwnsTimeout: false)
        guard case let .unixSocket(path) = options.target else { return XCTFail("expected unix socket target") }
        XCTAssertEqual(path, "/tmp/custom.sock")
    }

    func testUrlFlagSelectsTCPTarget() throws {
        let parsed = try parseArgs(["--url", "http://127.0.0.1:7717"], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: [:], commandOwnsTimeout: false)
        guard case let .tcp(host, port) = options.target else { return XCTFail("expected tcp target") }
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual(port, 7717)
    }

    func testMalformedUrlIsRejected() {
        let parsed = try! parseArgs(["--url", "not a url"], specs: GlobalFlag.all)
        XCTAssertThrowsError(try GlobalOptions.resolve(parsed, environment: [:], commandOwnsTimeout: false))
    }

    func testTokenFlagTakesPrecedenceOverEnv() throws {
        let parsed = try parseArgs(["--token", "flag-token"], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: ["PIDESK_TOKEN": "env-token"], commandOwnsTimeout: false)
        XCTAssertEqual(options.token, "flag-token")
    }

    func testTokenFallsBackToEnv() throws {
        let parsed = try parseArgs([], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: ["PIDESK_TOKEN": "env-token"], commandOwnsTimeout: false)
        XCTAssertEqual(options.token, "env-token")
    }

    func testTimeoutFlagParses() throws {
        let parsed = try parseArgs(["--timeout", "30"], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: [:], commandOwnsTimeout: false)
        XCTAssertEqual(options.timeoutSeconds, 30)
    }

    func testTimeoutFlagRejectsNonNumeric() {
        let parsed = try! parseArgs(["--timeout", "soon"], specs: GlobalFlag.all)
        XCTAssertThrowsError(try GlobalOptions.resolve(parsed, environment: [:], commandOwnsTimeout: false))
    }

    func testTimeoutEnvVarIsUsedWhenFlagAbsent() throws {
        let parsed = try parseArgs([], specs: GlobalFlag.all)
        let options = try GlobalOptions.resolve(parsed, environment: ["PIDESK_TIMEOUT": "45"], commandOwnsTimeout: false)
        XCTAssertEqual(options.timeoutSeconds, 45)
    }

    /// `schedule add --timeout` shadows the global flag; the same token must not be reinterpreted
    /// as a request timeout, but $PIDESK_TIMEOUT remains a working escape hatch.
    func testCommandOwnedTimeoutIgnoresFlagButHonorsEnv() throws {
        let specs = GlobalFlag.merged(into: [FlagSpec("--timeout", takesValue: true, placeholder: "DUR", help: "")], excludingTimeout: true)
        let parsed = try parseArgs(["--timeout", "30m"], specs: specs)
        let options = try GlobalOptions.resolve(parsed, environment: ["PIDESK_TIMEOUT": "20"], commandOwnsTimeout: true)
        XCTAssertEqual(options.timeoutSeconds, 20)
    }

    func testGlobalFlagMergeShadowsCommandSpecificTimeout() {
        let merged = GlobalFlag.merged(into: [FlagSpec("--timeout", takesValue: true, placeholder: "DUR", help: "command-specific")], excludingTimeout: true)
        let timeoutSpecs = merged.filter { $0.long == "--timeout" }
        XCTAssertEqual(timeoutSpecs.count, 1)
        XCTAssertEqual(timeoutSpecs.first?.help, "command-specific")
    }

    func testGlobalFlagMergeKeepsGlobalTimeoutWhenNotExcluded() {
        let merged = GlobalFlag.merged(into: [], excludingTimeout: false)
        XCTAssertTrue(merged.contains { $0.long == "--timeout" })
    }
}
