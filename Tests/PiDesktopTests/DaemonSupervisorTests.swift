import XCTest
@testable import PiDesktop

private final class FakeControlService: ControlServiceLifecycle, @unchecked Sendable {
    var startCount = 0
    var stopGrace: [TimeInterval] = []
    var startError: Error?

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop(graceSeconds: TimeInterval) async {
        stopGrace.append(graceSeconds)
    }
}

private struct FakeHealthProbe: DaemonHealthProbing {
    let healthy: Bool
    func probe() async -> Bool { healthy }
}

private struct FakeLaunchAgentProbe: LaunchAgentProbing {
    let loaded: Bool
    func isLoaded() -> Bool { loaded }
}

@MainActor
final class DaemonSupervisorTests: XCTestCase {
    func testAppHostsAndStopsItsOwnControlService() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ownerFile = directory.appendingPathComponent("owner.json")
        let service = FakeControlService()
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: FakeHealthProbe(healthy: false),
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: ownerFile,
            currentPID: 4242,
            isProcessAlive: { _ in false }
        )

        await supervisor.appDidLaunch()

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(DaemonOwnerFile.read(from: ownerFile)?.pid, 4242)

        await supervisor.stopForQuit()

        XCTAssertEqual(service.stopGrace, [0])
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertNil(DaemonOwnerFile.read(from: ownerFile))
    }

    func testExplicitExternalHostIsNeverOwnedOrStopped() async {
        let service = FakeControlService()
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: FakeHealthProbe(healthy: true),
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            currentPID: 4242,
            isProcessAlive: { _ in false }
        )

        await supervisor.appDidLaunch()
        await supervisor.stopForQuit()

        XCTAssertEqual(service.startCount, 0)
        XCTAssertTrue(service.stopGrace.isEmpty)
        XCTAssertEqual(supervisor.state, .stopped)
    }

    func testLaunchAgentTakesPrecedenceOverInProcessHost() async {
        let service = FakeControlService()
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: FakeHealthProbe(healthy: false),
            launchAgentProbe: FakeLaunchAgentProbe(loaded: true),
            ownerFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            currentPID: 4242,
            isProcessAlive: { _ in false }
        )

        await supervisor.appDidLaunch()

        XCTAssertEqual(supervisor.state, .deferringToLaunchAgent)
        XCTAssertEqual(service.startCount, 0)
    }
}
