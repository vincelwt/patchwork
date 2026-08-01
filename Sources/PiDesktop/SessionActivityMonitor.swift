import AppKit
import Combine
import Darwin
import Foundation
import PiDeskKit

/// How a session file's tail classifies right now.
enum SessionRunState: String, Equatable, Sendable {
    case running
    case idle
    case unknown
}

struct SessionActivity: Equatable, Sendable {
    var state: SessionRunState
    var modifiedAt: Date
    /// When the file last transitioned into `running`, used for sidebar and menu bar elapsed labels.
    var runningSince: Date?
    /// The newest completed assistant entry and its stop reason, when known. These are stable
    /// completion semantics; mtime and running/idle transitions never stand in for an answer.
    var latestCompletedEntryID: String?
    var lastStopReason: String?
    /// A short bounded preview paired with `latestCompletedEntryID` by a heartbeat. Used only to
    /// enrich a cross-terminal "turn finished" notification; never re-derived by reading the
    /// whole file.
    var preview: String?
    /// Live Pi process-tree usage, available only for heartbeat-backed running sessions.
    var resources: ThreadResourceUsage? = nil
}

/// Pure classification of a session's liveness from its JSONL file alone (mtime plus the last
/// complete entry), used only as a fallback for sessions with no activity heartbeat: an older
/// session, or one running under a Pi build without the `pi-desktop-activity` extension
/// installed yet.
enum SessionActivityClassifier {
    /// A write this recent means Pi is mid-turn, unless the entry itself already says the turn
    /// is over.
    static let recentWriteWindow = SessionFileActivityClassifier.recentWriteWindow
    /// A non-terminal entry older than this without a further write is presumed stalled (e.g. a
    /// killed terminal), rather than waiting for the full idle window.
    static let staleNonTerminalWindow = SessionFileActivityClassifier.staleNonTerminalWindow
    /// Older than this and nothing is running, whatever the last entry looks like.
    static let idleWindow = SessionFileActivityClassifier.idleWindow
    /// Only the tail is read, never the whole file.
    static let tailByteLimit = SessionFileActivityClassifier.tailByteLimit

    static let terminalStopReasons = SessionFileActivityClassifier.terminalStopReasons

    static func classify(
        lastEntry: JSONValue?, age: TimeInterval,
        hasNewerIncompleteRecord: Bool = false
    ) -> SessionRunState {
        switch SessionFileActivityClassifier.classify(
            lastEntry: lastEntry,
            age: age,
            hasNewerIncompleteRecord: hasNewerIncompleteRecord
        ) {
        case .running: .running
        case .idle: .idle
        case .unknown: .unknown
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

    /// Extracts the last decodable JSONL record from a tail buffer, tolerating a partially
    /// written final line.
    /// How far back to look for a record that means something. Pi writes almost only renderable
    /// entries, but an agent whose log is mostly bookkeeping (Codex writes token counts and
    /// world state constantly) can bury the last real entry well beyond the previous four lines,
    /// and giving up would report every busy Codex thread as idle.
    static let lastEntryScanLines = SessionFileActivityClassifier.lastEntryScanLines

    static func lastEntry(inTail tail: Data, transcoder: AgentSessionTranscoder = .pi) -> JSONValue? {
        SessionFileActivityClassifier.lastEntry(inTail: tail, transcoder: transcoder)
    }

    static func tailEvidence(
        inTail tail: Data, transcoder: AgentSessionTranscoder = .pi
    ) -> SessionFileTailEvidence {
        SessionFileActivityClassifier.tailEvidence(inTail: tail, transcoder: transcoder)
    }

    /// Reads at most `tailByteLimit` from the end of the file.
    static func readTail(at url: URL, limit: Int = tailByteLimit) -> Data? {
        SessionFileActivityClassifier.readTail(at: url, limit: limit)
    }

    /// Full single-file classification. `URL` caches resource values, so a fresh URL is used to
    /// guarantee the mtime reflects the file as it is right now.
    static func classifyFile(at url: URL, now: Date = Date()) -> SessionActivity? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modifiedAt = values.contentModificationDate else { return nil }
        let age = now.timeIntervalSince(modifiedAt)
        let transcoder = AgentSessionTranscoder.forSessionPath(url.path)
        let tail = readTail(at: fresh)
        let evidence = tail.map { tailEvidence(inTail: $0, transcoder: transcoder) }
            ?? SessionFileTailEvidence(lastEntry: nil, hasNewerIncompleteRecord: false)
        let entry = evidence.lastEntry
        let completion = tail.flatMap {
            SessionParser.latestTerminalAssistantCompletion(inTail: $0, transcoder: transcoder)
        }
        let state = classify(
            lastEntry: entry,
            age: age,
            hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
        )
        return SessionActivity(
            state: state,
            modifiedAt: modifiedAt,
            runningSince: state == .running ? modifiedAt : nil,
            latestCompletedEntryID: completion?.id,
            lastStopReason: completion?.stopReason ?? stopReason(ofLastEntry: entry)
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
/// Cost control: heartbeat-directory writes trigger an immediate shared scan; one fallback timer
/// runs every 2s while active and every 15s in the background. Each tick performs at most 16
/// bounded tail reads. Unchanged files reuse their last completion, and no timer is created per row.
@MainActor
final class SessionActivityMonitor: ObservableObject {
    @Published private(set) var activities: [String: SessionActivity] = [:]
    /// Includes live heartbeat-backed threads that have not reached the session scan yet, such as
    /// a newly-created automation run.
    @Published private(set) var hasRunningActivity = false
    /// The whole app process tree plus heartbeat-backed external conversations currently running.
    /// Resource samples are polled by the tiny sidebar labels instead of invalidating the whole window.
    private(set) var aggregateResources: ThreadResourceUsage?

    static let pollInterval: TimeInterval = 2
    static let backgroundPollInterval: TimeInterval = 15
    /// Upper bounds on fallback work per tick, so large histories do not cause periodic stat
    /// storms while heartbeat-backed sessions still update immediately.
    nonisolated static let fallbackStatsPerTick = 64
    nonisolated static let tailReadsPerTick = 16
    nonisolated static let maximumUrgentPaths = 4_096

    private struct Fingerprint: Equatable, Sendable {
        let modifiedAt: TimeInterval
        let size: Int64
    }

    private var trackedPaths: [String] = []
    private var fingerprints: [String: Fingerprint] = [:]
    private var heartbeatSnapshots: [String: [ActivityHeartbeat]] = [:]
    private var resourceSamples: [Int32: ProcessResourceSample] = [:]
    private var resourceUsageByPath: [String: ThreadResourceUsage] = [:]
    private var pollTask: Task<Void, Never>?
    private var heartbeatWatcher: DispatchSourceFileSystemObject?
    private var priorityFileWatcher: DispatchSourceFileSystemObject?
    private var priorityDirectoryWatcher: DispatchSourceFileSystemObject?
    private var priorityFileTickTask: Task<Void, Never>?
    private var incompleteTailRetryTask: Task<Void, Never>?
    private var priorityPath: String?
    private var tickInFlight = false
    private var tickPending = false
    private var fallbackCursor = 0
    private var urgentPaths: Set<String> = []
    /// Fresh incomplete appends may transiently mean "running". Retain a bounded deadline queue,
    /// but expose only one tail-read batch to any tick; this preserves exact expiry without ever
    /// turning a large burst into an all-catalog stat pass.
    private var incompleteTailRetryAtByPath: [String: Date] = [:]
    private var configurationRevision = 0
    private var cancellables: Set<AnyCancellable> = []
    private let isActiveOverride: Bool?
    private let heartbeatDirectory: URL
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let nowProvider: @Sendable () -> Date

    var incompleteTailPathCountForTesting: Int { incompleteTailRetryAtByPath.count }

    /// `isActiveOverride` keeps the monitor deterministic in tests without an app instance.
    /// `heartbeatDirectory` and `isProcessAlive` are test seams; production always uses the real
    /// `~/.pi/agent/desktop-activity` directory and a real `kill(pid, 0)` liveness check.
    init(
        isActiveOverride: Bool? = nil,
        heartbeatDirectory: URL = ActivityHeartbeatStore.defaultDirectory(),
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { ActivityHeartbeatClassifier.isProcessAlive(pid: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isActiveOverride = isActiveOverride
        self.heartbeatDirectory = heartbeatDirectory
        self.isProcessAlive = isProcessAlive
        nowProvider = now
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.tickNow() }
            .store(in: &cancellables)
    }

    private var isApplicationActive: Bool { isActiveOverride ?? NSApplication.shared.isActive }

    func setTrackedPaths(_ paths: [String]) {
        var seen: Set<String> = []
        let requested = paths.filter { seen.insert($0).inserted }
        let requestedSet = Set(requested)
        seen.removeAll(keepingCapacity: true)
        var unique = trackedPaths.filter { requestedSet.contains($0) && seen.insert($0).inserted }
        unique.append(contentsOf: requested.filter { seen.insert($0).inserted })
        guard unique != trackedPaths else { return }
        trackedPaths = unique
        configurationRevision &+= 1
        let live = Set(unique)
        if let priorityPath, !live.contains(priorityPath) { setPriorityPath(nil) }
        activities = activities.filter { live.contains($0.key) }
        fingerprints = fingerprints.filter { live.contains($0.key) }
        heartbeatSnapshots = heartbeatSnapshots.filter { live.contains($0.key) }
        resourceUsageByPath = resourceUsageByPath.filter { live.contains($0.key) }
        urgentPaths.formIntersection(live)
        incompleteTailRetryAtByPath = incompleteTailRetryAtByPath.filter { live.contains($0.key) }
        scheduleIncompleteTailRetry()
        if live.isEmpty {
            aggregateResources = nil
            resourceSamples.removeAll(keepingCapacity: false)
        }
        tickNow()
    }

    /// FSEvents points directly at external agent writes. Pull a bounded slice to the front of
    /// the next shared tick so a large history cannot delay its sidebar pulse by minutes.
    func prioritize(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let tracked = Set(trackedPaths)
        var normalizedPaths: Set<String> = []
        for path in paths {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if tracked.contains(normalizedPath) { normalizedPaths.insert(normalizedPath) }
        }
        enqueueUrgent(normalizedPaths)
        tickNow()
    }

    private func enqueueUrgent(_ paths: Set<String>) {
        for path in paths where urgentPaths.count < Self.maximumUrgentPaths {
            urgentPaths.insert(path)
        }
    }

    /// The conversation on screen is never left waiting behind the bounded round-robin scan.
    /// A file source also wakes the monitor shortly after an external terminal appends to it.
    func setPriorityPath(_ path: String?) {
        let normalized = path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard normalized != priorityPath else { return }
        priorityPath = normalized
        configurationRevision &+= 1
        priorityFileTickTask?.cancel()
        priorityFileTickTask = nil
        priorityFileWatcher?.cancel()
        priorityFileWatcher = nil
        priorityDirectoryWatcher?.cancel()
        priorityDirectoryWatcher = nil
        guard let normalized else {
            tickNow()
            return
        }
        installPriorityWatchers(at: normalized)
        tickNow()
    }

    private func installPriorityWatchers(at path: String) {
        installPriorityDirectoryWatcher(at: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        installPriorityFileWatcher(at: path)
    }

    private func installPriorityDirectoryWatcher(at path: String) {
        guard priorityDirectoryWatcher == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let terminal = priorityDirectoryWatcher?.data.intersection([.delete, .rename, .revoke]).isEmpty == false
            if terminal {
                priorityDirectoryWatcher?.cancel()
                priorityDirectoryWatcher = nil
            }
            if let priorityPath { installPriorityFileWatcher(at: priorityPath) }
            schedulePriorityFileTick()
        }
        source.setCancelHandler { close(descriptor) }
        priorityDirectoryWatcher = source
        source.resume()
    }

    private func installPriorityFileWatcher(at path: String) {
        guard priorityFileWatcher == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let terminal = priorityFileWatcher?.data.intersection([.delete, .rename, .revoke]).isEmpty == false
                if terminal {
                    priorityFileWatcher?.cancel()
                    priorityFileWatcher = nil
                }
                schedulePriorityFileTick()
            }
            source.setCancelHandler { close(descriptor) }
            priorityFileWatcher = source
            source.resume()
        }
    }

    private func schedulePriorityFileTick() {
        priorityFileTickTask?.cancel()
        priorityFileTickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.tickNow()
        }
    }

    func start() {
        startHeartbeatWatcher()
        scheduleIncompleteTailRetry()
        if let priorityPath { installPriorityWatchers(at: priorityPath) }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                guard let active = self?.isApplicationActive else { return }
                let interval = active ? Self.pollInterval : Self.backgroundPollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        heartbeatWatcher?.cancel()
        heartbeatWatcher = nil
        priorityFileTickTask?.cancel()
        priorityFileTickTask = nil
        incompleteTailRetryTask?.cancel()
        incompleteTailRetryTask = nil
        priorityFileWatcher?.cancel()
        priorityFileWatcher = nil
        priorityDirectoryWatcher?.cancel()
        priorityDirectoryWatcher = nil
    }

    private func startHeartbeatWatcher() {
        guard heartbeatWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: heartbeatDirectory, withIntermediateDirectories: true)
        let descriptor = open(heartbeatDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let directoryMoved = self.heartbeatWatcher?.data.contains(.delete) == true
                || self.heartbeatWatcher?.data.contains(.rename) == true
            self.tickNow()
            if directoryMoved {
                self.heartbeatWatcher?.cancel()
                self.heartbeatWatcher = nil
                self.startHeartbeatWatcher()
            }
        }
        source.setCancelHandler { close(descriptor) }
        heartbeatWatcher = source
        source.resume()
    }

    func tickNow() {
        Task { [weak self] in await self?.tick() }
    }

    private func scheduleIncompleteTailRetry(hasDuePaths: Bool = false) {
        incompleteTailRetryTask?.cancel()
        incompleteTailRetryTask = nil
        guard let earliest = incompleteTailRetryAtByPath.values.min() else { return }
        let delay: TimeInterval = hasDuePaths
            ? 0.01
            : max(0.01, earliest.timeIntervalSinceNow)
        incompleteTailRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tickNow()
        }
    }

    func activity(forPath path: String) -> SessionActivity? {
        guard var activity = activities[path] else { return nil }
        activity.resources = resourceUsageByPath[path]
        return activity
    }

    nonisolated static func heartbeatPathsRequiringPoll(
        paths: [String],
        heartbeats: [String: [ActivityHeartbeat]],
        previousHeartbeats: [String: [ActivityHeartbeat]],
        previousActivities: [String: SessionActivity]
    ) -> Set<String> {
        Set(paths.filter { path in
            guard let writers = heartbeats[path] else { return previousHeartbeats[path] != nil }
            let completionIDs = Set(writers.compactMap(\.completionId))
            return previousHeartbeats[path] != writers
                || previousActivities[path] == nil
                || previousActivities[path]?.state == .running
                || completionIDs.count != 1
        })
    }

    nonisolated static func pollSelection(
        paths: [String],
        heartbeatPaths: Set<String>,
        priorityPaths: Set<String> = [],
        fallbackCursor: Int
    ) -> (paths: [String], nextCursor: Int) {
        let prioritizedFallback = Set(paths.lazy.filter {
            priorityPaths.contains($0) && !heartbeatPaths.contains($0)
        }.prefix(fallbackStatsPerTick))
        let fallback = paths.filter {
            !heartbeatPaths.contains($0) && !prioritizedFallback.contains($0)
        }
        guard !fallback.isEmpty else {
            return (paths.filter { heartbeatPaths.contains($0) || prioritizedFallback.contains($0) }, 0)
        }
        let start = fallbackCursor % fallback.count
        let count = min(max(0, fallbackStatsPerTick - prioritizedFallback.count), fallback.count)
        let selectedFallback = Set((0..<count).map { fallback[(start + $0) % fallback.count] })
        return (
            paths.filter {
                heartbeatPaths.contains($0)
                    || prioritizedFallback.contains($0)
                    || selectedFallback.contains($0)
            },
            (start + count) % fallback.count
        )
    }

    /// Focus is the hard latency guarantee, then FSEvent writes, then short incomplete-tail
    /// retries. Stable input order is preserved inside each tier and every path appears once.
    nonisolated static func orderedPollPaths(
        _ paths: [String],
        focusedPath: String?,
        urgentPaths: Set<String>,
        incompletePaths: Set<String>
    ) -> [String] {
        let allowed = Set(paths)
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        func append(_ path: String) {
            guard allowed.contains(path), seen.insert(path).inserted else { return }
            ordered.append(path)
        }
        if let focusedPath { append(focusedPath) }
        for path in paths where urgentPaths.contains(path) { append(path) }
        for path in paths where incompletePaths.contains(path) { append(path) }
        for path in paths { append(path) }
        return ordered
    }

    nonisolated static func dueIncompleteTailPaths(
        paths: [String], retryAtByPath: [String: Date], now: Date
    ) -> Set<String> {
        Set(paths.lazy.filter { path in
            retryAtByPath[path].map { $0 <= now } ?? false
        }.prefix(tailReadsPerTick))
    }

    private func tick() async {
        if let priorityPath { installPriorityWatchers(at: priorityPath) }
        guard !tickInFlight else {
            tickPending = true
            return
        }
        tickInFlight = true
        defer {
            tickInFlight = false
            if tickPending {
                tickPending = false
                tickNow()
            }
        }

        let paths = trackedPaths
        let known = fingerprints
        let previous = activities
        let limit = Self.tailReadsPerTick
        let heartbeatDirectory = heartbeatDirectory
        let isProcessAlive = isProcessAlive
        let cursor = fallbackCursor
        let focusedPath = priorityPath
        let selectedUrgentPaths = Set(trackedPaths.lazy.filter(urgentPaths.contains).prefix(Self.tailReadsPerTick))
        urgentPaths.subtract(selectedUrgentPaths)
        if trackedPaths.contains(where: urgentPaths.contains) { tickPending = true }
        let knownIncompleteTailRetries = incompleteTailRetryAtByPath
        let immediatePriorityPaths = Set(focusedPath.map { [$0] } ?? [])
            .union(selectedUrgentPaths)
        let revision = configurationRevision
        let knownHeartbeats = heartbeatSnapshots
        let knownResourceSamples = resourceSamples
        let appProcessID = ProcessInfo.processInfo.processIdentifier
        let clock = nowProvider

        let result = await Task.detached(priority: .utility) {
            () -> (
                [String: SessionActivity], [String: Fingerprint], [String: [ActivityHeartbeat]], Int,
                [Int32: ProcessResourceSample], [String: ThreadResourceUsage], ThreadResourceUsage?, Bool,
                [String: Date], Set<String>, Bool
            ) in
            let now = clock()
            var heartbeats = ActivityHeartbeatStore.scan(directory: heartbeatDirectory)
            for path in Array(heartbeats.keys) {
                heartbeats[path]?.sort { lhs, rhs in
                    lhs.pid == rhs.pid ? lhs.updatedAt < rhs.updatedAt : lhs.pid < rhs.pid
                }
            }
            let hasRunningActivity = heartbeats.values.joined().contains {
                ActivityHeartbeatClassifier.isRunning($0, now: now, isProcessAlive: isProcessAlive)
            }
            guard !paths.isEmpty else {
                return ([:], [:], [:], 0, [:], [:], nil, hasRunningActivity, [:], [], false)
            }
            let heartbeatPaths = Set(heartbeats.keys)
            let trackedPathSet = Set(paths)
            var nextIncompleteTailRetries = knownIncompleteTailRetries.filter {
                trackedPathSet.contains($0.key)
            }
            let rootsByPath = heartbeats.reduce(into: [String: Set<Int32>]()) { result, entry in
                guard trackedPathSet.contains(entry.key) else { return }
                let roots = entry.value.filter {
                    ActivityHeartbeatClassifier.isRunning($0, now: now, isProcessAlive: isProcessAlive)
                }.map(\.pid)
                if !roots.isEmpty { result[entry.key] = Set(roots) }
            }
            let aggregateRoots = Set(rootsByPath.values.flatMap { $0 }).union([appProcessID])
            let resourceSnapshot = ProcessResourceSampler.sample(
                rootsByPath: rootsByPath,
                previous: knownResourceSamples,
                aggregateRoots: aggregateRoots,
                now: now
            )
            let heartbeatPathsToPoll = Self.heartbeatPathsRequiringPoll(
                paths: paths,
                heartbeats: heartbeats,
                previousHeartbeats: knownHeartbeats,
                previousActivities: previous
            )
            let dueIncompleteTailPaths = Self.dueIncompleteTailPaths(
                paths: paths, retryAtByPath: nextIncompleteTailRetries, now: now
            )
            let priorityPaths = immediatePriorityPaths.union(dueIncompleteTailPaths)
            // A pending incomplete record does not need another stat or tail read before its
            // exact expiry. A focus/FSEvent/heartbeat change still overrides that deferral.
            let pollablePaths = paths.filter { path in
                guard let retryAt = nextIncompleteTailRetries[path], retryAt > now else {
                    return true
                }
                return immediatePriorityPaths.contains(path)
                    || heartbeatPathsToPoll.contains(path)
            }
            let selection = Self.pollSelection(
                paths: pollablePaths,
                heartbeatPaths: heartbeatPaths,
                priorityPaths: priorityPaths,
                fallbackCursor: cursor
            )
            let selected = Set(selection.paths)
            var selectedPaths = paths.filter {
                heartbeatPathsToPoll.contains($0)
                    || priorityPaths.contains($0)
                    || (!heartbeatPaths.contains($0) && selected.contains($0))
            }
            selectedPaths = Self.orderedPollPaths(
                selectedPaths,
                focusedPath: focusedPath,
                urgentPaths: selectedUrgentPaths,
                incompletePaths: dueIncompleteTailPaths
            )
            var states = previous
            var stamps = known
            var deferredHeartbeatPaths: Set<String> = []
            var deferredUrgentPaths: Set<String> = []
            var tailReads = 0

            for path in selectedPaths {
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modifiedAt = values.contentModificationDate else {
                    nextIncompleteTailRetries.removeValue(forKey: path)
                    continue
                }
                let fingerprint = Fingerprint(
                    modifiedAt: modifiedAt.timeIntervalSince1970,
                    size: Int64(values.fileSize ?? 0)
                )
                let old = previous[path]
                let unchanged = known[path] == fingerprint
                let recordedWriters = heartbeats[path]
                let heartbeatDisappeared = recordedWriters == nil && knownHeartbeats[path] != nil
                let heartbeatRunning = recordedWriters?.contains {
                    ActivityHeartbeatClassifier.isRunning($0, now: now, isProcessAlive: isProcessAlive)
                } ?? false
                let newestHeartbeatDate = recordedWriters?.compactMap {
                    Date.piDate($0.updatedAt)
                }.max()
                let idleHeartbeatPredatesTranscript = !heartbeatRunning
                    && newestHeartbeatDate.map { modifiedAt.timeIntervalSince($0) > 0.001 } == true
                let staleIdleHeartbeat = priorityPaths.contains(path) && idleHeartbeatPredatesTranscript
                // A selected transcript may be written by a terminal that does not publish this
                // app's heartbeat. Once its JSONL is newer, the stale idle attachment must not
                // override the file tail.
                let writers = staleIdleHeartbeat ? nil : recordedWriters
                let heartbeatCompletionIDs = Set(writers?.compactMap(\.completionId) ?? [])
                // A live writer cannot have produced the next terminal completion yet. Its idle
                // heartbeat will carry that ID; tail fallback is only needed once the writer is
                // no longer live or no heartbeat exists.
                let needsTail = writers == nil || (!heartbeatRunning && heartbeatCompletionIDs.count != 1)
                var entry: JSONValue?
                var hasNewerIncompleteRecord = false
                var tailCompletion: SessionParser.AssistantCompletion?
                var readTail = false
                var tailReadSucceeded = false
                var retainsIncompleteRunningVerdict = false

                if needsTail, (!unchanged || heartbeatDisappeared) {
                    if tailReads < limit {
                        tailReads += 1
                        readTail = true
                        let tail = SessionActivityClassifier.readTail(at: url)
                        tailReadSucceeded = tail != nil
                        let transcoder = AgentSessionTranscoder.forSessionPath(path)
                        if let tail {
                            let evidence = SessionActivityClassifier.tailEvidence(
                                inTail: tail, transcoder: transcoder
                            )
                            entry = evidence.lastEntry
                            hasNewerIncompleteRecord = evidence.hasNewerIncompleteRecord
                        }
                        tailCompletion = tail.flatMap {
                            SessionParser.latestTerminalAssistantCompletion(inTail: $0, transcoder: transcoder)
                        }
                        let tailState = SessionActivityClassifier.classify(
                            lastEntry: entry,
                            age: now.timeIntervalSince(modifiedAt),
                            hasNewerIncompleteRecord: hasNewerIncompleteRecord
                        )
                        if hasNewerIncompleteRecord, tailState == .running {
                            // This verdict expires at the short append-race boundary even if the
                            // bytes never change again. Keep the old fingerprint so a later tick
                            // must reclassify the same bounded tail instead of extending running
                            // through the generic 15-second sticky-state window.
                            if let known = known[path] { stamps[path] = known }
                            else { stamps.removeValue(forKey: path) }
                            if nextIncompleteTailRetries[path] != nil
                                || nextIncompleteTailRetries.count < Self.maximumUrgentPaths {
                                nextIncompleteTailRetries[path] = modifiedAt.addingTimeInterval(
                                    SessionActivityClassifier.recentWriteWindow
                                )
                                retainsIncompleteRunningVerdict = true
                            }
                        } else if idleHeartbeatPredatesTranscript,
                           !priorityPaths.contains(path), tailState != .idle {
                            // Learn terminal completions in the background, but do not consume a
                            // newer nonterminal tail. Selecting the thread must still get a
                            // priority read that can override the stale idle attachment.
                            if let known = known[path] { stamps[path] = known }
                            else { stamps.removeValue(forKey: path) }
                        } else {
                            if tailReadSucceeded {
                                stamps[path] = fingerprint
                                nextIncompleteTailRetries.removeValue(forKey: path)
                            } else {
                                if let known = known[path] { stamps[path] = known }
                                else { stamps.removeValue(forKey: path) }
                                if nextIncompleteTailRetries[path] != nil {
                                    nextIncompleteTailRetries[path] = now.addingTimeInterval(0.25)
                                }
                            }
                        }
                    } else {
                        // Keep both retry signals until this changed/disappeared writer gets one
                        // of the bounded tail-read slots on a later tick.
                        if let known = known[path] { stamps[path] = known }
                        else { stamps.removeValue(forKey: path) }
                        if heartbeatDisappeared { deferredHeartbeatPaths.insert(path) }
                        if selectedUrgentPaths.contains(path) { deferredUrgentPaths.insert(path) }
                    }
                } else if heartbeatRunning, heartbeatCompletionIDs.count != 1 {
                    // Do not mark an ambiguous live tail as consumed. If the writer vanishes or
                    // settles without publishing a completion ID, the fallback must still read it.
                    if let known = known[path] { stamps[path] = known }
                    else { stamps.removeValue(forKey: path) }
                } else if idleHeartbeatPredatesTranscript {
                    // An idle attachment may coexist with a terminal writer that does not update
                    // this sidecar. Until the thread is selected, leave its newer transcript
                    // unconsumed so the priority transition gets one bounded tail read.
                    if let known = known[path] { stamps[path] = known }
                    else { stamps.removeValue(forKey: path) }
                } else {
                    stamps[path] = fingerprint
                }

                var completionID = old?.latestCompletedEntryID
                var completionStopReason = old?.lastStopReason
                var completionWriter: ActivityHeartbeat?
                var completionPreview: String?
                if heartbeatCompletionIDs.count == 1, let heartbeatCompletionID = heartbeatCompletionIDs.first {
                    completionID = heartbeatCompletionID
                    let matchingWriters = writers?.filter { $0.completionId == heartbeatCompletionID }
                    completionWriter = matchingWriters?.max {
                        (Date.piDate($0.updatedAt) ?? .distantPast) < (Date.piDate($1.updatedAt) ?? .distantPast)
                    }
                    completionPreview = matchingWriters?
                        .filter { $0.previewCompletionId == heartbeatCompletionID && $0.preview != nil }
                        .max {
                            (Date.piDate($0.updatedAt) ?? .distantPast) < (Date.piDate($1.updatedAt) ?? .distantPast)
                        }?.preview
                    if let reason = completionWriter?.stopReason,
                       SessionParser.terminalAssistantStopReasons.contains(reason) {
                        completionStopReason = reason
                    }
                } else if let tailCompletion {
                    completionID = tailCompletion.id
                    completionStopReason = tailCompletion.stopReason
                }

                if let writers {
                    nextIncompleteTailRetries.removeValue(forKey: path)
                    // An attached RPC process is idle while the terminal that owns the same
                    // session may still be working. Any fresh, live running writer wins.
                    let newest = writers.max {
                        (Date.piDate($0.updatedAt) ?? .distantPast) < (Date.piDate($1.updatedAt) ?? .distantPast)
                    }
                    let resolved: SessionRunState = heartbeatRunning ? .running : .idle
                    states[path] = SessionActivity(
                        state: resolved,
                        modifiedAt: modifiedAt,
                        runningSince: resolved == .running ? (old?.runningSince ?? modifiedAt) : nil,
                        latestCompletedEntryID: completionID,
                        lastStopReason: completionStopReason ?? newest?.stopReason,
                        preview: completionPreview
                            ?? (completionID == old?.latestCompletedEntryID ? old?.preview : nil)
                    )
                    continue
                }

                let age = now.timeIntervalSince(modifiedAt)
                let fileState: SessionRunState
                if readTail {
                    fileState = SessionActivityClassifier.classify(
                        lastEntry: entry,
                        age: age,
                        hasNewerIncompleteRecord: hasNewerIncompleteRecord
                            && retainsIncompleteRunningVerdict
                    )
                } else if let old {
                    fileState = old.state == .running && age > SessionActivityClassifier.staleNonTerminalWindow
                        ? .idle : old.state
                } else {
                    fileState = SessionActivityClassifier.classify(lastEntry: nil, age: age)
                }
                let resolved = fileState == .unknown ? (old?.state ?? .unknown) : fileState
                states[path] = SessionActivity(
                    state: resolved,
                    modifiedAt: modifiedAt,
                    runningSince: resolved == .running ? (old?.runningSince ?? modifiedAt) : nil,
                    latestCompletedEntryID: completionID,
                    lastStopReason: completionStopReason
                        ?? (readTail ? SessionActivityClassifier.stopReason(ofLastEntry: entry) : old?.lastStopReason),
                    preview: completionID == old?.latestCompletedEntryID ? old?.preview : nil,
                    resources: nil
                )
            }
            let tracked = Set(paths)
            var nextHeartbeats = heartbeats.filter { tracked.contains($0.key) }
            for path in deferredHeartbeatPaths {
                if let previous = knownHeartbeats[path] { nextHeartbeats[path] = previous }
            }
            return (
                states, stamps, nextHeartbeats, selection.nextCursor,
                resourceSnapshot.samples, resourceSnapshot.usageByPath,
                resourceSnapshot.aggregateUsage, hasRunningActivity, nextIncompleteTailRetries,
                deferredUrgentPaths,
                nextIncompleteTailRetries.values.contains { $0 <= now }
            )
        }.value

        guard configurationRevision == revision else {
            // Focus/catalog changes retire the detached result, but independent FSEvent work
            // must survive that generation fence. Restore only paths still tracked now.
            enqueueUrgent(selectedUrgentPaths.intersection(Set(trackedPaths)))
            tickPending = true
            return
        }
        fingerprints = result.1
        heartbeatSnapshots = result.2
        fallbackCursor = result.3
        resourceSamples = result.4
        resourceUsageByPath = result.5
        aggregateResources = result.6
        if hasRunningActivity != result.7 { hasRunningActivity = result.7 }
        incompleteTailRetryAtByPath = result.8
        scheduleIncompleteTailRetry(hasDuePaths: result.10)
        enqueueUrgent(result.9)
        if !result.9.isEmpty { tickPending = true }
        if activities != result.0 { activities = result.0 }
    }

    deinit {
        pollTask?.cancel()
        heartbeatWatcher?.cancel()
        priorityFileTickTask?.cancel()
        incompleteTailRetryTask?.cancel()
        priorityFileWatcher?.cancel()
        priorityDirectoryWatcher?.cancel()
    }
}
