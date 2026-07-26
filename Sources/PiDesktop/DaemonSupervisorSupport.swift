import Darwin
import Foundation
import PiDeskKit

// Every effectful dependency `DaemonSupervisor` needs, each behind a protocol so a test never
// has to fork a real `pi-deskd` to exercise the decision logic around them. The pure decisions
// themselves (mode classification, ownership, restart backoff) are the tested reference in
// `Sources/PiDeskCLI/Support/DaemonSupervisionRules.swift`; SwiftPM will not let this executable
// target import that one, so the types below are a small, deliberately literal mirror — the same
// trade-off `PiDeskKit.PiLocator` already documents against the app's own `PiLocator`.

/// Spawns the bundled daemon binary. `SystemDaemonProcessSpawner` is the only production
/// implementation; tests substitute a fake so this never forks a real process.
protocol DaemonProcessSpawning {
    func spawn(binary: URL) throws -> DaemonSpawnedProcess
}

/// A running daemon process, from the spawner's point of view. Only `pid` is used for
/// supervision decisions after launch — every liveness/stop decision goes through raw pid
/// signalling (`kill`), not this object, because a daemon adopted from a previous run of the app
/// (still alive after a crash) never has a live `Process` handle to begin with.
protocol DaemonSpawnedProcess: AnyObject {
    var pid: Int32 { get }
}

/// Probes whether *something* is answering the control socket. Does not distinguish who —
/// `DaemonOwnerFile` plus a LaunchAgent probe are what tells app-managed apart from LaunchAgent
/// apart from external.
protocol DaemonHealthProbing {
    func probe() async -> Bool
}

/// Whether `dev.pi.desktop.daemon` is currently bootstrapped into the user's gui domain — the
/// signal that means "defer to it", regardless of what else might also be reachable.
protocol LaunchAgentProbing {
    func isLoaded() -> Bool
}

struct SystemDaemonProcessSpawner: DaemonProcessSpawning {
    let logFile: URL

    func spawn(binary: URL) throws -> DaemonSpawnedProcess {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }
        let process = Process()
        process.executableURL = binary
        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        // Its own process group: if this daemon ever has to be force-killed (it failed to exit
        // after a graceful SIGTERM — see `DaemonSupervisor.terminate(pid:timeout:)`), killing the
        // group takes any `pi` grandchild it spawned for a run with it, instead of orphaning it.
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        return LiveDaemonProcess(process: process)
    }
}

final class LiveDaemonProcess: DaemonSpawnedProcess {
    let process: Process
    var pid: Int32 { process.processIdentifier }
    init(process: Process) { self.process = process }
}

struct SocketHealthProbe: DaemonHealthProbing {
    func probe() async -> Bool {
        do {
            _ = try await PiDeskClient.unixSocket(requestTimeout: 2).health()
            return true
        } catch {
            return false
        }
    }
}

struct SystemLaunchAgentProbe: LaunchAgentProbing {
    static let label = "dev.pi.desktop.daemon"

    func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(Self.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Locates the bundled helper. Packaged: `Contents/Helpers/pi-deskd`, signed alongside the app
/// by `scripts/package-app.sh`. Dev (`swift run PiDesktop`): SwiftPM places every product in the
/// same `.build/<config>/` directory, so it also sits right next to the running `PiDesktop`
/// binary — the same "look next to the current executable first" rule
/// `DaemonControl.resolveBinaryPath` uses on the CLI side.
enum DaemonBinaryLocator {
    static func resolve(bundle: Bundle = .main, currentExecutablePath: String = ProcessInfo.processInfo.arguments[0], fileManager: FileManager = .default) -> URL? {
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/pi-deskd")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        let sibling = URL(fileURLWithPath: currentExecutablePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("pi-deskd")
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }
}

/// Mirrors `PiDeskCLI`'s `DaemonRunMode`/`DaemonModeClassifier` (see that file's header comment
/// for why this can't just be shared code) — the state `DaemonSupervisor.state` maps down to
/// when something outside the supervisor (Settings, `pidesk daemon status`) only needs "which of
/// the three documented modes is this".
enum DaemonRunMode: String {
    case appManaged, launchAgent, external, notRunning
}

/// Written whenever *this app* spawns `pi-deskd`, so a later launch (including after a crash) or
/// `pidesk daemon status` can tell "the app started this" from "reachable, but not by us" without
/// guessing. See docs/daemon-api.md's "Storage" table; mirrors
/// `PiDeskCLI.DaemonOwnerRecord`/`DaemonOwnership`.
struct DaemonOwnerRecord: Codable, Equatable {
    var pid: Int32
    var startedAt: Date
}

enum DaemonOwnerFile {
    static func read(from url: URL) -> DaemonOwnerRecord? {
        PiDeskFile.readIfPresent(DaemonOwnerRecord.self, from: url)
    }

    static func write(_ record: DaemonOwnerRecord, to url: URL) throws {
        try PiDeskFile.writeAtomic(record, to: url)
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// "Only stop what we started": trustworthy only while the pid is still alive. A dead or
    /// (rare) reused pid must never read as ours; the safe default on any doubt is "not ours".
    static func isLive(_ record: DaemonOwnerRecord?, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        guard let record else { return false }
        return isAlive(record.pid)
    }
}

/// Mirrors `PiDeskCLI.RestartPolicy` exactly (tested there; see this file's header comment).
enum RestartPolicy {
    static let baseDelaySeconds: TimeInterval = 2
    static let maxDelaySeconds: TimeInterval = 60
    static let maxAttempts = 5

    static func hasExhausted(failureCount: Int) -> Bool { failureCount > maxAttempts }

    static func delay(forFailureCount failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        return min(maxDelaySeconds, baseDelaySeconds * pow(2, Double(failureCount - 1)))
    }
}

/// Whether Pi Desktop.app should start/stop `pi-deskd` on its own. Kept as its own UserDefaults
/// flag (default on) rather than a `PersistedAppState` field, matching
/// `ActivityExtensionSettings` — a fresh install never depends on the archive/session schema, and
/// the Settings toggle is a single `defaults write` away from scripting.
enum DaemonSupervisorSettings {
    static let autoManageDefaultsKey = "PiDesktopDaemonAutoManageEnabled"

    static func autoManageEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoManageDefaultsKey) == nil ? true : defaults.bool(forKey: autoManageDefaultsKey)
    }

    static func setAutoManageEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: autoManageDefaultsKey)
    }
}
