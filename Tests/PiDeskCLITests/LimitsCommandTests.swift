import XCTest
@testable import PiDeskCLI

final class LimitsCommandTests: XCTestCase {
    func testJSONPassesThroughReport() async throws {
        let plane = FakeControlPlane()
        plane.limitsResult = WireLimits(report: .object(["accounts": .array([.object(["name": .string("me")])])]), generatedAt: "2026-01-01T00:00:00Z", stale: false)
        let result = await runCLI(["limits", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        let decoded = try JSONDecoder().decode(WireLimits.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.report["accounts"]?.stringValue, nil) // array, not scalar
        XCTAssertEqual(decoded.generatedAt, "2026-01-01T00:00:00Z")
    }

    func testHumanRenderIsBoundedAndReadable() async {
        let plane = FakeControlPlane()
        plane.limitsResult = WireLimits(report: .object(["accounts": .array([.object(["name": .string("me"), "plan": .string("pro")])])]), generatedAt: "2026-01-01T00:00:00Z", stale: false)
        let result = await runCLI(["limits"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("name: me"))
    }

    func testStaleFlagNotedInHumanOutput() async {
        // Incidental context (like staleness) is stderr chatter, not part of the data on stdout.
        let plane = FakeControlPlane()
        plane.limitsResult = WireLimits(report: .object([:]), generatedAt: "2026-01-01T00:00:00Z", stale: true)
        let result = await runCLI(["limits"], controlPlane: plane)
        XCTAssertTrue(result.stderr.contains("stale"))
    }

    func testUnreachableDaemonExitsThree() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("socket not found")
        let result = await runCLI(["limits"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testHelp() async {
        let result = await runCLI(["limits", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage:"))
    }
}
