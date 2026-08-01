import Darwin
import Foundation
import PiDeskKit

/// The daemon's view of every agent's sessions as a `Thread`. Wraps `SessionScanner`/
/// `SessionThreadParser` with a fingerprint cache (path/size/mtime, exactly the app's own
/// `SessionSummaryCache` strategy) so only files that actually changed since the last call are
/// re-parsed \u2014 real session files run tens of megabytes, so re-parsing all of them on every
/// request would make `threads list` and the scheduler's own bookkeeping needlessly slow.
///
/// `running`/`archived`/`unread` are overlaid on each list refresh from the heartbeat directory,
/// a read-only peek at the app's `state.json`, and the daemon's own `DaemonOverlayStore`. Point
/// lookups reuse that presented snapshot so opening one thread never reparses every changed file.
actor ThreadStore {
    private static let indexVersion = 2
    private static let persistedEntryLimit = 10_000
    private static let maximumPersistedIndexBytes = 32 * 1_024 * 1_024

    private struct Fingerprint: Codable, Equatable, Sendable {
        let agent: AgentKind
        let fileIdentifier: String?
        let size: Int64
        let modifiedAt: TimeInterval
    }
    /// `thread == nil` records a file that parsed as "not a user thread" (a Codex subagent
    /// rollout) or did not parse at all, so a big tree of subagent transcripts is not re-parsed
    /// on every single list.
    private struct CacheEntry: Codable, Sendable {
        let fingerprint: Fingerprint
        let thread: PiThread?
    }

    private struct PersistedIndex: Codable, Sendable {
        var version: Int
        var entries: [String: CacheEntry]
    }

    private struct DirectoryFingerprint: Equatable, Sendable {
        let exists: Bool
        let fileIdentifier: String?
        let modifiedAt: TimeInterval
    }

    private struct TranscriptVersion: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct SettledTranscript: Sendable {
        let version: TranscriptVersion
        let recordedAt: Date
    }

    private struct CatalogDiskScan: Sendable {
        var threads: [PiThread]
        var cache: [String: CacheEntry]
        var cacheChanged: Bool
        var directoryFingerprints: [String: DirectoryFingerprint]
    }

    private struct CatalogParseCandidate: Sendable {
        let index: Int
        let url: URL
        let path: String
        let agent: AgentKind
        let fingerprint: Fingerprint
    }

    private struct CatalogParseOutcome: Sendable {
        let candidate: CatalogParseCandidate
        let thread: PiThread?
    }

    private static let maximumConcurrentCatalogParses = 4

    private let rootURL: URL
    /// Every agent whose sessions this daemon lists, with the root to scan for it.
    private let roots: [(agent: AgentKind, url: URL)]
    private let activityDirectoryURL: URL
    /// Read-only, and a parameter only so tests read a fixture instead of the machine's own
    /// `state.json`. The daemon never writes it; see `AppStatePeek`.
    private let appStateURL: URL
    private let logger: DaemonLogger
    private let overlay: DaemonOverlayStore
    private let indexFileURL: URL?
    private let externalTitleSnapshot: @Sendable () -> [String: String]
    private let catalogScanHook: (@Sendable () -> Void)?
    private let catalogParseHook: (@Sendable (URL) -> Void)?
    private let activityProjectionHook: (@Sendable () -> Void)?
    private let catalogWaiterHook: (@Sendable () -> Void)?
    private var cache: [String: CacheEntry] = [:]
    private var indexPersistenceTask: Task<Void, Never>?
    private var indexPersistencePending = false
    private var catalogDirectoryFingerprints: [String: DirectoryFingerprint] = [:]
    /// Exact custom-root seeds captured by the published catalog. Directory mtimes cannot detect
    /// app state or daemon overlay changes that introduce an already-existing transcript.
    private var catalogSupplementalPaths: Set<String> = []
    private var catalogMutationRevision: UInt64 = 0
    private var catalogScanInProgress = false
    private var catalogScanWaiters: [CheckedContinuation<Void, Never>] = []
    /// Last fully overlaid, sorted list. The web view loads this before opening a detail, so a
    /// point lookup stays O(thread count) instead of refreshing every session on disk.
    private var presented: [PiThread] = []
    private var hasPresentedCatalog = false
    private var presentedByPath: [String: PiThread] = [:]
    private var presentedByID: [String: [PiThread]] = [:]
    private var presentedIDCounts: [String: Int] = [:]
    /// A terminal daemon outcome is authoritative for the exact transcript version it completed.
    /// This prevents a delayed foreign tail from reappearing as live file-fallback work. Any
    /// subsequent write changes the version and immediately returns control to the file heuristic.
    private var settledTranscripts: [String: SettledTranscript] = [:]
    private static let maximumSettledTranscripts = 4_096
    private struct ListSnapshot: Sendable {
        let threads: [PiThread]
        let createdAt: Date
    }
    /// Cursors are opaque snapshot handles. Without this, every page repeats the complete disk
    /// discovery, stat, overlay, and sort pass. A bounded handful supports concurrent clients
    /// while keeping a single pagination walk coherent and cheap.
    private var listSnapshots: [String: ListSnapshot] = [:]
    private var listSnapshotOrder: [String] = []
    private var listSnapshotEntryCount = 0
    private static let maximumListSnapshots = 8
    private static let maximumThreadsPerListSnapshot = 20_000
    private static let maximumRetainedListSnapshotEntries = 20_000
    private static let listSnapshotLifetime: TimeInterval = 300

    init(
        rootURL: URL = SessionScanner.defaultRootURL(),
        roots: [(agent: AgentKind, url: URL)]? = nil,
        activityDirectoryURL: URL = PiDeskPaths.activityDirectory,
        appStateURL: URL = AppStatePeek.defaultURL(),
        logger: DaemonLogger,
        overlay: DaemonOverlayStore = DaemonOverlayStore(),
        indexFileURL: URL? = nil,
        externalTitleSnapshot: @escaping @Sendable () -> [String: String] = {
            CodexThreadTitles.shared.snapshot()
        },
        catalogScanHook: (@Sendable () -> Void)? = nil,
        catalogParseHook: (@Sendable (URL) -> Void)? = nil,
        activityProjectionHook: (@Sendable () -> Void)? = nil,
        catalogWaiterHook: (@Sendable () -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.roots = roots ?? SessionScanner.roots(piRootURL: rootURL)
        self.activityDirectoryURL = activityDirectoryURL
        self.appStateURL = appStateURL
        self.logger = logger
        self.overlay = overlay
        self.indexFileURL = indexFileURL
        self.externalTitleSnapshot = externalTitleSnapshot
        self.catalogScanHook = catalogScanHook
        self.catalogParseHook = catalogParseHook
        self.activityProjectionHook = activityProjectionHook
        self.catalogWaiterHook = catalogWaiterHook
        if let indexFileURL,
           let fileSize = (try? indexFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           fileSize <= Self.maximumPersistedIndexBytes,
           let data = try? Data(contentsOf: indexFileURL, options: .mappedIfSafe),
           let persisted = try? PiDeskJSON.decoder.decode(PersistedIndex.self, from: data),
           persisted.version == Self.indexVersion {
            cache = Dictionary(uniqueKeysWithValues: persisted.entries
                .sorted { $0.key < $1.key }
                .suffix(Self.persistedEntryLimit))
        }
    }

    func listThreads(
        query: String?, limit: Int, cursor: String?, archived: Bool?, running: Bool?,
        automated: Bool? = nil, automatedThreadIDs: Set<String> = [], agent: AgentKind? = nil,
        sidebar: Bool = false
    ) async throws -> (threads: [PiThread], nextCursor: String?) {
        pruneListSnapshots()
        var legacyOffset = 0
        if let cursor, !cursor.isEmpty {
            if let parsed = Self.parseSnapshotCursor(cursor) {
                guard let snapshot = listSnapshots[parsed.token] else {
                    throw DaemonHTTPError.conflict(
                        code: "cursor_expired",
                        message: "Thread list cursor expired; restart without a cursor."
                    )
                }
                return page(
                    snapshot.threads, start: parsed.offset, limit: limit,
                    snapshotToken: parsed.token
                )
            }
            guard let numeric = Int(cursor), numeric >= 0 else {
                throw DaemonHTTPError.badRequest(
                    code: "invalid_cursor", message: "Thread list cursor is invalid."
                )
            }
            legacyOffset = numeric
        }

        var filtered = await allThreadsSorted()
        if sidebar {
            let appState = AppStatePeek.load(from: appStateURL)
            let overlayState = await overlay.snapshot()
            let visibility = appState.sidebarVisibility(
                desktopStartedThreadPaths: overlayState.managedThreadPaths
            )
            filtered = filtered.filter { visibility.includes(path: $0.path, agent: $0.agent) }
        }
        for index in filtered.indices {
            filtered[index].shortId = PiThread.abbreviatedID(for: filtered[index].id)
            if automatedThreadIDs.contains(filtered[index].id) { filtered[index].automated = true }
        }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = query.lowercased()
            filtered = filtered.filter {
                $0.name.lowercased().contains(needle) || $0.preview.lowercased().contains(needle) || $0.cwd.lowercased().contains(needle)
            }
        }
        if let archived { filtered = filtered.filter { $0.archived == archived } }
        if let running { filtered = filtered.filter { $0.running == running } }
        if let automated { filtered = filtered.filter { ($0.automated == true) == automated } }
        if let agent { filtered = filtered.filter { $0.agent == agent } }

        let start = legacyOffset
        guard start >= 0, start < filtered.count else { return ([], nil) }
        let end = min(start + max(limit, 0), filtered.count)
        guard end < filtered.count else { return (Array(filtered[start..<end]), nil) }
        guard filtered.count <= Self.maximumThreadsPerListSnapshot else {
            throw DaemonHTTPError.serviceUnavailable(
                code: "catalog_snapshot_too_large",
                message: "The filtered thread catalog is too large to paginate safely; narrow the query."
            )
        }

        let token = UUID().uuidString
        listSnapshots[token] = ListSnapshot(threads: filtered, createdAt: Date())
        listSnapshotOrder.append(token)
        listSnapshotEntryCount += filtered.count
        trimListSnapshotsToLimit()
        return (Array(filtered[start..<end]), Self.snapshotCursor(token: token, offset: end))
    }

    private func page(
        _ threads: [PiThread], start: Int, limit: Int, snapshotToken: String
    ) -> (threads: [PiThread], nextCursor: String?) {
        guard start >= 0, start < threads.count else {
            removeListSnapshot(snapshotToken)
            return ([], nil)
        }
        let end = min(start + max(limit, 0), threads.count)
        if end >= threads.count {
            removeListSnapshot(snapshotToken)
            return (Array(threads[start..<end]), nil)
        }
        return (
            Array(threads[start..<end]),
            Self.snapshotCursor(token: snapshotToken, offset: end)
        )
    }

    private static func snapshotCursor(token: String, offset: Int) -> String {
        "\(token):\(offset)"
    }

    private static func parseSnapshotCursor(_ cursor: String) -> (token: String, offset: Int)? {
        guard let separator = cursor.lastIndex(of: ":"),
              separator != cursor.startIndex,
              UUID(uuidString: String(cursor[..<separator])) != nil,
              let offset = Int(cursor[cursor.index(after: separator)...]),
              offset >= 0 else { return nil }
        return (String(cursor[..<separator]), offset)
    }

    private func pruneListSnapshots() {
        let cutoff = Date().addingTimeInterval(-Self.listSnapshotLifetime)
        let expired = listSnapshots.compactMap { key, value in value.createdAt < cutoff ? key : nil }
        for token in expired { removeListSnapshot(token) }
        trimListSnapshotsToLimit()
    }

    private func trimListSnapshotsToLimit() {
        while listSnapshotOrder.count > Self.maximumListSnapshots
            || listSnapshotEntryCount > Self.maximumRetainedListSnapshotEntries {
            removeListSnapshot(listSnapshotOrder[0])
        }
    }

    private func removeListSnapshot(_ token: String) {
        if let removed = listSnapshots.removeValue(forKey: token) {
            listSnapshotEntryCount = max(0, listSnapshotEntryCount - removed.threads.count)
        }
        listSnapshotOrder.removeAll { $0 == token }
    }

    func thread(idOrPath: String) async -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        let pathMatch = presentedByPath[standardizedPath]
        let idMatches = presentedByID[idOrPath] ?? []
        if var cached = pathMatch ?? (idMatches.count == 1 ? idMatches[0] : nil),
           FileManager.default.fileExists(atPath: cached.path) {
            let freshURL = URL(fileURLWithPath: cached.path)
            if let values = try? freshURL.resourceValues(forKeys: [
                .contentModificationDateKey, .fileResourceIdentifierKey
            ]) {
                let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
                if let expected = cache[cached.path]?.fingerprint.fileIdentifier,
                   let identifier, identifier != expected {
                    return await refreshedThread(idOrPath: cached.path)
                }
                if let modified = values.contentModificationDate { cached.updatedAt = modified }
            }
            return await applyingOverlays(to: [cached], sessionIDCounts: presentedIDCounts).first
        }
        if idOrPath.hasPrefix("/"),
           let direct = await adoptExistingThread(at: URL(fileURLWithPath: standardizedPath)) {
            return direct
        }
        return await refreshedThread(idOrPath: idOrPath)
    }

    /// Makes a newly created transcript immediately point-readable without waiting for a full
    /// catalog rescan. The parsed file remains the source of truth; this only warms the same
    /// fingerprint and presented indexes a scan would populate.
    func presentCreatedThread(
        _ thread: PiThread, runningOverride: Bool? = nil
    ) async -> PiThread {
        let url = URL(fileURLWithPath: thread.path).standardizedFileURL
        var presentedThread = await applyingOverlays(to: [thread]).first ?? thread
        if let runningOverride {
            if runningOverride {
                settledTranscripts.removeValue(forKey: url.path)
            } else {
                recordSettledTranscript(path: url.path)
            }
            presentedThread.running = runningOverride
            if runningOverride { presentedThread.unread = false }
        }
        presentedThread.shortId = PiThread.abbreviatedID(for: presentedThread.id)
        cacheThread(presentedThread, at: url)
        presentIfCatalogLoaded(presentedThread)
        return presentedThread
    }

    func markTranscriptSettled(path: String) {
        recordSettledTranscript(
            path: URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    private func recordSettledTranscript(path: String) {
        guard let version = Self.transcriptMetadata(path: path)?.version else { return }
        if settledTranscripts[path] == nil,
           settledTranscripts.count >= Self.maximumSettledTranscripts,
           let oldest = settledTranscripts.min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key {
            settledTranscripts.removeValue(forKey: oldest)
        }
        settledTranscripts[path] = SettledTranscript(version: version, recordedAt: Date())
    }

    private func adoptExistingThread(at url: URL) async -> PiThread? {
        guard url.pathExtension == "jsonl", let agent = agentForSessionPath(url.path),
              var thread = Self.parse(url, agent: agent, logger: logger) else { return nil }
        thread.agent = agent
        return await presentCreatedThread(thread)
    }

    private func agentForSessionPath(_ path: String) -> AgentKind? {
        roots
            .map { ($0.agent, $0.url.standardizedFileURL.path) }
            .sorted { $0.1.count > $1.1.count }
            .first { _, root in path == root || path.hasPrefix(root + "/") }?.0
    }

    private func cacheThread(_ thread: PiThread, at url: URL) {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
        ]) else { return }
        cache[url.path] = CacheEntry(
            fingerprint: Fingerprint(
                agent: thread.agent,
                fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ),
            thread: thread
        )
        catalogMutationRevision &+= 1
        scheduleIndexPersistence()
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path != "/" {
            if catalogDirectoryFingerprints[directory.path] != nil {
                catalogDirectoryFingerprints[directory.path] = Self.directoryFingerprint(directory)
            }
            directory.deleteLastPathComponent()
        }
    }

    private func presentIfCatalogLoaded(_ thread: PiThread) {
        guard hasPresentedCatalog else { return }
        var updated = presented.filter { $0.path != thread.path }
        updated.append(thread)
        publishPresented(updated.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.name < rhs.name : lhs.updatedAt > rhs.updatedAt
        })
    }

    /// Exact ids/paths stay fast. Otherwise a unique prefix or suffix is accepted, which lets
    /// callers use the compact UUID tail printed by `pidesk` without risking the wrong thread.
    func resolve(idOrPath: String) async throws -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        if let exactPath = presentedByPath[standardizedPath] {
            return await thread(idOrPath: exactPath.path)
        }
        let exactIDs = presentedByID[idOrPath] ?? []
        if exactIDs.count > 1 {
            return try resolve(idOrPath: idOrPath, among: exactIDs)
        }
        if let exactID = exactIDs.first {
            return await thread(idOrPath: exactID.path)
        }
        // Unknown ids and compact prefixes refresh once so newly created transcripts remain
        // discoverable. Exact ids from the presented catalog stay on the fast point-read path.
        return try resolve(idOrPath: idOrPath, among: await allThreadsSorted())
    }

    /// Side-effecting routes refresh non-path identifiers before choosing a target. A copied
    /// transcript that appeared after the last list can therefore make an id ambiguous, but an
    /// exact path remains on the O(1) presented-snapshot path used by the native app.
    func resolveForMutation(idOrPath: String) async throws -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        if let exactPath = presentedByPath[standardizedPath] {
            return await thread(idOrPath: exactPath.path)
        }
        let exactIDs = presentedByID[idOrPath] ?? []
        if exactIDs.count > 1 {
            return try resolve(idOrPath: idOrPath, among: exactIDs)
        }
        if let exact = exactIDs.first, await catalogIsCurrent() {
            return await thread(idOrPath: exact.path)
        }
        return try resolve(idOrPath: idOrPath, among: await allThreadsSorted())
    }

    private func resolve(idOrPath: String, among threads: [PiThread]) throws -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        if let exactPath = threads.first(where: { $0.path == standardizedPath }) { return exactPath }
        guard !idOrPath.contains("/") else { return nil }
        let exact = threads.filter { $0.id == idOrPath }
        if exact.count > 1 {
            throw DaemonHTTPError.badRequest(
                code: "ambiguous_thread_id",
                message: "Thread id \(idOrPath) matches \(exact.count) threads; use the transcript path."
            )
        }
        if let exact = exact.first { return exact }
        let matches = threads.filter { $0.id.hasPrefix(idOrPath) || $0.id.hasSuffix(idOrPath) }
        guard matches.count <= 1 else {
            throw DaemonHTTPError.badRequest(
                code: "ambiguous_thread_id",
                message: "Thread id \(idOrPath) matches \(matches.count) threads; use more characters."
            )
        }
        return matches.first
    }

    /// Mutations that need freshly overlaid fields may pay for a list refresh; ordinary detail,
    /// image, send, and scheduler lookups should use `thread(idOrPath:)` above.
    func refreshedThread(idOrPath: String) async -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        let threads = await allThreadsSorted()
        if let exactPath = threads.first(where: { $0.path == standardizedPath }) { return exactPath }
        let idMatches = threads.filter { $0.id == idOrPath }
        return idMatches.count == 1 ? idMatches[0] : nil
    }

    func messages(idOrPath: String, limit: Int) async -> [Message]? {
        guard let thread = await thread(idOrPath: idOrPath) else {
            guard let url = await resolveURL(idOrPath: idOrPath) else { return nil }
            return try? SessionThreadParser.messages(at: url, limit: limit)
        }
        return try? SessionThreadParser.messages(
            at: URL(fileURLWithPath: thread.path), limit: limit,
            transcoder: .make(for: thread.agent)
        )
    }

    func resolveURL(idOrPath: String) async -> URL? {
        let standardized = URL(fileURLWithPath: idOrPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) { return standardized }
        guard let thread = await thread(idOrPath: idOrPath) else { return nil }
        return URL(fileURLWithPath: thread.path)
    }

    func setManagedWorktreeProject(_ project: URL, for worktree: URL) async throws {
        try await overlay.setManagedWorktreeProject(project, for: worktree)
    }

    func recordDesktopStartedThread(path: String) async throws {
        try await recordManagedThread(path: path, desktopManaged: true)
    }

    func recordManagedThread(path: String) async throws {
        try await recordManagedThread(path: path, desktopManaged: false)
    }

    private func recordManagedThread(path: String, desktopManaged: Bool) async throws {
        var lastError: Error?
        for delay in [UInt64(0), 50_000_000, 200_000_000, 1_000_000_000] {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                if desktopManaged {
                    try await overlay.recordDesktopStartedThread(path: path)
                } else {
                    try await overlay.recordManagedThread(path: path)
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DaemonHTTPError.serviceUnavailable(
            code: "ownership_persistence_failed",
            message: "The conversation ownership record could not be saved."
        )
    }

    /// One catalog scan serves both pieces of the activity response. On a large installed
    /// history, independently asking for legacy-running candidates and unread count doubles the
    /// filesystem and overlay work for every heartbeat.
    func activityProjection(
        excludingPaths heartbeatPaths: Set<String>, legacyIDs: Set<String>,
        heartbeats: [Heartbeat]? = nil,
        runningHeartbeats: [Heartbeat]? = nil,
        now: Date = Date()
    ) async -> (
        threadsWithoutHeartbeat: [PiThread], unreadCount: Int,
        sessionIDCounts: [String: Int]
    ) {
        let heartbeatValues = heartbeats
            ?? ActivityReader.readHeartbeats(directory: activityDirectoryURL, logger: logger)
        let runningHeartbeatValues = runningHeartbeats
            ?? heartbeatValues.filter { ActivityReader.isRunning($0, now: now) }
        let stateURL = appStateURL
        async let appStateTask = Task.detached(priority: .utility) {
            AppStatePeek.load(from: stateURL)
        }.value
        async let overlayStateTask = overlay.snapshot()
        let appState = await appStateTask
        let overlayState = await overlayStateTask
        let supplementalPaths = overlayState.managedThreadPaths.union(appState.appStartedSessionPaths)

        if hasPresentedCatalog, await catalogIsCurrent(supplementalPaths: supplementalPaths) {
            // Parent-directory mtimes do not change for transcript appends. Re-stat every known
            // transcript, but avoid rebuilding every PiThread and every point-lookup index merely
            // to answer the two fields in the activity payload.
            let source = presented
            let sessionIDCounts = presentedIDCounts
            let settledTranscriptSnapshot = settledTranscripts
            let hook = activityProjectionHook
            let projection = await Task.detached(priority: .utility) {
                hook?()
                return Self.fastActivityProjection(
                    from: source,
                    sessionIDCounts: sessionIDCounts,
                    excludingPaths: heartbeatPaths,
                    legacyIDs: legacyIDs,
                    heartbeats: heartbeatValues,
                    runningHeartbeats: runningHeartbeatValues,
                    appState: appState,
                    overlayState: overlayState,
                    settledTranscripts: settledTranscriptSnapshot,
                    now: now
                )
            }.value
            return (
                projection.threadsWithoutHeartbeat, projection.unreadCount, sessionIDCounts
            )
        }

        let threads = await allThreadsSorted(
            heartbeats: heartbeatValues, runningHeartbeats: runningHeartbeatValues, now: now
        )
        let sessionIDCounts = Dictionary(grouping: threads, by: \.id).mapValues(\.count)
        let legacy = threads.filter {
            !heartbeatPaths.contains($0.path)
                && !(sessionIDCounts[$0.id] == 1 && legacyIDs.contains($0.id))
                && !$0.archived
                && $0.running
        }
        return (legacy, threads.lazy.filter(\.unread).count, sessionIDCounts)
    }

    private nonisolated static func fastActivityProjection(
        from source: [PiThread],
        sessionIDCounts: [String: Int],
        excludingPaths: Set<String>,
        legacyIDs: Set<String>,
        heartbeats: [Heartbeat],
        runningHeartbeats: [Heartbeat],
        appState: AppStatePeek.Snapshot,
        overlayState: DaemonOverlayStore.Snapshot,
        settledTranscripts: [String: SettledTranscript],
        now: Date
    ) -> (threadsWithoutHeartbeat: [PiThread], unreadCount: Int) {
        let idOnlyHeartbeatIDs = Set(
            heartbeats.filter { $0.sessionFile == nil }.map(\.sessionId)
        )
        let heartbeatPaths = Set(heartbeats.compactMap {
            $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        })
        var completionByPath: [String: (updatedAt: Date, id: String)] = [:]
        var completionBySessionID: [String: (updatedAt: Date, id: String)] = [:]
        for heartbeat in heartbeats {
            if let completionId = heartbeat.completionId {
                if let rawPath = heartbeat.sessionFile {
                    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
                    if completionByPath[path]?.updatedAt ?? .distantPast < heartbeat.updatedAt {
                        completionByPath[path] = (heartbeat.updatedAt, completionId)
                    }
                }
                if completionBySessionID[heartbeat.sessionId]?.updatedAt ?? .distantPast
                    < heartbeat.updatedAt {
                    completionBySessionID[heartbeat.sessionId] = (
                        heartbeat.updatedAt, completionId
                    )
                }
            }
        }
        let runningIDs = Set(runningHeartbeats.filter { $0.sessionFile == nil }.map(\.sessionId))
        let runningPaths = Set(runningHeartbeats.compactMap {
            $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        })

        var legacy: [PiThread] = []
        var unreadCount = 0
        legacy.reserveCapacity(min(source.count, 16))
        for base in source {
            guard let metadata = transcriptMetadata(path: base.path) else { continue }
            let modifiedAt = metadata.modifiedAt
            var thread = base
            thread.updatedAt = modifiedAt
            let path = thread.path
            thread.archived = appState.archivedSessionPaths.contains(path)
                || (appState.archivedSessionIDs.contains(thread.id)
                    && !appState.archiveExemptSessionPaths.contains(path))
                || overlayState.archivedThreadPaths.contains(path)
                || (overlayState.archivedThreadIDs.contains(thread.id)
                    && !overlayState.archiveExemptThreadPaths.contains(path))

            let completion = completionByPath[path]?.id
                ?? (sessionIDCounts[thread.id] == 1
                    ? completionBySessionID[thread.id]?.id : nil)
            if let override = overlayState.readOverrides[path], override.markedAt >= modifiedAt {
                thread.unread = override.unread
            } else if appState.manuallyUnreadSessionPaths.contains(path) {
                thread.unread = true
            } else if let latest = completion
                ?? appState.latestCompletedEntryIDBySessionPath[path] {
                thread.unread = appState.lastSeenCompletedEntryIDBySessionPath[path] != latest
            } else if let viewed = appState.lastReadAt[path] {
                thread.unread = modifiedAt > viewed
            } else {
                thread.unread = false
            }

            let fallbackRunning = !heartbeatPaths.contains(path)
                && !(sessionIDCounts[thread.id] == 1
                    && idOnlyHeartbeatIDs.contains(thread.id))
                && settledTranscripts[path]?.version != metadata.version
                && FileRunStateFallback.isRunning(
                    sessionFile: URL(fileURLWithPath: path),
                    agent: thread.agent,
                    modifiedAt: modifiedAt,
                    now: now
                )
            thread.running = runningPaths.contains(path)
                || fallbackRunning
                || (sessionIDCounts[thread.id] == 1 && runningIDs.contains(thread.id))
            if thread.running { thread.unread = false }
            if thread.unread { unreadCount += 1 }
            if thread.running, !thread.archived,
               !excludingPaths.contains(path),
               !(sessionIDCounts[thread.id] == 1 && legacyIDs.contains(thread.id)) {
                legacy.append(thread)
            }
        }
        return (legacy, unreadCount)
    }

    private struct TranscriptMetadata: Sendable {
        let modifiedAt: Date
        let version: TranscriptVersion
    }

    private nonisolated static func transcriptMetadata(path: String) -> TranscriptMetadata? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modifiedAt = Date(timeIntervalSince1970:
            Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return TranscriptMetadata(
            modifiedAt: modifiedAt,
            version: TranscriptVersion(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
            )
        )
    }

    /// `POST /v1/threads/{id}/archive`. Returns the thread with the change already applied.
    @discardableResult
    func setArchived(_ archived: Bool, idOrPath: String) async throws -> PiThread {
        guard let existing = await thread(idOrPath: idOrPath) else { throw DaemonHTTPError.notFound("Thread \(idOrPath)") }
        if !archived, AppStatePeek.load(from: appStateURL).isArchived(
            sessionID: existing.id, path: existing.path
        ) {
            throw DaemonHTTPError.conflict(
                code: "archived_in_app",
                message: "This thread was archived in the Mac app; restore it there."
            )
        }
        let checkpoint = try await overlay.setArchived(
            archived, threadID: existing.id, path: existing.path
        )
        guard let refreshed = await thread(idOrPath: idOrPath) else {
            try await restoreArchiveOverlay(checkpoint, path: existing.path)
            throw DaemonHTTPError.notFound("Thread \(idOrPath)")
        }
        if !archived, refreshed.archived {
            try await restoreArchiveOverlay(checkpoint, path: existing.path)
            throw DaemonHTTPError.conflict(
                code: "archived_in_app",
                message: "This thread was archived in the Mac app; restore it there."
            )
        }
        return refreshed
    }

    private func restoreArchiveOverlay(
        _ checkpoint: DaemonOverlayStore.ArchiveCheckpoint, path: String
    ) async throws {
        do {
            try await overlay.restoreArchive(checkpoint)
        } catch {
            logger.error("Could not roll back archive state for \(path): \(error)")
            throw DaemonHTTPError.serviceUnavailable(
                code: "archive_rollback_failed",
                message: "The archive change could not be rolled back safely."
            )
        }
    }

    /// `POST /v1/threads/{id}/read`. Returns the thread with the change already applied.
    @discardableResult
    func setUnread(_ unread: Bool, idOrPath: String) async throws -> PiThread {
        guard var existing = await thread(idOrPath: idOrPath) else { throw DaemonHTTPError.notFound("Thread \(idOrPath)") }
        try await overlay.setUnread(unread, path: existing.path)
        existing.unread = unread
        return existing
    }

    private func applyingOverlays(
        to source: [PiThread],
        sessionIDCounts suppliedCounts: [String: Int]? = nil,
        heartbeats suppliedHeartbeats: [Heartbeat]? = nil,
        runningHeartbeats suppliedRunningHeartbeats: [Heartbeat]? = nil,
        now: Date = Date()
    ) async -> [PiThread] {
        let appState = AppStatePeek.load(from: appStateURL)
        let overlayState = await overlay.snapshot()
        let worktreeProjects = appState.managedWorktreeProjects.merging(
            overlayState.managedWorktreeProjects
        ) { _, daemon in daemon }
        let heartbeats = suppliedHeartbeats
            ?? ActivityReader.readHeartbeats(directory: activityDirectoryURL, logger: logger)
        let idOnlyHeartbeatIDs = Set(
            heartbeats.filter { $0.sessionFile == nil }.map(\.sessionId)
        )
        let heartbeatPaths = Set(heartbeats.compactMap { $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        let latestHeartbeatCompletionByPath = Dictionary(
            grouping: heartbeats.filter { $0.completionId != nil && $0.sessionFile != nil },
            by: { URL(fileURLWithPath: $0.sessionFile!).standardizedFileURL.path }
        ).compactMapValues { writers in writers.max { $0.updatedAt < $1.updatedAt }?.completionId }
        let latestHeartbeatCompletionBySessionID = Dictionary(
            grouping: heartbeats.filter { $0.completionId != nil }, by: \.sessionId
        ).compactMapValues { writers in writers.max { $0.updatedAt < $1.updatedAt }?.completionId }
        let runningHeartbeats = suppliedRunningHeartbeats
            ?? heartbeats.filter { ActivityReader.isRunning($0, now: now) }
        let runningIDs = Set(runningHeartbeats.filter { $0.sessionFile == nil }.map(\.sessionId))
        let runningPaths = Set(runningHeartbeats.compactMap { $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        let sessionIDCounts = suppliedCounts ?? Dictionary(grouping: source, by: \.id).mapValues(\.count)

        var results = source
        var obsoleteSettledPaths: [String] = []
        for index in results.indices {
            let path = URL(fileURLWithPath: results[index].path).standardizedFileURL.path
            results[index].archived = appState.isArchived(
                sessionID: results[index].id, path: path
            )
                || overlayState.isArchived(results[index].id, path: path)
            let cwd = URL(fileURLWithPath: results[index].cwd).standardizedFileURL.path
            if let project = worktreeProjects[cwd] {
                results[index].project = project
                results[index].worktree = cwd
            }
            let completion = latestHeartbeatCompletionByPath[path]
                ?? (sessionIDCounts[results[index].id] == 1 ? latestHeartbeatCompletionBySessionID[results[index].id] : nil)
            results[index].unread = overlayState.unreadOverride(
                path: results[index].path,
                updatedAt: results[index].updatedAt
            ) ?? appState.isUnread(
                path: results[index].path,
                latestCompletionID: completion,
                modifiedAt: results[index].updatedAt
            )
            let settledVersion = settledTranscripts[path]?.version
            let currentVersion = settledVersion == nil
                ? nil : Self.transcriptMetadata(path: path)?.version
            let fallbackSettled = settledVersion != nil && settledVersion == currentVersion
            if settledVersion != nil, !fallbackSettled { obsoleteSettledPaths.append(path) }
            let fallbackRunning = !heartbeatPaths.contains(path)
                && !(sessionIDCounts[results[index].id] == 1
                    && idOnlyHeartbeatIDs.contains(results[index].id))
                && !fallbackSettled
                && now.timeIntervalSince(results[index].updatedAt) <= FileRunStateFallback.idleAfter
                && FileRunStateFallback.isRunning(
                    sessionFile: URL(fileURLWithPath: path),
                    agent: results[index].agent,
                    now: now
                )
            results[index].running = runningPaths.contains(path)
                || fallbackRunning
                || (sessionIDCounts[results[index].id] == 1 && runningIDs.contains(results[index].id))
            if results[index].running { results[index].unread = false }
        }
        for path in obsoleteSettledPaths { settledTranscripts.removeValue(forKey: path) }
        return results
    }

    private func allThreadsSorted(
        heartbeats: [Heartbeat]? = nil,
        runningHeartbeats: [Heartbeat]? = nil,
        now: Date = Date()
    ) async -> [PiThread] {
        if catalogScanInProgress {
            catalogWaiterHook?()
            await withCheckedContinuation { catalogScanWaiters.append($0) }
            if await catalogIsCurrent() {
                return await applyingOverlays(
                    to: presented,
                    sessionIDCounts: presentedIDCounts,
                    heartbeats: heartbeats,
                    runningHeartbeats: runningHeartbeats,
                    now: now
                )
            }
            return await allThreadsSorted(
                heartbeats: heartbeats, runningHeartbeats: runningHeartbeats, now: now
            )
        }
        catalogScanInProgress = true
        defer {
            catalogScanInProgress = false
            let waiters = catalogScanWaiters
            catalogScanWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        var supplementalPaths: Set<String> = []
        var diskScan: CatalogDiskScan!
        while true {
            supplementalPaths = await currentSupplementalPaths()
            let revision = catalogMutationRevision
            let cacheSnapshot = cache
            let scanRoots = roots
            let scanSupplementalPaths = supplementalPaths
            let logger = logger
            let titleSnapshot = externalTitleSnapshot
            let scanHook = catalogScanHook
            let parseHook = catalogParseHook
            diskScan = await Task.detached(priority: .utility) {
                scanHook?()
                return await Self.scanCatalog(
                    roots: scanRoots,
                    supplementalPaths: scanSupplementalPaths,
                    cache: cacheSnapshot,
                    logger: logger,
                    externalTitleSnapshot: titleSnapshot,
                    parseHook: parseHook
                )
            }.value
            let currentPaths = await currentSupplementalPaths()
            if revision == catalogMutationRevision, currentPaths == supplementalPaths { break }
        }

        cache = diskScan.cache
        if diskScan.cacheChanged { scheduleIndexPersistence() }
        let results = await applyingOverlays(
            to: diskScan.threads,
            heartbeats: heartbeats,
            runningHeartbeats: runningHeartbeats,
            now: now
        )

        let sorted = results.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.name < rhs.name : lhs.updatedAt > rhs.updatedAt
        }
        catalogSupplementalPaths = supplementalPaths
        catalogDirectoryFingerprints = diskScan.directoryFingerprints
        publishPresented(sorted)
        return sorted
    }

    private nonisolated static func scanCatalog(
        roots: [(agent: AgentKind, url: URL)],
        supplementalPaths: Set<String>,
        cache originalCache: [String: CacheEntry],
        logger: DaemonLogger,
        externalTitleSnapshot: @Sendable () -> [String: String],
        parseHook: (@Sendable (URL) -> Void)?
    ) async -> CatalogDiskScan {
        let catalog = SessionScanner.discoverCatalog(
            roots: roots, supplementalPaths: supplementalPaths
        )
        let directoryFingerprints = Dictionary(uniqueKeysWithValues: catalog.directories.map {
            ($0.standardizedFileURL.path, directoryFingerprint($0))
        })
        var cache = originalCache
        var orderedResults = Array<PiThread?>(repeating: nil, count: catalog.sessions.count)
        var misses: [CatalogParseCandidate] = []
        misses.reserveCapacity(catalog.sessions.count)
        var stillPresent: Set<String> = []
        var cacheChanged = false

        for (index, file) in catalog.sessions.enumerated() {
            let url = file.url.standardizedFileURL
            let path = url.path
            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
            ]) else { continue }
            stillPresent.insert(path)
            let fingerprint = Fingerprint(
                agent: file.agent,
                fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
            if let cached = cache[path], cached.fingerprint == fingerprint {
                orderedResults[index] = cached.thread
            } else {
                misses.append(CatalogParseCandidate(
                    index: index,
                    url: url,
                    path: path,
                    agent: file.agent,
                    fingerprint: fingerprint
                ))
            }
        }

        let parseCandidate: @Sendable (CatalogParseCandidate) -> CatalogParseOutcome = { candidate in
            parseHook?(candidate.url)
            return CatalogParseOutcome(
                candidate: candidate,
                thread: parse(candidate.url, agent: candidate.agent, logger: logger)
            )
        }
        await withTaskGroup(of: CatalogParseOutcome.self) { group in
            var iterator = misses.makeIterator()
            for _ in 0..<min(maximumConcurrentCatalogParses, misses.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask { parseCandidate(candidate) }
            }

            while let outcome = await group.next() {
                let candidate = outcome.candidate
                orderedResults[candidate.index] = outcome.thread
                cache[candidate.path] = CacheEntry(
                    fingerprint: candidate.fingerprint,
                    thread: outcome.thread
                )
                cacheChanged = true
                if let candidate = iterator.next() {
                    group.addTask { parseCandidate(candidate) }
                }
            }
        }

        var results = orderedResults.compactMap { $0 }

        if results.contains(where: { $0.agent == .codex }) {
            let titles = externalTitleSnapshot()
            for index in results.indices {
                if let external = results[index].agent.externalName(
                    forSessionPath: results[index].path, titles: titles
                ) {
                    results[index].name = external
                }
            }
        }

        if cache.count != stillPresent.count || !cache.keys.allSatisfy(stillPresent.contains) {
            cache = cache.filter { stillPresent.contains($0.key) }
            cacheChanged = true
        }
        return CatalogDiskScan(
            threads: results,
            cache: cache,
            cacheChanged: cacheChanged,
            directoryFingerprints: directoryFingerprints
        )
    }

    private func publishPresented(_ threads: [PiThread]) {
        hasPresentedCatalog = true
        presented = threads
        presentedByPath = Dictionary(uniqueKeysWithValues: threads.map { ($0.path, $0) })
        presentedByID = Dictionary(grouping: threads, by: \.id)
        presentedIDCounts = presentedByID.mapValues(\.count)
    }

    private func currentSupplementalPaths() async -> Set<String> {
        async let overlayState = overlay.snapshot()
        let stateURL = appStateURL
        async let appPaths = Task.detached(priority: .utility) {
            AppStatePeek.load(from: stateURL).appStartedSessionPaths
        }.value
        let daemonSnapshot = await overlayState
        let nativePaths = await appPaths
        return daemonSnapshot.managedThreadPaths.union(nativePaths)
    }

    private func catalogIsCurrent() async -> Bool {
        await catalogIsCurrent(supplementalPaths: currentSupplementalPaths())
    }

    private func catalogIsCurrent(supplementalPaths: Set<String>) async -> Bool {
        guard supplementalPaths == catalogSupplementalPaths,
              !catalogDirectoryFingerprints.isEmpty else { return false }
        let fingerprints = catalogDirectoryFingerprints
        return await Task.detached(priority: .utility) {
            fingerprints.allSatisfy { path, expected in
                Self.directoryFingerprint(URL(fileURLWithPath: path)) == expected
            }
        }.value
    }

    private static func directoryFingerprint(_ url: URL) -> DirectoryFingerprint {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [
                  .contentModificationDateKey, .fileResourceIdentifierKey
              ]) else {
            return DirectoryFingerprint(exists: false, fileIdentifier: nil, modifiedAt: 0)
        }
        return DirectoryFingerprint(
            exists: true,
            fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private func scheduleIndexPersistence() {
        guard let indexFileURL else { return }
        guard indexPersistenceTask == nil else {
            indexPersistencePending = true
            return
        }
        let snapshot = cache
        indexPersistenceTask = Task { [weak self] in
            let failure = await Task.detached(priority: .utility) {
                Self.writePersistedIndex(snapshot, to: indexFileURL)
            }.value
            await self?.finishedIndexPersistence(failure: failure)
        }
    }

    private func finishedIndexPersistence(failure: String?) {
        indexPersistenceTask = nil
        if let failure { logger.warn("Could not persist the thread summary index: \(failure)") }
        guard indexPersistencePending else { return }
        indexPersistencePending = false
        scheduleIndexPersistence()
    }

    /// Test and shutdown seam: waits for the current write and any coalesced successor.
    func waitForIndexPersistence() async {
        while let task = indexPersistenceTask { await task.value }
    }

    private nonisolated static func writePersistedIndex(
        _ snapshot: [String: CacheEntry], to indexFileURL: URL
    ) -> String? {
        var pairs = Array(snapshot.sorted { $0.key < $1.key }.suffix(Self.persistedEntryLimit))
        do {
            while true {
                let entries = Dictionary(uniqueKeysWithValues: pairs)
                let data = try PiDeskJSON.encoder.encode(
                    PersistedIndex(version: Self.indexVersion, entries: entries)
                )
                if data.count <= Self.maximumPersistedIndexBytes {
                    try PiDeskFile.writeAtomic(data, to: indexFileURL)
                    return nil
                }
                guard pairs.count > 1 else {
                    return "The bounded thread summary index still exceeded the byte limit."
                }
                pairs = Array(pairs.suffix(max(1, pairs.count / 2)))
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// `nil` means "do not list this file": a subagent rollout, or something unparseable. Both
    /// are remembered by fingerprint so the decision is made once per file version.
    private static func parse(_ url: URL, agent: AgentKind, logger: DaemonLogger) -> PiThread? {
        do {
            var thread = try SessionThreadParser.thread(at: url, transcoder: .make(for: agent))
            thread.agent = agent
            return thread
        } catch SessionThreadParser.ParseError.subsession {
            return nil
        } catch {
            logger.warn("Skipping unparseable \(agent.displayName) session file \(url.lastPathComponent)")
            return nil
        }
    }
}
