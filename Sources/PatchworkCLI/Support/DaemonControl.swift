import Darwin
import Foundation
import PatchworkKit

/// Runs an external command and captures its result. `SystemShellRunner` is the only
/// implementation wired into `main.swift`; tests always use a fake so a test run never actually
/// touches launchd or spawns a real process.
protocol ShellRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> ShellResult
}

struct ShellResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct SystemShellRunner: ShellRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// Manages `patchworkd` as a macOS LaunchAgent (docs/daemon-api.md: "a LaunchAgent
/// (app.patchwork.desktop.daemon) that starts at login and restarts on failure"). Falls back to a
/// direct, non-persistent spawn for `start` when the agent was never installed, since that's
/// still useful for a one-off local session.
///
/// Every function takes `plistURL`/`logFile` as parameters defaulting to the real paths, so tests
/// can redirect them to a temp file instead of ever touching the real
/// `~/Library/LaunchAgents`/`~/Library/Logs`.
enum DaemonControl {
    static let label = "app.patchwork.desktop.daemon"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func guiDomain() -> String { "gui/\(getuid())" }
    static func guiService() -> String { "\(guiDomain())/\(label)" }

    /// `launchctl print` exits 0 only while the service is actually bootstrapped into the gui
    /// domain — the one true "is the LaunchAgent path in play" signal `daemon status` and Pi
    /// Desktop.app's own supervisor both need, matching `scripts/install-daemon.sh`'s `is_loaded`.
    static func isLoaded(runner: ShellRunning) -> Bool {
        (try? runner.run("/bin/launchctl", ["print", guiService()]))?.exitCode == 0
    }

    /// Looks next to the running `patchwork` binary first (the common case: both are built/installed
    /// together), then a couple of conventional install locations.
    static func resolveBinaryPath(
        currentExecutable: String = CommandLine.arguments[0],
        fallbackPaths: [String] = ["/usr/local/bin/patchworkd", "/opt/homebrew/bin/patchworkd"],
        fileManager: FileManager = .default
    ) -> String? {
        let sibling = URL(fileURLWithPath: currentExecutable).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("patchworkd").path
        if fileManager.isExecutableFile(atPath: sibling) { return sibling }
        for candidate in fallbackPaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static func plistContents(binaryPath: String, logPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(binaryPath)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key><false/>
          </dict>
          <key>StandardOutPath</key><string>\(logPath)</string>
          <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    static func install(
        runner: ShellRunning,
        fileManager: FileManager = .default,
        plistURL: URL = plistURL,
        logFile: URL = PatchworkPaths.logFile,
        currentExecutable: String = CommandLine.arguments[0],
        fallbackPaths: [String] = ["/usr/local/bin/patchworkd", "/opt/homebrew/bin/patchworkd"]
    ) throws -> String {
        guard let binaryPath = resolveBinaryPath(currentExecutable: currentExecutable, fallbackPaths: fallbackPaths, fileManager: fileManager) else {
            throw CLIFailure(
                exitCode: .requestFailed,
                message: "cannot find patchworkd next to patchwork or in /usr/local/bin, /opt/homebrew/bin",
                hint: "build it first: swift build --product patchworkd"
            )
        }
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = plistContents(binaryPath: binaryPath, logPath: logFile.path)
        try fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: plistURL, options: .atomic)
        _ = try? runner.run("/bin/launchctl", ["bootout", guiService()]) // clear a stale registration, ignore "not loaded"
        let result = try runner.run("/bin/launchctl", ["bootstrap", guiDomain(), plistURL.path])
        guard result.exitCode == 0 else {
            throw CLIFailure(exitCode: .requestFailed, message: "launchctl bootstrap failed: \(result.stderr.trimmedOrSelf())")
        }
        return binaryPath
    }

    static func uninstall(runner: ShellRunning, fileManager: FileManager = .default, plistURL: URL = plistURL) throws {
        _ = try? runner.run("/bin/launchctl", ["bootout", guiService()])
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    static func start(runner: ShellRunning, fileManager: FileManager = .default, plistURL: URL = plistURL, logFile: URL = PatchworkPaths.logFile) throws {
        if fileManager.fileExists(atPath: plistURL.path) {
            let result = try runner.run("/bin/launchctl", ["kickstart", guiService()])
            guard result.exitCode == 0 else {
                throw CLIFailure(exitCode: .requestFailed, message: "launchctl kickstart failed: \(result.stderr.trimmedOrSelf())")
            }
            return
        }
        guard let binaryPath = resolveBinaryPath(fileManager: fileManager) else {
            throw CLIFailure(
                exitCode: .requestFailed,
                message: "patchworkd not found",
                hint: "run `patchwork daemon install` to register it as a login item, or build it: swift build --product patchworkd"
            )
        }
        try spawnDetached(binaryPath: binaryPath, logFile: logFile)
    }

    static func stop(runner: ShellRunning, fileManager: FileManager = .default, plistURL: URL = plistURL) throws {
        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw CLIFailure(
                exitCode: .requestFailed,
                message: "daemon is not installed as a LaunchAgent; nothing to stop via launchctl",
                hint: "if Patchwork.app started it, quit the app (or turn off its \"background service\" setting) to stop it; " +
                    "if you started it yourself with `patchwork daemon start`, stop it manually (e.g. pkill patchworkd)"
            )
        }
        let result = try runner.run("/bin/launchctl", ["kill", "SIGTERM", guiService()])
        guard result.exitCode == 0 else {
            throw CLIFailure(exitCode: .requestFailed, message: "launchctl kill failed: \(result.stderr.trimmedOrSelf())")
        }
    }

    static func restart(runner: ShellRunning, fileManager: FileManager = .default, plistURL: URL = plistURL) throws {
        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw CLIFailure(exitCode: .requestFailed, message: "daemon is not installed as a LaunchAgent", hint: "run `patchwork daemon install` first")
        }
        let result = try runner.run("/bin/launchctl", ["kickstart", "-k", guiService()])
        guard result.exitCode == 0 else {
            throw CLIFailure(exitCode: .requestFailed, message: "launchctl kickstart -k failed: \(result.stderr.trimmedOrSelf())")
        }
    }

    private static func spawnDetached(binaryPath: String, logFile: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        // Deliberately not waiting: this is a best-effort session-only launch. `daemon install`
        // is the supported way to survive logout or a crash.
    }
}

extension String {
    func trimmedOrSelf() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self : trimmed
    }
}
