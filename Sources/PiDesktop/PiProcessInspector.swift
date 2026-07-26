import Foundation

/// One candidate process from a `ps` snapshot: its executable name matches, not yet confirmed
/// to own a tracked session's working directory.
struct PiProcessCandidate: Equatable, Sendable {
    let pid: Int32
    let command: String
}

/// Parses raw `ps`/`lsof` text. Kept free of `Process` entirely so tests can feed canned output
/// without ever shelling out.
enum ProcessSnapshotParser {
    /// `ps -axo pid=,comm=,args=`: pid, comm, then the full argument vector, which itself
    /// contains spaces — so only the first two splits are meaningful.
    static func candidates(fromPSOutput output: String) -> [PiProcessCandidate] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> PiProcessCandidate? in
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]) else { return nil }
            let command = String(fields[1])
            let arguments = fields.count > 2 ? String(fields[2]) : command
            guard isPiProcess(command: command, arguments: arguments) else { return nil }
            return PiProcessCandidate(pid: pid, command: command)
        }
    }

    /// The installed CLI is a Node script, so a live agent normally reports `comm` as `node`
    /// with `pi` only visible in its arguments (`node /Users/…/.local/bin/pi --mode rpc`).
    /// Matching `comm` alone silently found nothing and made every session look idle.
    static func isPiProcess(command: String, arguments: String) -> Bool {
        if (command as NSString).lastPathComponent == "pi" { return true }
        guard interpreters.contains((command as NSString).lastPathComponent) else { return false }
        return arguments.split(separator: " ", omittingEmptySubsequences: true).contains { token in
            // Only a real path to the executable counts, so an unrelated `pi` word in a
            // command line cannot masquerade as the agent.
            token.contains("/") && (String(token) as NSString).lastPathComponent == "pi"
        }
    }

    /// Runtimes the Pi CLI is launched through.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "npx", "tsx"]

    /// `lsof -a -p <pid> -d cwd -Fn`: machine-readable field lines. The cwd is the one line
    /// starting with `n`.
    static func cwd(fromLsofOutput output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }
}

/// The only piece that actually shells out; isolated behind a protocol so `PiProcessInspector`
/// is deterministically testable with a canned snapshot instead of real processes.
protocol ProcessSnapshotProviding: Sendable {
    func psOutput() -> String?
    func cwd(forPID pid: Int32) -> String?
}

struct LiveProcessSnapshotProvider: ProcessSnapshotProviding {
    func psOutput() -> String? {
        Self.run("/bin/ps", ["-axo", "pid=,comm=,args="], timeout: 2)
    }

    func cwd(forPID pid: Int32) -> String? {
        guard let output = Self.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 1) else { return nil }
        return ProcessSnapshotParser.cwd(fromLsofOutput: output)
    }

    /// Reads stdout before waiting on exit (the correct order for a pipe of unknown size), and
    /// terminates the child once `timeout` elapses so one hung `lsof` cannot stall a refresh.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}

/// Enumerates live `pi` agent processes and their working directories so the activity monitor
/// can cross-check its file-based verdict against reality. Every OS call happens off the main
/// actor inside a detached task; only the cheap cached-snapshot assignment touches it.
@MainActor
final class PiProcessInspector {
    /// Long enough that a burst of sidebar renders shares one snapshot, short enough that a
    /// process which just quit is noticed almost immediately.
    nonisolated static let cacheTTL: TimeInterval = 4
    /// However many `pi`-named processes exist, only this many have their cwd resolved per
    /// refresh, so a pathological process count cannot turn into a burst of `lsof` calls.
    nonisolated static let maxResolvedPerRefresh = 24

    /// Standardized cwd paths of every live Pi process as of the last successful refresh. `nil`
    /// means inspection has never once succeeded — callers fall back to the file-only heuristic
    /// instead of treating every session as idle.
    private(set) var liveCwds: Set<String>?

    private let snapshotProvider: ProcessSnapshotProviding
    private var lastRefresh: Date = .distantPast
    private var refreshTask: Task<Void, Never>?

    init(snapshotProvider: ProcessSnapshotProviding = LiveProcessSnapshotProvider()) {
        self.snapshotProvider = snapshotProvider
    }

    /// Cheap to call every tick: only actually schedules background work once the cache expires,
    /// and never overlaps a refresh already in flight.
    func refreshIfNeeded(now: Date = Date()) {
        guard refreshTask == nil, now.timeIntervalSince(lastRefresh) >= Self.cacheTTL else { return }
        lastRefresh = now
        let provider = snapshotProvider
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let cwds = Self.snapshot(using: provider)
            await self?.apply(cwds)
        }
    }

    private func apply(_ cwds: Set<String>?) {
        // A failed attempt (nil) keeps the previous cache rather than blanking it, so one
        // transient `ps` failure cannot flip every tracked session to the degraded fallback.
        if let cwds { liveCwds = cwds }
        refreshTask = nil
    }

    nonisolated private static func snapshot(using provider: ProcessSnapshotProviding) -> Set<String>? {
        guard let output = provider.psOutput() else { return nil }
        let candidates = ProcessSnapshotParser.candidates(fromPSOutput: output).prefix(maxResolvedPerRefresh)
        var cwds: Set<String> = []
        for candidate in candidates {
            guard let cwd = provider.cwd(forPID: candidate.pid) else { continue }
            cwds.insert(URL(fileURLWithPath: cwd).standardizedFileURL.path)
        }
        return cwds
    }
}
