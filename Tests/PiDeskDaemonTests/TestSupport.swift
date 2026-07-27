import Foundation
import PiDeskKit
@testable import PiDeskDaemon

/// Never spawns `pi`, never touches a real process \u2014 the fake runtime every scheduling/queueing/
/// timeout/status test in this target runs against, per the hard rule that no test may send a
/// provider prompt. `behavior` is swappable per test for success/failure/hang scenarios.
final class FakeRunExecutor: RunExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _executedJobs: [RunJob] = []
    var executedJobs: [RunJob] { lock.lock(); defer { lock.unlock() }; return _executedJobs }

    var behavior: @Sendable (RunJob) async -> RunOutcome

    init(behavior: @escaping @Sendable (RunJob) async -> RunOutcome = { _ in RunOutcome(status: .ok, error: nil, summary: "fake ok") }) {
        self.behavior = behavior
    }

    func execute(_ job: RunJob) async -> RunOutcome {
        record(job)
        return await behavior(job)
    }

    // A plain synchronous helper, not `lock()`/`unlock()` calls written directly inside an
    // `async` function body: `NSLock` is annotated unavailable there (an async function can in
    // general resume on a different thread than where it suspended, which is unsafe for a raw
    // OS lock held across a suspension point) even though this particular use never actually
    // suspends while holding it.
    private func record(_ job: RunJob) {
        lock.lock()
        _executedJobs.append(job)
        lock.unlock()
    }

    /// A behavior that never finishes on its own \u2014 only cooperative cancellation ends it \u2014 for
    /// exercising `RunManager`'s timeout race without a real hang.
    static func hanging(status: RunStatus = .timeout, tag: String = "cancelled") -> @Sendable (RunJob) async -> RunOutcome {
        { _ in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return RunOutcome(status: status, error: tag, summary: nil)
        }
    }
}

enum TestSupport {
    /// `/tmp` directly, not `FileManager.default.temporaryDirectory` (which resolves under the
    /// much longer `/var/folders/.../T/`): `sockaddr_un.sun_path` is capped at ~104 bytes on
    /// Darwin, and a Unix-socket-hosting test directory needs to fit a socket filename under
    /// that limit too.
    static func tempDirectory(_ name: String = #function) -> URL {
        let suffix = String(UUID().uuidString.prefix(8))
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("pd-\(suffix)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func logger(in directory: URL) -> DaemonLogger {
        DaemonLogger(fileURL: directory.appendingPathComponent("daemon.log"))
    }

    /// A fully wired `DaemonCore` rooted entirely under a fresh temp directory \u2014 schedules,
    /// run history, session root, overlay file \u2014 so tests never touch
    /// `~/Library/Application Support/Pi Desktop` or a real `~/.pi/agent/sessions`.
    static func makeCore(
        in directory: URL,
        executor: RunExecuting = FakeRunExecutor(),
        concurrency: Int = 2,
        schedulerPollInterval: TimeInterval = 1,
        interactions: InteractionRegistry = InteractionRegistry(),
        liveSessions: LiveSessionRegistry = LiveSessionRegistry()
    ) -> DaemonCore {
        let settings = DaemonSettings(remoteEnabled: false, port: 0, concurrency: concurrency)
        let sessionRoot = directory.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        // A real `~/.pi/agent/desktop-activity` can (and, on a machine with other agents active,
        // will) contain real heartbeats; every test must read a directory of its own instead.
        let activityDirectory = directory.appendingPathComponent("activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: activityDirectory, withIntermediateDirectories: true)
        return DaemonCore(
            settings: settings,
            logger: logger(in: directory),
            executor: executor,
            sessionRootURL: sessionRoot,
            activityDirectoryURL: activityDirectory,
            schedulesFileURL: directory.appendingPathComponent("schedules.json"),
            runHistoryFileURL: directory.appendingPathComponent("runs.jsonl"),
            overlayFileURL: directory.appendingPathComponent("overlay.json"),
            schedulerPollInterval: schedulerPollInterval,
            interactions: interactions,
            liveSessions: liveSessions,
            // Never the real app's `state.json`: the folder endpoint must read a fixture, and
            // nothing here may depend on how the machine running the tests organises its own
            // conversations.
            appStateURL: directory.appendingPathComponent("state.json")
        )
    }

    /// Writes the app-owned parts of `state.json` this daemon reads (never writes).
    static func writeAppState(in directory: URL, folders: String = "[]", assignments: [String: String] = [:]) {
        let pairs = assignments.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let json = "{\"virtualFolders\":\(folders),\"virtualFolderAssignments\":{\(pairs)}}"
        try? json.write(to: directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    static func writeSessionFile(in directory: URL, id: String = "sess-\(UUID().uuidString)", cwd: String, lines extra: [String] = [], name: String? = nil) -> URL {
        let sessionRoot = directory.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let url = sessionRoot.appendingPathComponent("\(id).jsonl")
        var lines = [#"{"type":"session","id":"\#(id)","cwd":"\#(cwd)"}"#]
        if let name { lines.append(#"{"type":"session_info","id":"info","name":"\#(name)"}"#) }
        lines.append(contentsOf: extra)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
