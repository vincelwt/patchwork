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
}

/// Pure classification of a session's liveness. Sessions started in any terminal are detected
/// from their JSONL file alone: mtime age plus the last complete entry.
enum SessionActivityClassifier {
    /// A write this recent means Pi is mid-turn regardless of what the entry says.
    static let recentWriteWindow: TimeInterval = 6
    /// Older than this and nothing is running, whatever the last entry looks like.
    static let idleWindow: TimeInterval = 90
    /// Only the tail is read, never the whole file.
    static let tailByteLimit = 256 * 1_024

    static let terminalStopReasons: Set<String> = ["stop", "length", "error", "aborted"]

    static func classify(lastEntry: JSONValue?, age: TimeInterval) -> SessionRunState {
        if age > idleWindow { return .idle }
        if age <= recentWriteWindow { return .running }
        guard let entry = lastEntry else { return .unknown }

        let type = entry["type"]?.stringValue
        if type == "bashExecution" { return .running }

        guard type == "message", let message = entry["message"] else { return .unknown }
        let role = message["role"]?.stringValue
        switch role {
        case "user", "toolResult", "bashExecution":
            // Pi has just been handed work, or a tool has just answered: the turn continues.
            return .running
        case "assistant":
            let stopReason = message["stopReason"]?.stringValue
            if stopReason == "toolUse" { return .running }
            if let stopReason, terminalStopReasons.contains(stopReason) { return .idle }
            return .unknown
        default:
            return .unknown
        }
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
        return SessionActivity(state: state, modifiedAt: modifiedAt, runningSince: state == .running ? modifiedAt : nil)
    }
}

/// Stat-then-tail activity monitor for every discovered session file. Sessions running in any
/// terminal drive the sidebar spinner, live modification times, and the menu bar list.
///
/// Cost control: one shared 2s timer that only runs while the app is active, `stat` for every
/// tracked path, and a bounded tail read only for files whose fingerprint changed and whose
/// mtime is recent. Nothing is ever re-read in full and no timer is created per row.
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

    /// `isActiveOverride` keeps the monitor deterministic in tests without an app instance.
    init(isActiveOverride: Bool? = nil) {
        self.isActiveOverride = isActiveOverride
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

        let result = await Task.detached(priority: .utility) { () -> ([String: SessionActivity], [String: Fingerprint]) in
            let now = Date()
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
                let age = now.timeIntervalSince(modifiedAt)

                // An old file is idle from its mtime alone; no read at all.
                if age > SessionActivityClassifier.idleWindow {
                    states[path] = SessionActivity(state: .idle, modifiedAt: modifiedAt)
                    continue
                }

                let unchanged = known[path] == fingerprint
                if unchanged, let cached = previous[path] {
                    // Re-evaluate the age-based verdict without touching the file again.
                    let state = SessionActivityClassifier.classify(
                        lastEntry: nil,
                        age: age
                    )
                    let resolved = state == .unknown ? cached.state : state
                    states[path] = SessionActivity(
                        state: resolved,
                        modifiedAt: modifiedAt,
                        runningSince: resolved == .running ? (cached.runningSince ?? modifiedAt) : nil
                    )
                    continue
                }

                guard tailReads < limit else {
                    states[path] = previous[path] ?? SessionActivity(state: .unknown, modifiedAt: modifiedAt)
                    continue
                }
                tailReads += 1
                let entry = SessionActivityClassifier.readTail(at: url)
                    .flatMap(SessionActivityClassifier.lastEntry(inTail:))
                let state = SessionActivityClassifier.classify(lastEntry: entry, age: age)
                states[path] = SessionActivity(
                    state: state,
                    modifiedAt: modifiedAt,
                    runningSince: state == .running ? (previous[path]?.runningSince ?? modifiedAt) : nil
                )
            }
            return (states, stamps)
        }.value

        fingerprints = result.1
        if activities != result.0 { activities = result.0 }
    }

    deinit { pollTask?.cancel() }
}
