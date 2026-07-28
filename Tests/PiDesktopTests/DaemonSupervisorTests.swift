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

private final class MutableHealthProbe: DaemonHealthProbing {
    var healthy: Bool
    init(healthy: Bool) { self.healthy = healthy }
    func probe() async -> Bool { healthy }
}

private struct FakeLaunchAgentProbe: LaunchAgentProbing {
    let loaded: Bool
    func isLoaded() -> Bool { loaded }
}

private final class SignalCapture {
    var values: [(Int32, Int32)] = []
}

private actor GatedControlService: ControlServiceLifecycle {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopValues: [TimeInterval] = []

    func start() async throws {
        await withCheckedContinuation { startContinuation = $0 }
    }

    func stop(graceSeconds: TimeInterval) async {
        stopValues.append(graceSeconds)
    }

    func startBegan() -> Bool { startContinuation != nil }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stops() -> [TimeInterval] { stopValues }
}

private actor GatedHealthProbe: DaemonHealthProbing {
    private var calls = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    func probe() async -> Bool {
        calls += 1
        if calls == 1 { return true }
        return await withCheckedContinuation { continuation = $0 }
    }

    func secondProbeStarted() -> Bool { continuation != nil }

    func release(_ healthy: Bool) {
        continuation?.resume(returning: healthy)
        continuation = nil
    }
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

    func testAppTakesOverWhenDeferredExternalHostExits() async {
        let health = MutableHealthProbe(healthy: true)
        let service = FakeControlService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: health,
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: directory.appendingPathComponent("owner.json"),
            currentPID: 4242,
            pollInterval: 0.05,
            isProcessAlive: { _ in false }
        )
        await supervisor.appDidLaunch()
        XCTAssertEqual(supervisor.state, .deferringToExternalProcess)

        health.healthy = false
        for _ in 0..<30 where supervisor.state != .running {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(service.startCount, 1)
        await supervisor.stopForQuit()
    }

    func testQuitWaitsForDeferredProbeWithoutStartingAServiceAfterward() async {
        let health = GatedHealthProbe()
        let service = FakeControlService()
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: health,
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            currentPID: 4242,
            pollInterval: 0.05,
            isProcessAlive: { _ in false }
        )
        await supervisor.appDidLaunch()
        for _ in 0..<30 {
            if await health.secondProbeStarted() { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let quit = Task { await supervisor.stopForQuit() }
        await Task.yield()
        await health.release(false)
        await quit.value

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(service.startCount, 0)
    }

    func testQuitWaitsForTakeoverStartupAndStopsTheCandidate() async {
        let health = MutableHealthProbe(healthy: true)
        let service = GatedControlService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: health,
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: directory.appendingPathComponent("owner.json"),
            currentPID: 4242,
            pollInterval: 0.05,
            isProcessAlive: { _ in false }
        )
        await supervisor.appDidLaunch()
        health.healthy = false
        for _ in 0..<30 {
            if await service.startBegan() { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let quit = Task { await supervisor.stopForQuit() }
        await Task.yield()
        await service.releaseStart()
        await quit.value

        let stops = await service.stops()
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(stops, [0])
        XCTAssertNil(DaemonOwnerFile.read(from: directory.appendingPathComponent("owner.json")))
    }

    func testSecondAppInstanceDoesNotKillTheFirstAppHostedService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerFile = directory.appendingPathComponent("owner.json")
        try DaemonOwnerFile.write(
            DaemonOwnerRecord(pid: 111, startedAt: Date(), host: "app"),
            to: ownerFile
        )
        let signals = SignalCapture()
        let supervisor = DaemonSupervisor(
            serviceFactory: { FakeControlService() },
            healthProbe: FakeHealthProbe(healthy: true),
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: ownerFile,
            currentPID: 222,
            isProcessAlive: { _ in true },
            signalProcess: { signals.values.append(($0, $1)) }
        )

        await supervisor.appDidLaunch()

        XCTAssertEqual(supervisor.state, .deferringToExternalProcess)
        XCTAssertTrue(signals.values.isEmpty)
        XCTAssertEqual(DaemonOwnerFile.read(from: ownerFile)?.pid, 111)
    }

    func testStaleLegacyRecordNeverSignalsAReusedUnmatchedPID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerFile = directory.appendingPathComponent("owner.json")
        try DaemonOwnerFile.write(DaemonOwnerRecord(pid: 111, startedAt: .distantPast), to: ownerFile)
        let signals = SignalCapture()
        let service = FakeControlService()
        let supervisor = DaemonSupervisor(
            serviceFactory: { service },
            healthProbe: FakeHealthProbe(healthy: false),
            launchAgentProbe: FakeLaunchAgentProbe(loaded: false),
            ownerFileURL: ownerFile,
            currentPID: 222,
            isProcessAlive: { _ in true },
            isLegacyDaemon: { _ in false },
            signalProcess: { signals.values.append(($0, $1)) }
        )

        await supervisor.appDidLaunch()

        XCTAssertTrue(signals.values.isEmpty)
        XCTAssertEqual(service.startCount, 1)
        XCTAssertEqual(DaemonOwnerFile.read(from: ownerFile)?.pid, 222)
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
