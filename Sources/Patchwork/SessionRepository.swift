import Foundation
import PatchworkKit

protocol SessionRepositoryProtocol {
    var rootURL: URL { get }
    /// Discovery narrowed to the agents the user has switched on. Declared here rather than only
    /// in the extension below: an extension member dispatches statically through a protocol
    /// existential, so the file repository's root-skipping override would never have run.
    func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary]
    /// Which agent wrote a transcript, decided by the session root it lives under.
    func agent(for fileURL: URL) -> AgentKind
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary]
    func loadConversation(from fileURL: URL) async throws -> SessionConversation
    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage
    func loadOlderConversationPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage
    func loadFocusedHistoryPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary
    /// Sidebar hydration: everything the persisted summary cache already knows, with no disk
    /// scan and no JSONL parsing, so the first paint is immediate.
    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary]
    /// Fast partial parse for the "instant tail" first paint on a cache miss (Task 1): the last
    /// `limit` renderable messages, read backward from EOF so latency does not scale with total
    /// file size. `isComplete` reports whether this already *is* the whole conversation.
    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan
}

extension SessionRepositoryProtocol {
    /// The default filters after the fact so any repository keeps working; the file repository
    /// skips those roots outright, which is the point — a disabled agent's transcripts are never
    /// read at all.
    func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary] {
        let all = try await discoverSessions(archivedIDs: archivedIDs)
        guard let agents else { return all }
        return all.filter { agents.contains($0.agent) }
    }

    /// Fakes and legacy repositories only ever hold Pi sessions.
    func agent(for fileURL: URL) -> AgentKind { .pi }

    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary] { [] }
    /// Defaulted to a full load reported as already-complete: fakes/tests that never override
    /// this behave exactly as if every selection were a full-file parse in one step, which is
    /// what they already exercise today.
    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan {
        SessionParser.TailScan(conversation: try await loadConversation(from: fileURL), isComplete: true)
    }

    // Legacy-only fakes keep compiling. Production's file repository overrides both methods with
    // the bounded JSONL scanner below.
    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage {
        let conversation = try await loadConversation(from: fileURL)
        let truncated = conversation.messages.count > ConversationPage.defaultMessageTarget
        return ConversationPage(
            messages: Array(conversation.messages.suffix(ConversationPage.defaultMessageTarget)),
            olderCursor: nil,
            leafID: conversation.leafID,
            rawEntryCount: conversation.rawEntryCount,
            scannedEntryCount: conversation.rawEntryCount,
            scannedByteCount: 0,
            isTruncated: truncated
        )
    }

    func loadOlderConversationPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        throw ConversationPagingError.unsupported
    }

    func loadFocusedHistoryPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        try await loadOlderConversationPage(from: fileURL, cursor: cursor)
    }
}

struct FileSessionRepository: SessionRepositoryProtocol {
    /// Pi's own root. Retained because callers still use it as "where a new Pi thread lands";
    /// discovery itself walks every agent root in `roots`.
    let rootURL: URL
    /// Every agent whose session tree exists on this machine, with the root to scan for it.
    let roots: [(agent: AgentKind, url: URL)]
    let summaryCache: SessionSummaryCache

    init(
        rootURL: URL = FileSessionRepository.defaultRootURL(),
        roots: [(agent: AgentKind, url: URL)]? = nil,
        summaryCache: SessionSummaryCache? = nil
    ) {
        self.rootURL = rootURL
        // Pinning Pi's root to a fixture tree pins all of them; see `SessionScanner.roots`.
        self.roots = roots ?? SessionScanner.roots(piRootURL: rootURL)
        self.summaryCache = summaryCache ?? SessionSummaryCache()
    }

    static func defaultRootURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        AgentCatalog.sessionRoot(for: .pi, environment: environment)
    }

    /// Which agent owns an already-discovered file. Falls back to the roots this repository was
    /// actually built with, so a test fixture root resolves to its declared agent.
    func agent(for fileURL: URL) -> AgentKind {
        let path = fileURL.standardizedFileURL.path
        let match = roots
            .map { ($0.agent, $0.url.standardizedFileURL.path) }
            .sorted { $0.1.count > $1.1.count }
            .first { path.hasPrefix($0.1 + "/") || path == $0.1 }
        return match?.0 ?? AgentCatalog.agent(forSessionPath: path) ?? .pi
    }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        try await discoverSessions(archivedIDs: archivedIDs, agents: nil)
    }

    func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary] {
        let roots = roots.filter { agents?.contains($0.agent) ?? true }
        let candidates = try await Self.detached(priority: .utility) {
            try roots.flatMap { root in
                try Self.sessionCandidates(agent: root.agent, rootURL: root.url)
            }
        }
        try Task.checkCancellation()

        var summaries: [SessionSummary] = []
        var misses: [Candidate] = []
        summaries.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let cached = await summaryCache.summary(for: candidate.fingerprint, archivedIDs: archivedIDs) {
                summaries.append(cached)
            } else {
                misses.append(candidate)
            }
        }

        let parsed = try await withThrowingTaskGroup(of: (SessionSummary, SessionFileFingerprint)?.self) { group in
            var iterator = misses.makeIterator()
            for _ in 0..<min(4, misses.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask { try Self.parse(candidate, archivedIDs: archivedIDs) }
            }

            var values: [(SessionSummary, SessionFileFingerprint)] = []
            while let result = try await group.next() {
                if let result { values.append(result) }
                if let candidate = iterator.next() {
                    group.addTask { try Self.parse(candidate, archivedIDs: archivedIDs) }
                }
            }
            return values
        }
        for (summary, fingerprint) in parsed {
            summaries.append(summary)
            await summaryCache.store(summary, fingerprint: fingerprint)
        }
        _ = await summaryCache.pruneMissingFiles()
        try? await summaryCache.persist()

        // Subagent transcripts are parsed and cached like anything else, but never listed: they
        // are a tool's working notes, not one of the user's conversations.
        return summaries.filter { !$0.isSubsession }.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt { return lhs.displayName < rhs.displayName }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private static func parse(
        _ candidate: Candidate,
        archivedIDs: Set<String>
    ) throws -> (SessionSummary, SessionFileFingerprint) {
        try Task.checkCancellation()
        var summary = try SessionParser.summary(
            at: candidate.url,
            archivedIDs: archivedIDs,
            transcoder: .make(for: candidate.agent)
        )
        summary.agent = candidate.agent
        summary.applyExternalName()
        return (summary, candidate.fingerprint)
    }

    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary] {
        await summaryCache.liveSummaries(archivedIDs: archivedIDs)
            .filter { !$0.isSubsession }
            .sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt { return lhs.displayName < rhs.displayName }
                return lhs.modifiedAt > rhs.modifiedAt
            }
    }

    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        // NSURL can retain resource values across an append; recreate it before validating the cache.
        let fresh = URL(fileURLWithPath: fileURL.path)
        let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = SessionFileFingerprint(url: fresh, values: values)
        if let cached = await summaryCache.summary(for: fingerprint, archivedIDs: archivedIDs) { return cached }
        let agent = agent(for: fresh)
        var summary = try await Self.detached(priority: .utility) {
            try SessionParser.summary(at: fresh, archivedIDs: archivedIDs, transcoder: .make(for: agent))
        }
        summary.agent = agent
        summary.applyExternalName()
        await summaryCache.store(summary, fingerprint: fingerprint)
        try? await summaryCache.persist()
        return summary
    }

    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        let transcoder = AgentSessionTranscoder.make(for: agent(for: fileURL))
        return try await Self.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try SessionParser.conversation(at: fileURL, transcoder: transcoder)
        }
    }

    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan {
        let transcoder = AgentSessionTranscoder.make(for: agent(for: fileURL))
        return try await Self.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try SessionParser.conversationTail(at: fileURL, limit: limit, transcoder: transcoder)
        }
    }

    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage {
        let transcoder = AgentSessionTranscoder.make(for: agent(for: fileURL))
        return try await Self.detached(priority: .userInitiated) {
            try SessionParser.conversationPage(at: fileURL, transcoder: transcoder)
        }
    }

    func loadOlderConversationPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        let transcoder = AgentSessionTranscoder.make(for: agent(for: fileURL))
        return try await Self.detached(priority: .userInitiated) {
            try SessionParser.conversationPage(at: fileURL, cursor: cursor, transcoder: transcoder)
        }
    }

    func loadFocusedHistoryPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        let transcoder = AgentSessionTranscoder.make(for: agent(for: fileURL))
        return try await Self.detached(priority: .userInitiated) {
            try SessionParser.conversationPage(
                at: fileURL, cursor: cursor, projection: .focusedHistory, transcoder: transcoder
            )
        }
    }

    /// Detached work with cancellation propagated into the worker, so abandoning a selection
    /// actually stops the parse instead of leaving it to finish in the background.
    private static func detached<Value: Sendable>(
        priority: TaskPriority,
        operation: @Sendable @escaping () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private struct Candidate: Sendable {
        let agent: AgentKind
        let url: URL
        let fingerprint: SessionFileFingerprint
    }

    private static let resourceKeys: Set<URLResourceKey> =
        [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]

    /// Walks one agent's session root to that agent's declared depth. Pi and Claude keep one
    /// project folder below the root; Codex nests `YYYY/MM/DD`. Going deeper than an agent
    /// declares would sweep up its subagent and process artifacts.
    private static func sessionCandidates(agent: AgentKind, rootURL: URL) throws -> [Candidate] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path) else { return [] }
        let descriptor = AgentCatalog.descriptor(for: agent)

        var files: [URL] = []
        var frontier = [rootURL]
        for depth in 0...max(0, descriptor.sessionScanDepth) {
            var next: [URL] = []
            for directory in frontier {
                try Task.checkCancellation()
                let items = (try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                )) ?? []
                for item in items {
                    if (try? item.resourceValues(forKeys: resourceKeys).isDirectory) == true {
                        if depth < descriptor.sessionScanDepth { next.append(item) }
                    } else if item.pathExtension.lowercased() == "jsonl" {
                        guard let prefix = descriptor.sessionFilePrefix else {
                            files.append(item)
                            continue
                        }
                        if item.lastPathComponent.hasPrefix(prefix) { files.append(item) }
                    }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        var seen: Set<String> = []
        return files.compactMap { file in
            let normalized = file.standardizedFileURL
            guard seen.insert(normalized.path).inserted,
                  let values = try? normalized.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { return nil }
            return Candidate(
                agent: agent,
                url: normalized,
                fingerprint: SessionFileFingerprint(url: normalized, values: values)
            )
        }
    }
}

@MainActor
final class AppPersistence {
    private let fileURL: URL
    private(set) var state: PersistedAppState

    init(baseURL: URL? = nil) {
        let manager = FileManager.default
        let directory = baseURL ?? PatchworkPaths.supportDirectory
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("state.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedAppState.self, from: data) {
            state = decoded
        } else {
            state = PersistedAppState()
        }
        state.pruneCompletionState()
    }

    /// Records a conversation this app started. Bounded: the oldest entries are dropped rather
    /// than letting the set grow without limit, which at worst makes a very old conversation
    /// look foreign again.
    static let maxAppStartedPaths = 5_000

    func recordAppStarted(sessionPath: String) {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        guard !path.isEmpty, !state.appStartedSessionPaths.contains(path) else { return }
        state.appStartedSessionPaths.insert(path)
        if state.appStartedSessionPaths.count > Self.maxAppStartedPaths {
            state.appStartedSessionPaths = Set(
                state.appStartedSessionPaths.sorted().suffix(Self.maxAppStartedPaths)
            )
        }
        save()
    }

    func setShowsForeignConversations(_ shows: Bool) {
        guard state.showsForeignConversations != shows else { return }
        state.showsForeignConversations = shows
        save()
    }

    func setArchived(_ archived: Bool, sessionID: String, now: Date = Date()) {
        if archived {
            state.archivedSessionIDs.insert(sessionID)
            state.archivedAt[sessionID] = now
        } else {
            state.archivedSessionIDs.remove(sessionID)
            state.archivedAt.removeValue(forKey: sessionID)
        }
        save()
    }

    /// Records an explicit sidebar expansion choice. `nil` restores the recency default.
    func setFolderExpanded(_ expanded: Bool?, path: String) {
        state.expandedFolders.remove(path)
        state.collapsedFolders.remove(path)
        switch expanded {
        case true?: state.expandedFolders.insert(path)
        case false?: state.collapsedFolders.insert(path)
        case nil: break
        }
        save()
    }

    func cacheExtensionStatuses(_ values: [String: String]) {
        guard state.cachedExtensionStatuses != values else { return }
        state.cachedExtensionStatuses = values
        save()
    }

    func setLastFolder(_ path: String) {
        guard state.lastFolder != path else { return }
        state.lastFolder = path
        save()
    }

    func rememberFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        state.recentFolders.removeAll { $0 == path }
        state.recentFolders.insert(path, at: 0)
        state.recentFolders = Array(state.recentFolders.prefix(8))
        save()
    }

    func rememberImportedFolder(_ url: URL) {
        state.rememberImportedFolder(path: url.standardizedFileURL.path)
        save()
    }

    func setManagedWorktreeProject(_ project: URL?, for worktree: URL) {
        let worktreePath = worktree.standardizedFileURL.path
        let projectPath = project?.standardizedFileURL.path
        guard state.managedWorktreeProjects[worktreePath] != projectPath else { return }
        state.setManagedWorktreeProject(worktreePath: worktreePath, projectPath: projectPath)
        save()
    }

    func mergeManagedWorktreeProjects(_ projects: [String: String]) {
        var changed = false
        for (worktree, project) in projects where state.managedWorktreeProjects[worktree] == nil {
            state.setManagedWorktreeProject(worktreePath: worktree, projectPath: project)
            changed = true
        }
        if changed { save() }
    }

    func updateState(_ update: (inout PersistedAppState) -> Void) {
        update(&state)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
