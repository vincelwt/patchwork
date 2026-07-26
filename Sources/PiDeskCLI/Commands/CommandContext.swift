import Darwin
import Foundation
import PiDeskKit

/// Raw dependencies that differ between a live run and a test run. `CLIRunner.run` turns this
/// into a `CommandContext` after a quick scan of argv for `--json`/`--quiet` (needed before any
/// command-specific parsing, so even a usage error prints in the right shape).
struct CLIHost {
    var environment: [String: String]
    var writeOut: (String) -> Void
    var writeErr: (String) -> Void
    var isTTY: Bool
    var makeControlPlane: (GlobalOptions) -> ControlPlane
    var shellRunner: ShellRunning
    var fileManager: FileManager
    var now: () -> Date
    /// Bounded stdin read, used by `threads send <id> -` to take message text from a pipe.
    var readStdin: (Int) -> Data
    /// Local-storage paths `remote`/`daemon logs` touch directly (no HTTP endpoint covers them;
    /// see RemoteCommand.swift). Defaulted to the real locations in `.live()`, overridden with
    /// temp paths in tests so nothing ever touches the user's real Application Support directory.
    var daemonSettingsPath: URL
    var tokenFilePath: URL
    var logFilePath: URL
    /// Where Pi Desktop.app records that *it* started the currently-running `pi-deskd`, if it
    /// did — `daemon status`'s only source for telling "app-managed" apart from "reachable, but
    /// nobody we recognise started it". See `DaemonSupervisionRules.swift`.
    var daemonOwnerFilePath: URL

    static func live() -> CLIHost {
        CLIHost(
            environment: ProcessInfo.processInfo.environment,
            writeOut: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeErr: { FileHandle.standardError.write(Data($0.utf8)) },
            isTTY: isatty(STDOUT_FILENO) != 0,
            makeControlPlane: { options in HTTPControlPlane(target: options.target, token: options.token, timeout: options.timeoutSeconds) },
            shellRunner: SystemShellRunner(),
            fileManager: .default,
            now: Date.init,
            readStdin: { maxBytes in FileHandle.standardInput.readData(ofLength: maxBytes) },
            daemonSettingsPath: PiDeskPaths.daemonSettings,
            tokenFilePath: PiDeskPaths.tokenFile,
            logFilePath: PiDeskPaths.logFile,
            daemonOwnerFilePath: DaemonOwnership.fileURL()
        )
    }
}

/// Everything a command needs to do its work, already carrying the one `OutputSink` for this
/// invocation.
struct CommandContext {
    var environment: [String: String]
    var makeControlPlane: (GlobalOptions) -> ControlPlane
    var shellRunner: ShellRunning
    var fileManager: FileManager
    var now: () -> Date
    var readStdin: (Int) -> Data
    var out: OutputSink
    var daemonSettingsPath: URL
    var tokenFilePath: URL
    var logFilePath: URL
    var daemonOwnerFilePath: URL
}
