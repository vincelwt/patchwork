import XCTest
@testable import PiDeskCLI

final class CLIRunnerTests: XCTestCase {
    func testNoArgumentsPrintsUsageAndExitsBadUsage() async {
        let result = await runCLI([])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("Usage:"))
    }

    func testTopLevelHelpExitsOk() async {
        let result = await runCLI(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("threads"))
        XCTAssertTrue(result.stdout.contains("schedule"))
        XCTAssertTrue(result.stdout.contains("daemon"))
        XCTAssertTrue(result.stdout.contains("remote"))
        XCTAssertTrue(result.stdout.contains("limits"))
        XCTAssertTrue(result.stdout.contains("Exit codes:"))
    }

    func testShortHelpFlagWorksToo() async {
        let result = await runCLI(["-h"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testVersionFlag() async {
        let result = await runCLI(["--version"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("pidesk"))
    }

    func testUnknownTopLevelCommandIsBadUsage() async {
        let result = await runCLI(["frobnicate"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("frobnicate"))
    }

    func testQuietSuppressesInfoButNotData() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A")], nextCursor: "cur1")
        let result = await runCLI(["threads", "list", "--quiet"], controlPlane: plane)
        XCTAssertTrue(result.stdout.contains("t1")) // primary data still printed
        XCTAssertFalse(result.stderr.contains("--cursor")) // incidental hint suppressed
    }

    func testJSONModeNeverEmitsAnsiColorCodes() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A", running: true)], nextCursor: nil)
        let result = await runCLI(["threads", "list", "--json"], controlPlane: plane, isTTY: true)
        XCTAssertFalse(result.stdout.contains("\u{1B}["))
    }

    func testNonTTYNeverEmitsAnsiColorCodes() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A", running: true)], nextCursor: nil)
        let result = await runCLI(["threads", "list"], controlPlane: plane, isTTY: false)
        XCTAssertFalse(result.stdout.contains("\u{1B}["))
    }

    func testNoColorEnvDisablesColorEvenOnTTY() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A", running: true)], nextCursor: nil)
        let result = await runCLI(["threads", "list"], environment: ["NO_COLOR": "1"], controlPlane: plane, isTTY: true)
        XCTAssertFalse(result.stdout.contains("\u{1B}["))
    }

    func testTTYWithoutNoColorEnablesColorForStatusWords() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A", running: true)], nextCursor: nil)
        let result = await runCLI(["threads", "list"], controlPlane: plane, isTTY: true)
        XCTAssertTrue(result.stdout.contains("\u{1B}["))
    }
}
