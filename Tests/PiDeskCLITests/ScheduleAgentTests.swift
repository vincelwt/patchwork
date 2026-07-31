import XCTest
@testable import PiDeskCLI

/// A non-Pi agent creating an automation for itself has to be able to say so. Without this the
/// CLI could only ever create Pi automations, so a Claude thread running `pidesk schedule add
/// --cwd …` got a schedule that came back later as Pi.
final class ScheduleAgentTests: XCTestCase {
    func testANewThreadScheduleCarriesTheChosenAgent() async {
        let plane = FakeControlPlane()
        let result = await runCLI([
            "schedule", "add", "--name", "Nightly", "--cwd", ".", "--prompt", "p",
            "--every", "1h", "--agent", "claude"
        ], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.agent, "claude")
    }

    func testAgentIsNormalised() async {
        let plane = FakeControlPlane()
        _ = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p",
            "--every", "1h", "--agent", "CODEX"
        ], controlPlane: plane)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.agent, "codex")
    }

    func testAnUnknownAgentIsRejectedBeforeAnyRequest() async {
        let plane = FakeControlPlane()
        let result = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p",
            "--every", "1h", "--agent", "gemini"
        ], controlPlane: plane)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertNil(plane.lastScheduleCreateRequest)
    }

    /// An existing thread already knows its agent, and the scheduler reads it from the thread at
    /// every fire, so pinning one here could only ever disagree with the transcript.
    func testAgentIsRejectedForAnExistingThreadTarget() async {
        let plane = FakeControlPlane()
        let result = await runCLI([
            "schedule", "add", "--name", "n", "--thread", "abc", "--prompt", "p",
            "--every", "1h", "--agent", "claude"
        ], controlPlane: plane)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertNil(plane.lastScheduleCreateRequest)
    }

    func testWithoutAnAgentNothingIsSentSoTheDaemonKeepsItsDefault() async {
        let plane = FakeControlPlane()
        _ = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--every", "1h"
        ], controlPlane: plane)
        XCTAssertNil(plane.lastScheduleCreateRequest?.agent)
    }
}
