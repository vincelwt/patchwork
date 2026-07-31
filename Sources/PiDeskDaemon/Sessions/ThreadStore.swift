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
    private struct Fingerprint: Equatable { let size: Int64; let modifiedAt: TimeInterval }
    /// `thread == nil` records a file that parsed as "not a user thread" (a Codex subagent
    /// rollout) or did not parse at all, so a big tree of subagent transcripts is not re-parsed
    /// on every single list.
    private struct CacheEntry { let fingerprint: Fingerprint; let thread: PiThread? }

    private let rootURL: URL
    /// Every agent whose sessions this daemon lists, with the root to scan for it.
    private let roots: [(agent: AgentKind, url: URL)]
    private let activityDirectoryURL: URL
    /// Read-only, and a parameter only so tests read a fixture instead of the machine's own
    /// `state.json`. The daemon never writes it; see `AppStatePeek`.
    private let appStateURL: URL
    private let logger: DaemonLogger
    private let overlay: DaemonOverlayStore
    private var cache: [String: CacheEntry] = [:]
    /// Last fully overlaid, sorted list. The web view loads this before opening a detail, so a
    /// point lookup stays O(thread count) instead of refreshing every session on disk.
    private var presented: [PiThread] = []

    init(
        rootURL: URL = SessionScanner.defaultRootURL(),
        roots: [(agent: AgentKind, url: URL)]? = nil,
        activityDirectoryURL: URL = PiDeskPaths.activityDirectory,
        appStateURL: URL = AppStatePeek.defaultURL(),
        logger: DaemonLogger,
        overlay: DaemonOverlayStore = DaemonOverlayStore()
    ) {
        self.rootURL = rootURL
        self.roots = roots ?? SessionScanner.roots(piRootURL: rootURL)
        self.activityDirectoryURL = activityDirectoryURL
        self.appStateURL = appStateURL
        self.logger = logger
        self.overlay = overlay
    }

    func listThreads(
        query: String?, limit: Int, cursor: String?, archived: Bool?, running: Bool?,
        automated: Bool? = nil, automatedThreadIDs: Set<String> = [], agent: AgentKind? = nil
    ) async -> (threads: [PiThread], nextCursor: String?) {
        var filtered = await allThreadsSorted()
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

        let start = cursor.flatMap(Int.init) ?? 0
        guard start >= 0, start < filtered.count else { return ([], nil) }
        let end = min(start + max(limit, 0), filtered.count)
        let nextCursor = end < filtered.count ? String(end) : nil
        return (Array(filtered[start..<end]), nextCursor)
    }

    func thread(idOrPath: String) async -> PiThread? {
        let standardizedPath = URL(fileURLWithPath: idOrPath).standardizedFileURL.path
        if var cached = presented.first(where: { $0.id == idOrPath || $0.path == standardizedPath }),
           FileManager.default.fileExists(atPath: cached.path) {
            let freshURL = URL(fileURLWithPath: cached.path)
            if let modified = try? freshURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                cached.updatedAt = modified
            }
            let counts = Dictionary(grouping: presented, by: \.id).mapValues(\.count)
            return await applyingOverlays(to: [cached], sessionIDCounts: counts).first
        }
        return await refreshedThread(idOrPath: idOrPath)
    }

    /// Exact ids/paths stay fast. Otherwise a unique prefix or suffix is accepted, which lets
    /// callers use the compact UUID tail printed by `pidesk` without risking the wrong thread.
    func resolve(idOrPath: String) async throws -> PiThread? {
        if let exact = await thread(idOrPath: idOrPath) { return exact }
        guard !idOrPath.contains("/") else { return nil }
        let matches = await allThreadsSorted().filter {
            $0.id.hasPrefix(idOrPath) || $0.id.hasSuffix(idOrPath)
        }
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
        return await allThreadsSorted().first { $0.id == idOrPath || $0.path == standardizedPath }
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

    func unreadCount() async -> Int {
        await allThreadsSorted().filter(\.unread).count
    }

    func setManagedWorktreeProject(_ project: URL, for worktree: URL) async throws {
        try await overlay.setManagedWorktreeProject(project, for: worktree)
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

    private func applyingOverlays(
        to source: [PiThread],
        sessionIDCounts suppliedCounts: [String: Int]? = nil
    ) async -> [PiThread] {
        let appState = AppStatePeek.load(from: appStateURL)
        let overlayState = await overlay.snapshot()
        let worktreeProjects = appState.managedWorktreeProjects.merging(
            overlayState.managedWorktreeProjects
        ) { _, daemon in daemon }
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
        let runningIDs = Set(runningHeartbeats.filter { $0.sessionFile == nil }.map(\.sessionId))
        let runningPaths = Set(runningHeartbeats.compactMap { $0.sessionFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        let sessionIDCounts = suppliedCounts ?? Dictionary(grouping: source, by: \.id).mapValues(\.count)

        var results = source
        for index in results.indices {
            let path = URL(fileURLWithPath: results[index].path).standardizedFileURL.path
            results[index].archived = appState.isArchived(sessionID: results[index].id)
                || overlayState.isArchived(results[index].id)
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
            let fallbackRunning = !heartbeatPaths.contains(path)
                && !heartbeatIDs.contains(results[index].id)
                && Date().timeIntervalSince(results[index].updatedAt) <= FileRunStateFallback.idleAfter
                && FileRunStateFallback.isRunning(sessionFile: URL(fileURLWithPath: path))
            results[index].running = runningPaths.contains(path)
                || fallbackRunning
                || (sessionIDCounts[results[index].id] == 1 && runningIDs.contains(results[index].id))
            if results[index].running { results[index].unread = false }
        }
        return results
    }

    private func allThreadsSorted() async -> [PiThread] {
        let files = SessionScanner.discoverSessions(roots: roots)
        var results: [PiThread] = []
        results.reserveCapacity(files.count)
        var stillPresent: Set<String> = []

        for file in files {
            let standardizedURL = file.url.standardizedFileURL
            let path = standardizedURL.path
            stillPresent.insert(path)
            guard let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let fingerprint = Fingerprint(size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0)

            let thread: PiThread?
            if let cached = cache[path], cached.fingerprint == fingerprint {
                thread = cached.thread
            } else {
                thread = Self.parse(standardizedURL, agent: file.agent, logger: logger)
                cache[path] = CacheEntry(fingerprint: fingerprint, thread: thread)
            }

            if let thread { results.append(thread) }
        }

        results = await applyingOverlays(to: results)

        // Drop cache entries for files that disappeared (archived out from under Pi, deleted).
        if cache.count != stillPresent.count || !cache.keys.allSatisfy(stillPresent.contains) {
            cache = cache.filter { stillPresent.contains($0.key) }
        }

        let sorted = results.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.name < rhs.name : lhs.updatedAt > rhs.updatedAt
        }
        presented = sorted
        return sorted
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
