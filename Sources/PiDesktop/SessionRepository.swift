import Foundation

protocol SessionRepositoryProtocol {
    var rootURL: URL { get }
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
    let rootURL: URL
    let summaryCache: SessionSummaryCache

    init(rootURL: URL = FileSessionRepository.defaultRootURL(), summaryCache: SessionSummaryCache? = nil) {
        self.rootURL = rootURL
        self.summaryCache = summaryCache ?? SessionSummaryCache()
    }

    static func defaultRootURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PI_CODING_AGENT_SESSION_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] {
        let rootURL = rootURL
        let candidates = try await Self.detached(priority: .utility) {
            try Self.sessionCandidates(rootURL: rootURL)
        }
        try Task.checkCancellation()

        var summaries: [SessionSummary] = []
        var misses: [(URL, SessionFileFingerprint)] = []
        summaries.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let cached = await summaryCache.summary(for: candidate.fingerprint, archivedIDs: archivedIDs) {
                summaries.append(cached)
            } else {
                misses.append((candidate.url, candidate.fingerprint))
            }
        }

        let parsed = try await withThrowingTaskGroup(of: (SessionSummary, SessionFileFingerprint)?.self) { group in
            var iterator = misses.makeIterator()
            for _ in 0..<min(4, misses.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask {
                    try Task.checkCancellation()
                    return (try SessionParser.summary(at: candidate.0, archivedIDs: archivedIDs), candidate.1)
                }
            }

            var values: [(SessionSummary, SessionFileFingerprint)] = []
            while let result = try await group.next() {
                if let result { values.append(result) }
                if let candidate = iterator.next() {
                    group.addTask {
                        try Task.checkCancellation()
                        return (try SessionParser.summary(at: candidate.0, archivedIDs: archivedIDs), candidate.1)
                    }
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

        return summaries.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt { return lhs.displayName < rhs.displayName }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    func cachedSessions(archivedIDs: Set<String>) async -> [SessionSummary] {
        await summaryCache.liveSummaries(archivedIDs: archivedIDs).sorted { lhs, rhs in
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
        let summary = try await Self.detached(priority: .utility) {
            try SessionParser.summary(at: fresh, archivedIDs: archivedIDs)
        }
        await summaryCache.store(summary, fingerprint: fingerprint)
        try? await summaryCache.persist()
        return summary
    }

    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        try await Self.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try SessionParser.conversation(at: fileURL)
        }
    }

    func loadConversationTail(from fileURL: URL, limit: Int) async throws -> SessionParser.TailScan {
        try await Self.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try SessionParser.conversationTail(at: fileURL, limit: limit)
        }
    }

    func loadNewestConversationPage(from fileURL: URL) async throws -> ConversationPage {
        try await Self.detached(priority: .userInitiated) {
            try SessionParser.conversationPage(at: fileURL)
        }
    }

    func loadOlderConversationPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        try await Self.detached(priority: .userInitiated) {
            try SessionParser.conversationPage(at: fileURL, cursor: cursor)
        }
    }

    func loadFocusedHistoryPage(from fileURL: URL, cursor: ConversationPageCursor) async throws -> ConversationPage {
        try await Self.detached(priority: .userInitiated) {
            try SessionParser.conversationPage(at: fileURL, cursor: cursor, projection: .focusedHistory)
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
        let url: URL
        let fingerprint: SessionFileFingerprint
    }

    private static func sessionCandidates(rootURL: URL) throws -> [Candidate] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let rootItems = try manager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        )

        // Pi stores one project directory below the session root. Only JSONLs directly in the
        // root or those project directories are user threads; deeper session.jsonl files are
        // subagent/process artifacts and must not be promoted into the sidebar.
        var files = rootItems.filter { $0.pathExtension.lowercased() == "jsonl" }
        for folder in rootItems where (try? folder.resourceValues(forKeys: keys).isDirectory) == true {
            try Task.checkCancellation()
            files += (try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: []
            ).filter { $0.pathExtension.lowercased() == "jsonl" }) ?? []
        }

        var seen: Set<String> = []
        return files.compactMap { file in
            let normalized = file.standardizedFileURL
            guard seen.insert(normalized.path).inserted,
                  let values = try? normalized.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return Candidate(url: normalized, fingerprint: SessionFileFingerprint(url: normalized, values: values))
        }
    }
}

@MainActor
final class AppPersistence {
    private let fileURL: URL
    private(set) var state: PersistedAppState

    init(baseURL: URL? = nil) {
        let manager = FileManager.default
        let directory = baseURL ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pi Desktop", isDirectory: true)
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

    func setManagedWorktreeProject(_ project: URL?, for worktree: URL) {
        let worktreePath = worktree.standardizedFileURL.path
        let projectPath = project?.standardizedFileURL.path
        guard state.managedWorktreeProjects[worktreePath] != projectPath else { return }
        state.setManagedWorktreeProject(worktreePath: worktreePath, projectPath: projectPath)
        save()
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
