import Foundation
import PiDeskKit

/// The daemon's view of every Pi session as a `Thread`. Wraps `SessionScanner`/
/// `SessionThreadParser` with a fingerprint cache (path/size/mtime, exactly the app's own
/// `SessionSummaryCache` strategy) so only files that actually changed since the last call are
/// re-parsed \u2014 real session files run tens of megabytes, so re-parsing all of them on every
/// request would make `threads list` and the scheduler's own bookkeeping needlessly slow.
///
/// `running`/`archived`/`unread` are overlaid fresh on every call from the heartbeat directory,
/// a read-only peek at the app's `state.json`, and the daemon's own `DaemonOverlayStore` \u2014
/// never cached, since those change independently of the session file itself.
actor ThreadStore {
    private struct Fingerprint: Equatable { let size: Int64; let modifiedAt: TimeInterval }
    private struct CacheEntry { let fingerprint: Fingerprint; let thread: PiThread }

    private let rootURL: URL
    private let activityDirectoryURL: URL
    private let logger: DaemonLogger
    private let overlay: DaemonOverlayStore
    private var cache: [String: CacheEntry] = [:]

    init(
        rootURL: URL = SessionScanner.defaultRootURL(),
        activityDirectoryURL: URL = PiDeskPaths.activityDirectory,
        logger: DaemonLogger,
        overlay: DaemonOverlayStore = DaemonOverlayStore()
    ) {
        self.rootURL = rootURL
        self.activityDirectoryURL = activityDirectoryURL
        self.logger = logger
        self.overlay = overlay
    }

    func listThreads(query: String?, limit: Int, cursor: String?, archived: Bool?, running: Bool?) async -> (threads: [PiThread], nextCursor: String?) {
        var filtered = await allThreadsSorted()
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = query.lowercased()
            filtered = filtered.filter {
                $0.name.lowercased().contains(needle) || $0.preview.lowercased().contains(needle) || $0.cwd.lowercased().contains(needle)
            }
        }
        if let archived { filtered = filtered.filter { $0.archived == archived } }
        if let running { filtered = filtered.filter { $0.running == running } }

        let start = cursor.flatMap(Int.init) ?? 0
        guard start >= 0, start < filtered.count else { return ([], nil) }
        let end = min(start + max(limit, 0), filtered.count)
        let nextCursor = end < filtered.count ? String(end) : nil
        return (Array(filtered[start..<end]), nextCursor)
    }

    func thread(idOrPath: String) async -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        return await allThreadsSorted().first { $0.id == idOrPath || $0.path == standardizedPath }
    }

    func messages(idOrPath: String, limit: Int) async -> [Message]? {
        guard let url = await resolveURL(idOrPath: idOrPath) else { return nil }
        return try? SessionThreadParser.messages(at: url, limit: limit)
    }

    func resolveURL(idOrPath: String) async -> URL? {
        let standardized = URL(fileURLWithPath: idOrPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) { return standardized }
        guard let thread = await thread(idOrPath: idOrPath) else { return nil }
        return URL(fileURLWithPath: thread.path)
    }

    func unreadCount() async -> Int {
        await allThreadsSorted().filter(\.unread).count
    }

    /// Threads the heartbeat extension has never reported on — sessions that started before it
    /// was installed. Their run state has to come from their file instead.
    func threadsWithoutHeartbeat(excluding heartbeatIDs: Set<String>) async -> [PiThread] {
        await allThreadsSorted().filter { !heartbeatIDs.contains($0.id) && !$0.archived }
    }

    /// `POST /v1/threads/{id}/archive`. Returns the thread with the change already applied.
    @discardableResult
    func setArchived(_ archived: Bool, idOrPath: String) async throws -> PiThread {
        guard let existing = await thread(idOrPath: idOrPath) else { throw DaemonHTTPError.notFound("Thread \(idOrPath)") }
        try await overlay.setArchived(archived, threadID: existing.id)
        guard let refreshed = await thread(idOrPath: idOrPath) else { throw DaemonHTTPError.notFound("Thread \(idOrPath)") }
        return refreshed
    }

    /// `POST /v1/threads/{id}/read`. Returns the thread with the change already applied.
    @discardableResult
    func setUnread(_ unread: Bool, idOrPath: String) async throws -> PiThread {
        guard let existing = await thread(idOrPath: idOrPath) else { throw DaemonHTTPError.notFound("Thread \(idOrPath)") }
        try await overlay.setUnread(unread, path: existing.path)
        guard let refreshed = await thread(idOrPath: idOrPath) else { throw DaemonHTTPError.notFound("Thread \(idOrPath)") }
        return refreshed
    }

    private func allThreadsSorted() async -> [PiThread] {
        let files = SessionScanner.discoverSessionFiles(rootURL: rootURL)
        let appState = AppStatePeek.load()
        let overlayState = await overlay.snapshot()
        let heartbeats = ActivityReader.readHeartbeats(directory: activityDirectoryURL, logger: logger)
        let heartbeatIDs = Set(heartbeats.map(\.sessionId))
        let heartbeatPaths = Set(heartbeats.compactMap { $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        let latestHeartbeatCompletionByPath = Dictionary(
            grouping: heartbeats.filter { $0.completionId != nil && $0.sessionFile != nil },
            by: { URL(fileURLWithPath: $0.sessionFile!).standardizedFileURL.path }
        ).compactMapValues { writers in writers.max { $0.updatedAt < $1.updatedAt }?.completionId }
        let latestHeartbeatCompletionBySessionID = Dictionary(
            grouping: heartbeats.filter { $0.completionId != nil }, by: \.sessionId
        ).compactMapValues { writers in writers.max { $0.updatedAt < $1.updatedAt }?.completionId }
        let runningHeartbeats = heartbeats.filter { ActivityReader.isRunning($0) }
        var runningIDs = Set(runningHeartbeats.filter { $0.sessionFile == nil }.map(\.sessionId))
        let runningPaths = Set(runningHeartbeats.compactMap { $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })

        var results: [PiThread] = []
        results.reserveCapacity(files.count)
        var stillPresent: Set<String> = []

        for file in files {
            let standardizedURL = file.standardizedFileURL
            let path = standardizedURL.path
            stillPresent.insert(path)
            guard let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let fingerprint = Fingerprint(size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0)

            var thread: PiThread
            if let cached = cache[path], cached.fingerprint == fingerprint {
                thread = cached.thread
            } else {
                guard let parsed = try? SessionThreadParser.thread(at: standardizedURL) else {
                    logger.warn("Skipping unparseable session file \(standardizedURL.lastPathComponent)")
                    continue
                }
                thread = parsed
                cache[path] = CacheEntry(fingerprint: fingerprint, thread: thread)
            }

            thread.archived = appState.isArchived(sessionID: thread.id) || overlayState.isArchived(thread.id)
            thread.unread = overlayState.unreadOverride(path: thread.path, updatedAt: thread.updatedAt)
                ?? appState.isUnread(
                    path: thread.path,
                    latestCompletionID: latestHeartbeatCompletionByPath[path]
                        ?? latestHeartbeatCompletionBySessionID[thread.id],
                    modifiedAt: thread.updatedAt
                )
            // A session the extension has never seen still has to report honestly, so its file
            // decides. Freshly written files are the only ones worth reading a tail for.
            if !heartbeatPaths.contains(path), !heartbeatIDs.contains(thread.id),
               Date().timeIntervalSince(thread.updatedAt) <= FileRunStateFallback.idleAfter,
               FileRunStateFallback.isRunning(sessionFile: standardizedURL) {
                runningIDs.insert(thread.id)
            }
            thread.running = runningPaths.contains(path) || runningIDs.contains(thread.id)
            if thread.running { thread.unread = false }
            results.append(thread)
        }

        // Drop cache entries for files that disappeared (archived out from under Pi, deleted).
        if cache.count != stillPresent.count || !cache.keys.allSatisfy(stillPresent.contains) {
            cache = cache.filter { stillPresent.contains($0.key) }
        }

        return results.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.name < rhs.name : lhs.updatedAt > rhs.updatedAt
        }
    }
}
