import Foundation
import PatchworkKit

struct SessionObservationRoot: Hashable, Sendable {
    let agent: AgentKind
    let url: URL
    /// A custom-root transcript is watched through its parent directory, but only this exact file
    /// may become a catalog candidate. Siblings remain outside discovery.
    let exactFilePath: String?

    init(agent: AgentKind, url: URL, exactFilePath: String? = nil) {
        self.agent = agent
        self.url = url
        self.exactFilePath = exactFilePath
    }
}

protocol SessionRepositoryProtocol {
    var rootURL: URL { get }
    /// Discovery narrowed to the agents the user has switched on. Declared here rather than only
    /// in the extension below: an extension member dispatches statically through a protocol
    /// existential, so the file repository's root-skipping override would never have run.
    func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary]
    /// Exact app-owned or daemon-owned paths outside static agent roots. Pi can choose one through
    /// cwd-specific settings, so catalog refreshes must retain these without scanning arbitrary
    /// parent trees.
    func discoverSessions(
        archivedIDs: Set<String>,
        agents: Set<AgentKind>?,
        supplementalPaths: Set<String>
    ) async throws -> [SessionSummary]
    /// Which agent wrote a transcript, decided by the session root it lives under.
    func agent(for fileURL: URL) -> AgentKind
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary]
    func loadConversation(from fileURL: URL) async throws -> SessionConversation
    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage
    func loadOlderConversationPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary
    /// Sidebar hydration: everything the persisted summary cache already knows, with no disk
    /// scan and no JSONL parsing, so the first paint is immediate.
    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary]
    /// Fast partial parse for the "instant tail" first paint on a cache miss (Task 1): the last
    /// `limit` renderable messages, read backward from EOF so latency does not scale with total
    /// file size. `isComplete` reports whether this already *is* the whole conversation.
    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan
    /// Recursive roots whose topology can add or remove sidebar conversations. Fakes default to
    /// none so tests never install filesystem streams accidentally.
    func observationRoots(agents: Set<AgentKind>?) -> [SessionObservationRoot]
    func observationRoots(
        agents: Set<AgentKind>?, supplementalPaths: Set<String>
    ) -> [SessionObservationRoot]
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

    func discoverSessions(
        archivedIDs: Set<String>,
        agents: Set<AgentKind>?,
        supplementalPaths: Set<String>
    ) async throws -> [SessionSummary] {
        var discovered = try await discoverSessions(archivedIDs: archivedIDs, agents: agents)
        var seen = Set(discovered.map { $0.fileURL.standardizedFileURL.path })
        for rawPath in supplementalPaths.sorted().suffix(SessionScanner.supplementalPathLimit) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard url.pathExtension.lowercased() == "jsonl",
                  seen.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let pathAgent = agent(for: url)
            guard agents?.contains(pathAgent) ?? true,
                  var summary = try? await refreshSummary(at: url, archivedIDs: archivedIDs),
                  !summary.isSubsession else { continue }
            summary.agent = pathAgent
            discovered.append(summary)
        }
        return discovered.sorted { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt
                ? lhs.displayName < rhs.displayName
                : lhs.modifiedAt > rhs.modifiedAt
        }
    }

    /// Fakes and legacy repositories only ever hold Pi sessions.
    func agent(for fileURL: URL) -> AgentKind { .pi }

    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary] { [] }
    func observationRoots(agents: Set<AgentKind>?) -> [SessionObservationRoot] { [] }
    func observationRoots(
        agents: Set<AgentKind>?, supplementalPaths: Set<String>
    ) -> [SessionObservationRoot] {
        observationRoots(agents: agents)
    }
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

}

struct FileSessionRepository: SessionRepositoryProtocol {
    /// Pi's own root. Retained because callers still use it as "where a new Pi thread lands";
    /// discovery itself walks every agent root in `roots`.
    let rootURL: URL
    /// Every agent whose session tree exists on this machine, with the root to scan for it.
    let roots: [(agent: AgentKind, url: URL)]
    let summaryCache: SessionSummaryCache
    private let externalTitleSnapshot: @Sendable () -> [String: String]

    init(
        rootURL: URL = FileSessionRepository.defaultRootURL(),
        roots: [(agent: AgentKind, url: URL)]? = nil,
        summaryCache: SessionSummaryCache? = nil,
        externalTitleSnapshot: @escaping @Sendable () -> [String: String] = {
            CodexThreadTitles.shared.snapshot()
        }
    ) {
        self.rootURL = rootURL
        // Pinning Pi's root to a fixture tree pins all of them; see `SessionScanner.roots`.
        self.roots = roots ?? SessionScanner.roots(piRootURL: rootURL)
        self.summaryCache = summaryCache ?? SessionSummaryCache()
        self.externalTitleSnapshot = externalTitleSnapshot
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

    func observationRoots(agents: Set<AgentKind>?) -> [SessionObservationRoot] {
        roots.compactMap { root in
            guard agents?.contains(root.agent) ?? true else { return nil }
            return SessionObservationRoot(agent: root.agent, url: root.url.standardizedFileURL)
        }
    }

    func observationRoots(
        agents: Set<AgentKind>?, supplementalPaths: Set<String>
    ) -> [SessionObservationRoot] {
        let staticRoots = observationRoots(agents: agents)
        let rootPaths = staticRoots.map { $0.url.standardizedFileURL.path }
        var seen = Set(staticRoots)
        var result = staticRoots
        for rawPath in supplementalPaths.sorted().suffix(SessionScanner.supplementalPathLimit) {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard path.lowercased().hasSuffix(".jsonl"),
                  !rootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                continue
            }
            let agent = self.agent(for: URL(fileURLWithPath: path))
            guard agents?.contains(agent) ?? true else { continue }
            let observation = SessionObservationRoot(
                agent: agent,
                url: URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL,
                exactFilePath: path
            )
            if seen.insert(observation).inserted { result.append(observation) }
        }
        return result
    }

    func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary] {
        try await discoverSessions(
            archivedIDs: archivedIDs,
            agents: agents,
            supplementalPaths: []
        )
    }

    func discoverSessions(
        archivedIDs: Set<String>,
        agents: Set<AgentKind>?,
        supplementalPaths: Set<String>
    ) async throws -> [SessionSummary] {
        let enabledRoots = roots
            .filter { agents?.contains($0.agent) ?? true }
            .sorted {
                $0.url.standardizedFileURL.path.count > $1.url.standardizedFileURL.path.count
            }
        let classificationRoots = roots
        let candidates = try await Self.detached(priority: .utility) {
            let rooted = try enabledRoots.flatMap { root in
                try Self.sessionCandidates(agent: root.agent, rootURL: root.url)
            }
            let supplemental = Self.supplementalCandidates(
                paths: supplementalPaths,
                roots: classificationRoots,
                agents: agents
            )
            var seen: Set<String> = []
            return (rooted + supplemental).filter {
                seen.insert($0.url.standardizedFileURL.path).inserted
            }
        }
        try Task.checkCancellation()

        var summaries: [SessionSummary] = []
        var misses: [Candidate] = []
        summaries.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let cached = await summaryCache.summary(
                for: candidate.fingerprint,
                archivedIDs: archivedIDs,
                expectedAgent: candidate.agent
            ) {
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

        let titles = await currentExternalTitles(ifNeededFor: summaries)
        for index in summaries.indices { summaries[index].applyExternalName(from: titles) }

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
        return (summary, candidate.fingerprint)
    }

    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary] {
        var summaries = await summaryCache.liveSummaries(archivedIDs: archivedIDs)
        let titles = await currentExternalTitles(ifNeededFor: summaries)
        for index in summaries.indices { summaries[index].applyExternalName(from: titles) }
        return summaries.filter { !$0.isSubsession }
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
        let agent = agent(for: fresh)
        if var cached = await summaryCache.summary(
            for: fingerprint,
            archivedIDs: archivedIDs,
            expectedAgent: agent
        ) {
            let titles = await currentExternalTitles(ifNeededFor: [cached])
            cached.applyExternalName(from: titles)
            return cached
        }
        var summary = try await Self.detached(priority: .utility) {
            try SessionParser.summary(at: fresh, archivedIDs: archivedIDs, transcoder: .make(for: agent))
        }
        summary.agent = agent
        await summaryCache.store(summary, fingerprint: fingerprint)
        var presented = summary
        let titles = await currentExternalTitles(ifNeededFor: [presented])
        presented.applyExternalName(from: titles)
        return presented
    }

    private func currentExternalTitles(ifNeededFor summaries: [SessionSummary]) async -> [String: String] {
        guard summaries.contains(where: { $0.agent == .codex }) else { return [:] }
        let snapshot = externalTitleSnapshot
        return await Task.detached(priority: .utility) { snapshot() }.value
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

    private static func supplementalCandidates(
        paths: Set<String>,
        roots: [(agent: AgentKind, url: URL)],
        agents: Set<AgentKind>?
    ) -> [Candidate] {
        let orderedRoots = roots.sorted {
            $0.url.standardizedFileURL.path.count > $1.url.standardizedFileURL.path.count
        }
        return paths.sorted().suffix(SessionScanner.supplementalPathLimit).compactMap { rawPath in
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard url.pathExtension.lowercased() == "jsonl",
                  let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { return nil }
            let pathAgent = orderedRoots.first { root in
                let rootPath = root.url.standardizedFileURL.path
                return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
            }?.agent ?? .pi
            guard agents?.contains(pathAgent) ?? true else { return nil }
            return Candidate(
                agent: pathAgent,
                url: url,
                fingerprint: SessionFileFingerprint(url: url, values: values)
            )
        }
    }
}

@MainActor
final class AppPersistence {
    struct DaemonReadUpdate {
        var path: String
        var unread: Bool
        var markedAt: Date
        var completionID: String?
    }

    private let fileURL: URL
    private(set) var state: PersistedAppState
    static let maxStateBytes = ArchiveStateBounds.appStateByteLimit

    init(baseURL: URL? = nil) {
        let manager = FileManager.default
        let directory = baseURL ?? PatchworkPaths.supportDirectory
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("state.json")

        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let fileSize, fileSize <= Self.maxStateBytes,
           let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
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

    @discardableResult
    func recordAppStarted(sessionPath: String) -> Bool {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        guard !path.isEmpty else { return false }
        guard !state.appStartedSessionPaths.contains(path) else { return true }
        let previous = state.appStartedSessionPaths
        state.appStartedSessionPaths.insert(path)
        if state.appStartedSessionPaths.count > Self.maxAppStartedPaths {
            let overflow = state.appStartedSessionPaths.count - Self.maxAppStartedPaths
            for stale in state.appStartedSessionPaths
                .filter({ $0 != path }).sorted().prefix(overflow) {
                state.appStartedSessionPaths.remove(stale)
            }
        }
        guard save() else {
            state.appStartedSessionPaths = previous
            return false
        }
        return true
    }

    @discardableResult
    func discardAppStarted(sessionPath: String) -> Bool {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        guard state.appStartedSessionPaths.remove(path) != nil else { return true }
        guard save() else {
            state.appStartedSessionPaths.insert(path)
            return false
        }
        return true
    }

    func setShowsForeignConversations(_ shows: Bool) {
        guard state.showsForeignConversations != shows else { return }
        state.showsForeignConversations = shows
        save()
    }

    func isArchived(sessionID: String, sessionPath: String) -> Bool {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        return state.archivedSessionPaths.contains(path)
            || (state.archivedSessionIDs.contains(sessionID)
                && !state.archiveExemptSessionPaths.contains(path))
    }

    func archivedDate(sessionID: String, sessionPath: String) -> Date? {
        state.archivedAtBySessionPath[URL(fileURLWithPath: sessionPath).standardizedFileURL.path]
            ?? state.archivedAt[sessionID]
    }

    func noteArchivePresentation(_ archived: Bool, sessionPath: String, now: Date = Date()) {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        if archived {
            guard state.archivedAtBySessionPath[path] == nil else { return }
            state.archivedAtBySessionPath[path] = now
        } else {
            guard state.archivedAtBySessionPath.removeValue(forKey: path) != nil else { return }
        }
        save()
    }

    func setArchived(
        _ archived: Bool,
        sessionID: String,
        sessionPath: String,
        now: Date = Date(),
        queueDaemonSync: Bool = false
    ) {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        if archived {
            state.archiveExemptSessionPaths.remove(path)
            state.archivedSessionPaths.insert(path)
            state.archivedAtBySessionPath[path] = now
        } else {
            state.archivedSessionPaths.remove(path)
            state.archivedAtBySessionPath.removeValue(forKey: path)
            if state.archivedSessionIDs.contains(sessionID) {
                state.archiveExemptSessionPaths.insert(path)
            } else {
                state.archiveExemptSessionPaths.remove(path)
            }
        }
        if state.archivedSessionPaths.count > 10_000 {
            let overflow = state.archivedSessionPaths.count - 10_000
            let oldest = state.archivedSessionPaths.sorted {
                (state.archivedAtBySessionPath[$0] ?? .distantPast)
                    < (state.archivedAtBySessionPath[$1] ?? .distantPast)
            }.prefix(overflow)
            for stale in oldest {
                state.archivedSessionPaths.remove(stale)
                state.archivedAtBySessionPath.removeValue(forKey: stale)
            }
        }
        if state.archivedAtBySessionPath.count > 10_000 {
            state.archivedAtBySessionPath = Dictionary(uniqueKeysWithValues:
                state.archivedAtBySessionPath
                    .sorted { $0.value < $1.value }
                    .suffix(10_000)
            )
        }
        if state.archiveExemptSessionPaths.count > 10_000 {
            let overflow = state.archiveExemptSessionPaths.count - 10_000
            for stale in state.archiveExemptSessionPaths
                .filter({ $0 != path }).sorted().prefix(overflow) {
                state.archiveExemptSessionPaths.remove(stale)
            }
        }
        if queueDaemonSync {
            state.setPendingDaemonArchiveIntent(path: path, archived: archived)
        }
        save()
    }

    /// Clears only the value that the daemon actually acknowledged. A late restore response must
    /// not erase a newer archive intent for the same conversation.
    @discardableResult
    func acknowledgeArchiveSync(path rawPath: String, expected: Bool) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard state.pendingDaemonArchiveIntentBySessionPath[path] == expected else { return false }
        state.pendingDaemonArchiveIntentBySessionPath.removeValue(forKey: path)
        save()
        return true
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

    /// Applies one daemon snapshot in one state-file write. A timestamp bridges the short window
    /// before the activity monitor has learned the latest completion id, so a remotely read
    /// conversation does not flash unread again when that heartbeat arrives.
    func applyDaemonReadUpdates(_ updates: [DaemonReadUpdate]) {
        guard !updates.isEmpty else { return }
        var changed = false
        for update in updates {
            let path = URL(fileURLWithPath: update.path).standardizedFileURL.path
            if update.unread {
                if state.manuallyUnreadSessionPaths.insert(path).inserted { changed = true }
                if state.lastReadAt.removeValue(forKey: path) != nil { changed = true }
            } else {
                if state.manuallyUnreadSessionPaths.remove(path) != nil { changed = true }
                if let completionID = update.completionID {
                    if state.latestCompletedEntryIDBySessionPath[path] != completionID {
                        state.latestCompletedEntryIDBySessionPath[path] = completionID
                        changed = true
                    }
                    if state.lastSeenCompletedEntryIDBySessionPath[path] != completionID {
                        state.lastSeenCompletedEntryIDBySessionPath[path] = completionID
                        changed = true
                    }
                    if state.lastReadAt.removeValue(forKey: path) != nil { changed = true }
                } else {
                    if update.markedAt > (state.lastReadAt[path] ?? .distantPast) {
                        state.lastReadAt[path] = update.markedAt
                        changed = true
                    }
                }
            }
        }
        guard changed else { return }
        state.pruneCompletionState(preferredPath: updates.last.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        save()
    }

    func updateState(_ update: (inout PersistedAppState) -> Void) {
        update(&state)
        save()
    }

    @discardableResult
    func updateStateIfChanged(_ update: (inout PersistedAppState) -> Bool) -> Bool {
        guard update(&state) else { return false }
        save()
        return true
    }

    @discardableResult
    private func save() -> Bool {
        guard let data = try? JSONEncoder().encode(state), data.count <= Self.maxStateBytes else {
            return false
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
extension AppPersistence: ScheduleMutationIntentPersisting {
    var scheduleMutationIntents: [String: ScheduleMutationIntent] {
        state.scheduleMutationIntents
    }

    @discardableResult
    func replaceScheduleMutationIntents(_ values: [String: ScheduleMutationIntent]) -> Bool {
        guard ScheduleMutationIntent.isWithinNormalBounds(values) else { return false }
        let previous = state.scheduleMutationIntents
        state.scheduleMutationIntents = values
        guard save() else {
            state.scheduleMutationIntents = previous
            return false
        }
        return true
    }
}
