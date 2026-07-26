import AppKit
import Combine
import Foundation

/// How a session file's tail classifies right now.
enum SessionRunState: String, Equatable, Sendable {
    case running
    case idle
    case unknown
}

struct SessionActivity: Equatable, Sendable {
    var state: SessionRunState
    var modifiedAt: Date
    /// When the file last transitioned into `running`, used for the menu bar's elapsed label.
    var runningSince: Date?
    /// The last entry's assistant stop reason, when known. Lets a notification distinguish a
    /// clean finish from an error/abort without re-reading the file.
    var lastStopReason: String?
    /// A short bounded preview of the last assistant text, when a heartbeat supplied one. Used
    /// only to enrich a cross-terminal "turn finished" notification; never re-derived by reading
    /// the whole file.
    var preview: String?
}

/// Pure classification of a session's liveness from its JSONL file alone (mtime plus the last
/// complete entry), used only as a fallback for sessions with no activity heartbeat: an older
/// session, or one running under a Pi build without the `pi-desktop-activity` extension
/// installed yet.
enum SessionActivityClassifier {
    /// A write this recent means Pi is mid-turn, unless the entry itself already says the turn
    /// is over.
    static let recentWriteWindow: TimeInterval = 6
    /// A non-terminal entry older than this without a further write is presumed stalled (e.g. a
    /// killed terminal), rather than waiting for the full idle window.
    static let staleNonTerminalWindow: TimeInterval = 15
    /// Older than this and nothing is running, whatever the last entry looks like.
    static let idleWindow: TimeInterval = 90
    /// Only the tail is read, never the whole file.
    static let tailByteLimit = 256 * 1_024

    static let terminalStopReasons: Set<String> = ["stop", "length", "error", "aborted"]

    static func classify(lastEntry: JSONValue?, age: TimeInterval) -> SessionRunState {
        if age > idleWindow { return .idle }
        // A killed-and-relaunched terminal can leave a fresh mtime behind an already-settled
        // turn; the stop reason must win even over a very recent write.
        if isTerminalStop(lastEntry) { return .idle }
        if age <= recentWriteWindow { return .running }
        guard age <= staleNonTerminalWindow else { return .idle }

        guard let entry = lastEntry else { return .unknown }
        let type = entry["type"]?.stringValue
        if type == "bashExecution" { return .running }

        guard type == "message", let message = entry["message"] else { return .unknown }
        switch message["role"]?.stringValue {
        case "user", "toolResult", "bashExecution":
            // Pi has just been handed work, or a tool has just answered: the turn continues.
            return .running
        case "assistant":
            // A terminal stop reason already returned above; only toolUse or an absent reason
            // (still streaming) remain.
            return message["stopReason"]?.stringValue == "toolUse" ? .running : .unknown
        default:
            return .unknown
        }
    }

    /// The assistant stop reason of the last entry, when there is one. Threaded through
    /// `SessionActivity` so the monitor and notifications can tell a clean finish from an
    /// error/abort without re-parsing the tail a second time.
    static func stopReason(ofLastEntry entry: JSONValue?) -> String? {
        guard entry?["type"]?.stringValue == "message",
              let message = entry?["message"], message["role"]?.stringValue == "assistant" else { return nil }
        return message["stopReason"]?.stringValue
    }

    private static func isTerminalStop(_ entry: JSONValue?) -> Bool {
        guard let stopReason = stopReason(ofLastEntry: entry) else { return false }
        return terminalStopReasons.contains(stopReason)
    }

    /// Extracts the last decodable JSONL record from a tail buffer, tolerating a partially
    /// written final line.
    static func lastEntry(inTail tail: Data) -> JSONValue? {
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed().prefix(4) {
            var record = Data(line)
            if record.last == 0x0D { record.removeLast() }
            guard !record.isEmpty, let value = try? JSONValue.decode(record) else { continue }
            return value
        }
        return nil
    }

    /// Reads at most `tailByteLimit` from the end of the file.
    static func readTail(at url: URL, limit: Int = tailByteLimit) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(limit) ? end - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: limit)
    }

    /// Full single-file classification. `URL` caches resource values, so a fresh URL is used to
    /// guarantee the mtime reflects the file as it is right now.
    static func classifyFile(at url: URL, now: Date = Date()) -> SessionActivity? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modifiedAt = values.contentModificationDate else { return nil }
        let age = now.timeIntervalSince(modifiedAt)
        // Old files never get read: their mtime alone settles it.
        if age > idleWindow { return SessionActivity(state: .idle, modifiedAt: modifiedAt) }
        let entry = readTail(at: fresh).flatMap(lastEntry(inTail:))
        let state = classify(lastEntry: entry, age: age)
        return SessionActivity(
            state: state,
            modifiedAt: modifiedAt,
            runningSince: state == .running ? modifiedAt : nil,
            lastStopReason: stopReason(ofLastEntry: entry)
        )
    }
}

/// Stat-then-tail activity monitor for every discovered session file. Sessions running in any
/// terminal drive the sidebar spinner, live modification times, and the menu bar list.
///
/// Run state has two independent sources, resolved fresh every tick:
///  1. **Activity heartbeats** (`ActivityHeartbeatStore`) — authoritative when present: a
///     session whose Pi process has the `pi-desktop-activity` extension loaded writes its own
///     running/idle state, so this needs no guessing at all.
///  2. **The file heuristic** above — the fallback for sessions with no heartbeat (extension not
///     installed yet, or an older/ephemeral session).
///
/// A session only ever uses one source at a time; there is no second signal layered on top to
/// second-guess the first (that cross-check — matching live `pi` processes by working directory
/// — was the previous design and is exactly what caused sessions to flicker between running and
/// idle: process matching does not work at all against Pi's process title, and cwd matching is
/// wrong regardless since several sessions can share one directory). When neither source can
/// produce a confident verdict, the previous resolved state is kept rather than guessing
/// (`.unknown` is sticky), so a momentary gap in the data can never look like a flip.
///
/// Cost control: one shared 2s timer that only runs while the app is active, `stat` for every
/// tracked path, one heartbeat-directory scan per tick, and a bounded tail read only for files
/// whose fingerprint changed and whose mtime is recent. Nothing is ever re-read in full and no
/// timer is created per row.
@MainActor
final class SessionActivityMonitor: ObservableObject {
    @Published private(set) var activities: [String: SessionActivity] = [:]

    static let pollInterval: TimeInterval = 2
    /// Upper bound on tail reads per tick, so a burst of concurrent sessions stays cheap.
    static let tailReadsPerTick = 16

    private struct Fingerprint: Equatable, Sendable {
        let modifiedAt: TimeInterval
        let size: Int64
    }

    private var trackedPaths: [String] = []
    private var fingerprints: [String: Fingerprint] = [:]
    private var pollTask: Task<Void, Never>?
    private var tickInFlight = false
    private var cancellables: Set<AnyCancellable> = []
    private let isActiveOverride: Bool?
    private let heartbeatDirectory: URL
    private let isProcessAlive: @Sendable (Int32) -> Bool

    /// `isActiveOverride` keeps the monitor deterministic in tests without an app instance.
    /// `heartbeatDirectory` and `isProcessAlive` are test seams; production always uses the real
    /// `~/.pi/agent/desktop-activity` directory and a real `kill(pid, 0)` liveness check.
    init(
        isActiveOverride: Bool? = nil,
        heartbeatDirectory: URL = ActivityHeartbeatStore.defaultDirectory(),
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { ActivityHeartbeatClassifier.isProcessAlive(pid: $0) }
    ) {
        self.isActiveOverride = isActiveOverride
        self.heartbeatDirectory = heartbeatDirectory
        self.isProcessAlive = isProcessAlive
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.tickNow() }
            .store(in: &cancellables)
    }

    private var isApplicationActive: Bool { isActiveOverride ?? NSApplication.shared.isActive }

    func setTrackedPaths(_ paths: [String]) {
        let unique = Array(Set(paths))
        guard unique != trackedPaths else { return }
        trackedPaths = unique
        let live = Set(unique)
        activities = activities.filter { live.contains($0.key) }
        fingerprints = fingerprints.filter { live.contains($0.key) }
        tickNow()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func tickNow() {
        Task { [weak self] in await self?.tick() }
    }

    func activity(forPath path: String) -> SessionActivity? { activities[path] }

    private func tick() async {
        // Paused entirely while the app is inactive; a background app must not poll the disk.
        guard isApplicationActive, !trackedPaths.isEmpty, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        let paths = trackedPaths
        let known = fingerprints
        let previous = activities
        let limit = Self.tailReadsPerTick
        let heartbeatDirectory = heartbeatDirectory
        let isProcessAlive = isProcessAlive

        let result = await Task.detached(priority: .utility) { () -> ([String: SessionActivity], [String: Fingerprint]) in
            let now = Date()
            let heartbeats = ActivityHeartbeatStore.scan(directory: heartbeatDirectory)
            var states: [String: SessionActivity] = [:]
            var stamps: [String: Fingerprint] = [:]
            var tailReads = 0

            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modifiedAt = values.contentModificationDate else { continue }
                let fingerprint = Fingerprint(
                    modifiedAt: modifiedAt.timeIntervalSince1970,
                    size: Int64(values.fileSize ?? 0)
                )
                stamps[path] = fingerprint

                if let writers = heartbeats[path] {
                    // An attached RPC process is idle while the terminal that owns the same
                    // session may still be working. Heartbeats are per writer, so any fresh,
                    // live "running" writer wins; an idle attachment cannot erase it.
                    let running = writers.contains {
                        ActivityHeartbeatClassifier.isRunning($0, now: now, isProcessAlive: isProcessAlive)
                    }
                    let newest = writers.max {
                        (Date.piDate($0.updatedAt) ?? .distantPast) < (Date.piDate($1.updatedAt) ?? .distantPast)
                    }
                    let resolved: SessionRunState = running ? .running : .idle
                    states[path] = SessionActivity(
                        state: resolved,
                        modifiedAt: modifiedAt,
                        runningSince: resolved == .running ? (previous[path]?.runningSince ?? modifiedAt) : nil,
                        lastStopReason: newest?.stopReason ?? previous[path]?.lastStopReason,
                        preview: newest?.preview ?? previous[path]?.preview
                    )
                    continue
                }

                // No heartbeat for this session: fall back to the file heuristic exactly as
                // before heartbeats existed.
                let age = now.timeIntervalSince(modifiedAt)
                if age > SessionActivityClassifier.idleWindow {
                    states[path] = SessionActivity(state: .idle, modifiedAt: modifiedAt)
                    continue
                }

                let unchanged = known[path] == fingerprint
                let fileState: SessionRunState
                let entry: JSONValue?
                if unchanged {
                    entry = nil
                    fileState = SessionActivityClassifier.classify(lastEntry: nil, age: age)
                } else if tailReads < limit {
                    tailReads += 1
                    entry = SessionActivityClassifier.readTail(at: url).flatMap(SessionActivityClassifier.lastEntry(inTail:))
                    fileState = SessionActivityClassifier.classify(lastEntry: entry, age: age)
                } else {
                    // Over budget for this tick: keep the last known verdict rather than
                    // guessing, exactly like the sticky-unknown rule below.
                    states[path] = previous[path] ?? SessionActivity(state: .unknown, modifiedAt: modifiedAt)
                    continue
                }

                // Sticky unknown: an ambiguous read never overrides a previously known verdict,
                // so a throttled tail read or a file mid-write can never look like a flip
                // between running and idle.
                let resolved = fileState == .unknown ? (previous[path]?.state ?? .unknown) : fileState
                states[path] = SessionActivity(
                    state: resolved,
                    modifiedAt: modifiedAt,
                    runningSince: resolved == .running ? (previous[path]?.runningSince ?? modifiedAt) : nil,
                    lastStopReason: unchanged ? previous[path]?.lastStopReason : SessionActivityClassifier.stopReason(ofLastEntry: entry),
                    preview: previous[path]?.preview
                )
            }
            return (states, stamps)
        }.value

        fingerprints = result.1
        if activities != result.0 { activities = result.0 }
    }

    deinit { pollTask?.cancel() }
}
