import PatchworkKit
import XCTest
@testable import PatchworkCLI

final class DaemonControlUnitTests: XCTestCase {
    func testResolveBinaryPathFindsSiblingOfCurrentExecutable() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let patchwork = dir.appendingPathComponent("patchwork")
        let sibling = dir.appendingPathComponent("patchworkd")
        FileManager.default.createFile(atPath: patchwork.path, contents: Data())
        FileManager.default.createFile(atPath: sibling.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let resolved = DaemonControl.resolveBinaryPath(currentExecutable: patchwork.path, fallbackPaths: [])
        XCTAssertEqual(resolved, sibling.path)
    }

    func testResolveBinaryPathFallsBackToConfiguredPaths() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fallback = dir.appendingPathComponent("fallback-patchworkd")
        FileManager.default.createFile(atPath: fallback.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let resolved = DaemonControl.resolveBinaryPath(currentExecutable: "/nonexistent/patchwork", fallbackPaths: [fallback.path])
        XCTAssertEqual(resolved, fallback.path)
    }

    func testResolveBinaryPathReturnsNilWhenNothingFound() {
        let resolved = DaemonControl.resolveBinaryPath(currentExecutable: "/nonexistent/patchwork", fallbackPaths: ["/nonexistent/fallback"])
        XCTAssertNil(resolved)
    }

    func testPlistContentsIncludeLabelBinaryAndLogPath() {
        let plist = DaemonControl.plistContents(binaryPath: "/usr/local/bin/patchworkd", logPath: "/tmp/daemon.log")
        XCTAssertTrue(plist.contains(DaemonControl.label))
        XCTAssertTrue(plist.contains("/usr/local/bin/patchworkd"))
        XCTAssertTrue(plist.contains("/tmp/daemon.log"))
        XCTAssertTrue(plist.contains("RunAtLoad"))
        XCTAssertTrue(plist.contains("SuccessfulExit"))
    }

    func testInstallWritesPlistAndBootstraps() throws {
        // Uses real temp paths (never the real ~/Library/LaunchAgents) so this stays hermetic.
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sibling = dir.appendingPathComponent("patchworkd")
        FileManager.default.createFile(atPath: sibling.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let plistURL = dir.appendingPathComponent("LaunchAgents/\(DaemonControl.label).plist")
        let logFile = dir.appendingPathComponent("Logs/daemon.log")

        let runner = RecordingShellRunner()
        let path = try DaemonControl.install(runner: runner, fileManager: .default, plistURL: plistURL, logFile: logFile, currentExecutable: "/nonexistent/patchwork", fallbackPaths: [sibling.path])
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
    /// `RecordingShellRunner`'s own default stub reports success for anything, `daemon status`'s
    /// LaunchAgent probe included — fine for tests that don't care, wrong for every test below
    /// that asserts a specific mode, so they all supply this explicit "not loaded" double instead.
    private func notLoadedRunner() -> RecordingShellRunner {
        let runner = RecordingShellRunner()
        runner.resultProvider = { _, args in args.contains("print") ? ShellResult(exitCode: 1, stdout: "", stderr: "Could not find service") : ShellResult(exitCode: 0, stdout: "", stderr: "") }
        return runner
    }

    private func loadedRunner() -> RecordingShellRunner {
        let runner = RecordingShellRunner()
        runner.resultProvider = { _, args in args.contains("print") ? ShellResult(exitCode: 0, stdout: "", stderr: "") : ShellResult(exitCode: 0, stdout: "", stderr: "") }
        return runner
    }

    func testStatusReachableJSON() async throws {
        let plane = FakeControlPlane()
        plane.healthResult = WireHealth(ok: true, version: "1.2.3", api: 1, startedAt: "2026-01-01T00:00:00Z", runningRuns: 1, queuedRuns: 0, piVersion: "0.82.1", schedulesEnabled: true)
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane, shellRunner: notLoadedRunner())
        XCTAssertEqual(result.exitCode, 0)
        let decoded = try JSONDecoder().decode(DaemonStatusJSON.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.health.version, "1.2.3")
        XCTAssertEqual(decoded.mode, DaemonRunMode.external.rawValue, "reachable with no owner record and no LaunchAgent is an unrecognised, honest \"external\"")
    }

    func testStatusReachableAndOwnedByAppReportsAppManaged() async throws {
        let plane = FakeControlPlane()
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ownerFile = dir.appendingPathComponent("daemon-owner.json")
        try PatchworkFile.writeAtomic(DaemonOwnerRecord(pid: getpid(), startedAt: Date()), to: ownerFile)
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane, shellRunner: notLoadedRunner(), daemonOwnerFilePath: ownerFile)
        XCTAssertEqual(result.exitCode, 0)
        let decoded = try JSONDecoder().decode(DaemonStatusJSON.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.mode, DaemonRunMode.appManaged.rawValue, "this process's own pid is always alive, so a record naming it must read as owned")
    }

    func testStatusReportsLaunchAgentEvenWhenOwnerFileAlsoPresent() async throws {
        let plane = FakeControlPlane()
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ownerFile = dir.appendingPathComponent("daemon-owner.json")
        try PatchworkFile.writeAtomic(DaemonOwnerRecord(pid: getpid(), startedAt: Date()), to: ownerFile)
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane, shellRunner: loadedRunner(), daemonOwnerFilePath: ownerFile)
        let decoded = try JSONDecoder().decode(DaemonStatusJSON.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.mode, DaemonRunMode.launchAgent.rawValue, "the LaunchAgent must win even though an app owner record also exists")
    }

    func testStatusUnreachableJSONEnvelope() async throws {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("connection refused")
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane, shellRunner: notLoadedRunner())
        XCTAssertEqual(result.exitCode, 3)
        let decoded = try JSONDecoder().decode(JSONErrorEnvelope.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.ok, false)
        XCTAssertEqual(decoded.error.code, "unreachable")
        XCTAssertEqual(decoded.mode, DaemonRunMode.notRunning.rawValue)
    }

    func testStatusUnreachableButLaunchAgentLoadedReportsLaunchAgentMode() async throws {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("connection refused")
        let result = await runCLI(["daemon", "status", "--json"], controlPlane: plane, shellRunner: loadedRunner())
        let decoded = try JSONDecoder().decode(JSONErrorEnvelope.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.mode, DaemonRunMode.launchAgent.rawValue, "loaded-but-not-yet-answering must still say LaunchAgent, not notRunning")
    }

    func testStatusUnreachableHumanMessage() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("connection refused")
        let result = await runCLI(["daemon", "status"], controlPlane: plane, shellRunner: notLoadedRunner())
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("not reachable"))
        XCTAssertTrue(result.stdout.contains("mode: not running"))
    }

    func testInstallFailsCleanlyWhenBinaryMissing() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RecordingShellRunner()
        let fileManager = StubFileManager(existingPaths: [])
        let result = await runCLI(["daemon", "install"], shellRunner: runner, fileManager: fileManager)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("patchworkd"))
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

        // Route PatchworkPaths.logFile-dependent code through a real file by using the real
        // FileManager and asserting via LogTail directly (daemon logs always reads the fixed
        // PatchworkPaths.logFile path, so this exercises the same bounded-tail logic it uses).
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
