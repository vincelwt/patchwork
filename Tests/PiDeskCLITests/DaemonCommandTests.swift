import XCTest
@testable import PiDeskCLI

final class DaemonControlUnitTests: XCTestCase {
    func testResolveBinaryPathFindsSiblingOfCurrentExecutable() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidesk = dir.appendingPathComponent("pidesk")
        let sibling = dir.appendingPathComponent("pi-deskd")
        FileManager.default.createFile(atPath: pidesk.path, contents: Data())
        FileManager.default.createFile(atPath: sibling.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let resolved = DaemonControl.resolveBinaryPath(currentExecutable: pidesk.path, fallbackPaths: [])
        XCTAssertEqual(resolved, sibling.path)
    }

    func testResolveBinaryPathFallsBackToConfiguredPaths() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fallback = dir.appendingPathComponent("fallback-pi-deskd")
        FileManager.default.createFile(atPath: fallback.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let resolved = DaemonControl.resolveBinaryPath(currentExecutable: "/nonexistent/pidesk", fallbackPaths: [fallback.path])
        XCTAssertEqual(resolved, fallback.path)
    }

    func testResolveBinaryPathReturnsNilWhenNothingFound() {
        let resolved = DaemonControl.resolveBinaryPath(currentExecutable: "/nonexistent/pidesk", fallbackPaths: ["/nonexistent/fallback"])
        XCTAssertNil(resolved)
    }

    func testPlistContentsIncludeLabelBinaryAndLogPath() {
        let plist = DaemonControl.plistContents(binaryPath: "/usr/local/bin/pi-deskd", logPath: "/tmp/daemon.log")
        XCTAssertTrue(plist.contains(DaemonControl.label))
        XCTAssertTrue(plist.contains("/usr/local/bin/pi-deskd"))
        XCTAssertTrue(plist.contains("/tmp/daemon.log"))
        XCTAssertTrue(plist.contains("RunAtLoad"))
        XCTAssertTrue(plist.contains("SuccessfulExit"))
    }

    func testInstallWritesPlistAndBootstraps() throws {
        // Uses real temp paths (never the real ~/Library/LaunchAgents) so this stays hermetic.
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sibling = dir.appendingPathComponent("pi-deskd")
        FileManager.default.createFile(atPath: sibling.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let plistURL = dir.appendingPathComponent("LaunchAgents/\(DaemonControl.label).plist")
        let logFile = dir.appendingPathComponent("Logs/daemon.log")

        let runner = RecordingShellRunner()
        let path = try DaemonControl.install(runner: runner, fileManager: .default, plistURL: plistURL, logFile: logFile, currentExecutable: "/nonexistent/pidesk", fallbackPaths: [sibling.path])
        XCTAssertEqual(path, sibling.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        let contents = try String(contentsOf: plistURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(logFile.path))
        XCTAssertTrue(runner.invocations.contains { $0.arguments.contains("bootstrap") })
    }

    func testStartUsesKickstartWhenPlistExists() throws {
        let runner = RecordingShellRunner()
        let fileManager = StubFileManager(existingPaths: [DaemonControl.plistURL.path])
        try DaemonControl.start(runner: runner, fileManager: fileManager)
        XCTAssertEqual(runner.invocations.last?.executable, "/bin/launchctl")
        XCTAssertEqual(runner.invocations.last?.arguments.first, "kickstart")
    }

    func testStopFailsCleanlyWhenNotInstalled() {
        let runner = RecordingShellRunner()
        let fileManager = StubFileManager(existingPaths: [])
        XCTAssertThrowsError(try DaemonControl.stop(runner: runner, fileManager: fileManager)) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("expected CLIFailure") }
            XCTAssertEqual(failure.exitCode, .requestFailed)
        }
    }

    func testRestartUsesKickstartDashK() throws {
        let runner = RecordingShellRunner()
        let fileManager = StubFileManager(existingPaths: [DaemonControl.plistURL.path])
        try DaemonControl.restart(runner: runner, fileManager: fileManager)
        XCTAssertEqual(runner.invocations.last?.arguments, ["kickstart", "-k", DaemonControl.guiService()])
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RecordingShellRunner()
        let fileManager = StubFileManager(existingPaths: [DaemonControl.plistURL.path])
        try DaemonControl.uninstall(runner: runner, fileManager: fileManager)
        XCTAssertTrue(runner.invocations.contains { $0.arguments.contains("bootout") })
        XCTAssertTrue(fileManager.removedPaths.contains(DaemonControl.plistURL.path))
    }
}

final class DaemonCommandCLITests: XCTestCase {
    func testStatusReachableJSON() async throws {
        let plane = FakeControlPlane()
        plane.healthResult = WireHealth(ok: true, version: "1.2.3", api: 1, startedAt: "2026-01-01T00:00:00Z", runningRuns: 1, queuedRuns: 0, piVersion: "0.82.1", schedulesEnabled: true)
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        let decoded = try JSONDecoder().decode(WireHealth.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.version, "1.2.3")
    }

    func testStatusUnreachableJSONEnvelope() async throws {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("connection refused")
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 3)
        let decoded = try JSONDecoder().decode(JSONErrorEnvelope.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.ok, false)
        XCTAssertEqual(decoded.error.code, "unreachable")
    }

    func testStatusUnreachableHumanMessage() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("connection refused")
        let result = await runCLI(["daemon", "status"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("not reachable"))
    }

    func testInstallFailsCleanlyWhenBinaryMissing() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RecordingShellRunner()
        let fileManager = StubFileManager(existingPaths: [])
        let result = await runCLI(["daemon", "install"], shellRunner: runner, fileManager: fileManager)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("pi-deskd"))
    }

    func testLogsFailsCleanlyWhenNoLogFileYet() async {
        let result = await runCLI(["daemon", "logs"], fileManager: StubFileManager(existingPaths: []))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("daemon start"))
    }

    func testLogsShowsTailOfFile() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("daemon.log")
        try Data("line1\nline2\nline3\n".utf8).write(to: logURL)

        // Route PiDeskPaths.logFile-dependent code through a real file by using the real
        // FileManager and asserting via LogTail directly (daemon logs always reads the fixed
        // PiDeskPaths.logFile path, so this exercises the same bounded-tail logic it uses).
        let lines = try LogTail.lastLines(of: logURL, count: 2)
        XCTAssertEqual(lines, ["line2", "line3"])
    }

    func testLogsRejectsBadLinesValue() async {
        let result = await runCLI(["daemon", "logs", "--lines", "0"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testGroupHelp() async {
        let result = await runCLI(["daemon", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("install"))
    }
}

/// Minimal FileManager stand-in for daemon-lifecycle tests: only the handful of methods
/// DaemonControl actually calls need to be faked; everything else defers to a real FileManager
/// via subclassing so paths outside the test's control (e.g. temp dirs) still work.
final class StubFileManager: FileManager, @unchecked Sendable {
    private var existingPaths: Set<String>
    private(set) var removedPaths: [String] = []

    init(existingPaths: [String]) {
        self.existingPaths = Set(existingPaths)
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path) || super.fileExists(atPath: path)
    }

    override func removeItem(at URL: URL) throws {
        removedPaths.append(URL.path)
        existingPaths.remove(URL.path)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        // No-op: these tests assert on recorded shell invocations, not the real filesystem.
    }
}
