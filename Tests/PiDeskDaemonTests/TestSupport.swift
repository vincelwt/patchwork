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

final class FakeThreadRPCService: ThreadRPCServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _created = 0
    private var _createdCwds: [URL] = []
    private var _modelSets: [(String, String)] = []
    private var _thinkingSets: [String] = []
    private var _agents: [AgentKind] = []
    var created: Int { lock.lock(); defer { lock.unlock() }; return _created }
    var createdCwds: [URL] { lock.lock(); defer { lock.unlock() }; return _createdCwds }
    var modelSets: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _modelSets }
    var thinkingSets: [String] { lock.lock(); defer { lock.unlock() }; return _thinkingSets }
    /// Which agent each call asked for, so a test can prove the thread's own agent was used.
    var agents: [AgentKind] { lock.lock(); defer { lock.unlock() }; return _agents }

    let thread: PiThread
    var runtime: ThreadRuntimeState

    init(thread: PiThread, runtime: ThreadRuntimeState = ThreadRuntimeState()) {
        self.thread = thread
        self.runtime = runtime
    }

    func createIdle(agent: AgentKind, cwd: URL, name: String?) async throws -> PiThread {
        recordAgent(agent)
        recordCreate(cwd: cwd)
        var created = thread
        created.cwd = cwd.standardizedFileURL.path
        created.folder = cwd.lastPathComponent
        return created
    }

    func rename(agent: AgentKind, cwd: URL, sessionPath: URL, name: String) async throws {
        recordAgent(agent)
    }

    func runtimeSnapshot(agent: AgentKind, cwd: URL, sessionPath: URL) async throws -> ThreadRuntimeState {
        recordAgent(agent)
        return runtime
    }

    func setModel(agent: AgentKind, cwd: URL, sessionPath: URL, provider: String, modelId: String) async throws -> ThreadRuntimeState {
        recordAgent(agent)
        recordModel(provider, modelId)
        runtime.provider = provider
        runtime.modelId = modelId
        return runtime
    }

    func setThinkingLevel(agent: AgentKind, cwd: URL, sessionPath: URL, level: String) async throws -> ThreadRuntimeState {
        recordAgent(agent)
        recordThinking(level)
        runtime.thinkingLevel = level
        return runtime
    }

    private func recordAgent(_ agent: AgentKind) {
        lock.lock(); _agents.append(agent); lock.unlock()
    }

    private func recordCreate(cwd: URL) {
        lock.lock(); _created += 1; _createdCwds.append(cwd); lock.unlock()
    }
    private func recordModel(_ provider: String, _ modelId: String) {
        lock.lock(); _modelSets.append((provider, modelId)); lock.unlock()
    }
    private func recordThinking(_ level: String) {
        lock.lock(); _thinkingSets.append(level); lock.unlock()
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
        schedulerRetryDelays: [TimeInterval] = Scheduler.defaultRetryDelays,
        networkAvailable: @escaping @Sendable () -> Bool = { true },
        interactions: InteractionRegistry = InteractionRegistry(),
        liveSessions: LiveSessionRegistry = LiveSessionRegistry(),
        threadRPC: ThreadRPCServing? = nil,
        /// Seeds another agent's session tree. Pinning Pi's root pins every root, so a test that
        /// wants a Codex or Claude thread has to say so explicitly.
        extraSessionRoots: [(agent: AgentKind, url: URL)] = []
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
            sessionRoots: extraSessionRoots.isEmpty ? nil : [(AgentKind.pi, sessionRoot)] + extraSessionRoots,
            activityDirectoryURL: activityDirectory,
            schedulesFileURL: directory.appendingPathComponent("schedules.json"),
            runHistoryFileURL: directory.appendingPathComponent("runs.jsonl"),
            overlayFileURL: directory.appendingPathComponent("overlay.json"),
            schedulerPollInterval: schedulerPollInterval,
            schedulerRetryDelays: schedulerRetryDelays,
            networkAvailable: networkAvailable,
            interactions: interactions,
            liveSessions: liveSessions,
            threadRPC: threadRPC,
            // Never the real app's `state.json` or worktree root: fixtures must stay inside the
            // throwaway directory and no test may alter the user's managed worktrees.
            appStateURL: directory.appendingPathComponent("state.json"),
            worktreeRootURL: directory.appendingPathComponent("worktrees", isDirectory: true)
        )
    }

    /// Writes the app-owned parts of `state.json` this daemon reads (never writes).
    static func writeAppState(
        in directory: URL,
        folders: String = "[]",
        assignments: [String: String] = [:],
        projectAssignments: [String: String] = [:],
        archivedSessionIDs: [String] = []
    ) {
        let pairs = assignments.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let projectPairs = projectAssignments.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let archived = archivedSessionIDs.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"virtualFolders":\(folders),"virtualFolderAssignments":{\(pairs)},\
        "projectFolderAssignments":{\(projectPairs)},"archivedSessionIDs":[\(archived)]}
        """
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

extension TestSupport {
    /// A minimal Codex rollout, in the nested `YYYY/MM/DD` layout Codex actually writes.
    @discardableResult
    static func writeCodexRollout(in root: URL, id: String, cwd: String) -> URL {
        let directory = root.appendingPathComponent("2026/07/31", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-07-31T00-00-00-\(id).jsonl")
        let lines = [
            #"{"timestamp":"2026-07-31T00:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-07-31T00:00:00.000Z","thread_source":"user"}}"#,
            #"{"timestamp":"2026-07-31T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"a codex question"}]}}"#,
            #"{"timestamp":"2026-07-31T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a codex answer"}]}}"#
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
