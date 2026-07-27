import Foundation

/// An app-owned organizational folder. It never maps to, creates, or mutates a filesystem
/// directory; assignments are Pi Desktop metadata keyed by the session file's stable path.
///
/// `parentID` places a folder in the same tree `SidebarView.SessionFolderGroup` renders, using
/// the identical id scheme: `nil` is top level, a filesystem project path (e.g.
/// `/Users/vince/code`) nests inside that project group, and `"virtual:<uuid>"` nests inside
/// another virtual folder. Sharing the scheme means a drop target's or menu's group id can be
/// written straight into `parentID` with no translation.
struct VirtualFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var parentID: String?

    init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), parentID: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentID = parentID
    }

    /// Hand-written so folders persisted before nesting existed (no `parentID` key) keep
    /// decoding as top-level, matching `PersistedAppState`'s forward-compatible pattern.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
    }
}

/// Pure CRUD/move/tree rules shared by persistence and tests.
enum WorkspaceOrganization {
    static func cleanedName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(80))
    }

    /// Same id scheme `SessionFolderGroup.id` uses: a filesystem project path names itself, a
    /// virtual folder is `"virtual:<uuid>"`. `virtualFolderID` inverts it; a plain project path
    /// has no folder id and returns `nil`.
    static func groupID(forVirtualFolderID id: String) -> String { "virtual:\(id)" }

    static func virtualFolderID(fromGroupID groupID: String) -> String? {
        groupID.hasPrefix("virtual:") ? String(groupID.dropFirst("virtual:".count)) : nil
    }

    /// Ancestor folder ids walking up from `folderID` through `parentID`, nearest first. Stops
    /// at top level, a filesystem project, or the first repeated id, so a corrupted cycle can
    /// never make this loop forever.
    static func ancestorFolderIDs(of folderID: String, in folders: [VirtualFolder]) -> [String] {
        var chain: [String] = []
        var visited: Set<String> = [folderID]
        var currentID = folderID
        while let node = folders.first(where: { $0.id == currentID }),
              let parentGroupID = node.parentID,
              let parentFolderID = virtualFolderID(fromGroupID: parentGroupID) {
            guard visited.insert(parentFolderID).inserted else { break }
            chain.append(parentFolderID)
            currentID = parentFolderID
        }
        return chain
    }

    /// A folder can never become its own ancestor: true if `newParentFolderID` is `folderID`
    /// itself or already sits underneath it.
    static func wouldCreateCycle(moving folderID: String, into newParentFolderID: String, in folders: [VirtualFolder]) -> Bool {
        newParentFolderID == folderID || ancestorFolderIDs(of: newParentFolderID, in: folders).contains(folderID)
    }

    /// Defensive parent resolution for rendering: a dangling virtual parent, or an ancestor
    /// cycle that `reparent` should have made unreachable, both degrade to top level instead of
    /// hanging the sidebar tree in infinite recursion over hand-edited state.
    static func effectiveParentID(of folder: VirtualFolder, in folders: [VirtualFolder]) -> String? {
        guard let parentGroupID = folder.parentID else { return nil }
        guard let parentFolderID = virtualFolderID(fromGroupID: parentGroupID) else { return parentGroupID }
        guard folders.contains(where: { $0.id == parentFolderID }),
              !wouldCreateCycle(moving: folder.id, into: parentFolderID, in: folders) else { return nil }
        return parentGroupID
    }

    /// `parentID` may be top level, a filesystem project path (always accepted \u2014 projects are
    /// derived from live sessions, never persisted as entities), or another folder's group id
    /// (must already exist).
    static func create(named name: String, parentID: String? = nil, in folders: inout [VirtualFolder]) -> VirtualFolder? {
        guard let clean = cleanedName(name) else { return nil }
        if let parentID, let parentFolderID = virtualFolderID(fromGroupID: parentID) {
            guard folders.contains(where: { $0.id == parentFolderID }) else { return nil }
        }
        let folder = VirtualFolder(name: clean, parentID: parentID)
        folders.append(folder)
        return folder
    }

    @discardableResult
    static func rename(id: String, to name: String, in folders: inout [VirtualFolder]) -> Bool {
        guard let clean = cleanedName(name), let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[index].name = clean
        return true
    }

    /// Refuses a move that would make `id` its own ancestor or that targets a virtual folder
    /// that does not exist; a filesystem project path or top level (`nil`) is always accepted.
    @discardableResult
    static func reparent(id: String, to newParentGroupID: String?, in folders: inout [VirtualFolder]) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        if let newParentGroupID, let newParentFolderID = virtualFolderID(fromGroupID: newParentGroupID) {
            guard folders.contains(where: { $0.id == newParentFolderID }),
                  !wouldCreateCycle(moving: id, into: newParentFolderID, in: folders) else { return false }
        }
        folders[index].parentID = newParentGroupID
        return true
    }

    /// Deleting a folder reparents its direct children up to the deleted folder's own parent
    /// (least destructive: a subtree stays together instead of scattering to top level) and
    /// clears only assignments that pointed at the deleted folder itself \u2014 sessions filed under
    /// a surviving child or grandchild keep their assignment untouched.
    @discardableResult
    static func delete(id: String, folders: inout [VirtualFolder], assignments: inout [String: String]) -> Bool {
        guard let target = folders.first(where: { $0.id == id }) else { return false }
        let deletedGroupID = groupID(forVirtualFolderID: id)
        for index in folders.indices where folders[index].parentID == deletedGroupID {
            folders[index].parentID = target.parentID
        }
        folders.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        return true
    }

    static func move(sessionPath: String, to folderID: String?, folders: [VirtualFolder], assignments: inout [String: String]) {
        let path = URL(fileURLWithPath: sessionPath).standardizedFileURL.path
        guard let folderID else {
            assignments.removeValue(forKey: path)
            return
        }
        guard folders.contains(where: { $0.id == folderID }) else { return }
        assignments[path] = folderID
    }

    struct FolderTreeEntry: Identifiable {
        let folder: VirtualFolder
        let depth: Int
        var id: String { folder.id }
    }

    /// Depth-first order of the folders parented directly or indirectly under `parentGroupID`
    /// (`nil` for top level), for pickers like "Move to\u2026". Uses the same cycle-safe parent
    /// resolution as rendering, and `maxDepth` is a second, independent recursion guard.
    static func orderedChildren(
        of parentGroupID: String?, in folders: [VirtualFolder], depth: Int = 0, maxDepth: Int = 48
    ) -> [FolderTreeEntry] {
        guard depth < maxDepth else { return [] }
        let direct = folders
            .filter { effectiveParentID(of: $0, in: folders) == parentGroupID }
            .sorted { $0.createdAt < $1.createdAt }
        return direct.flatMap { folder in
            [FolderTreeEntry(folder: folder, depth: depth)]
                + orderedChildren(of: groupID(forVirtualFolderID: folder.id), in: folders, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Every folder exactly once: the top-level subtree first, then each filesystem project
    /// that hosts folders (first-seen order), so a flat picker can show the whole tree with
    /// simple per-depth indentation.
    static func allFolderEntries(_ folders: [VirtualFolder]) -> [FolderTreeEntry] {
        var roots: [String?] = [nil]
        var seenProjectPaths: Set<String> = []
        for folder in folders {
            guard let parent = effectiveParentID(of: folder, in: folders), virtualFolderID(fromGroupID: parent) == nil,
                  seenProjectPaths.insert(parent).inserted else { continue }
            roots.append(parent)
        }
        return roots.flatMap { orderedChildren(of: $0, in: folders) }
    }

    // MARK: - Default working directory for a folder-scoped new chat

    /// The working directory offered when starting a chat "inside" a virtual folder (the
    /// sidebar's `+` and "New Chat Here"), since a virtual folder — unlike a project group — has
    /// no cwd of its own. Each tier is tried only once the previous one has nothing to offer:
    /// 1. The cwd shared by the folder's own directly-assigned sessions: their most common cwd,
    ///    so a folder that already leans toward one project keeps new chats there even if a
    ///    stray session or two came from elsewhere. Ties break on the most recently modified
    ///    session, the same recency preference `SidebarSnapshot` sorts groups by.
    /// 2. The nearest enclosing filesystem project, found by walking up through parent virtual
    ///    folders — an empty folder nested inside a project should still start there.
    /// 3. `fallback`: the caller's ordinary default (whatever a plain "New chat" would use).
    static func defaultWorkingDirectory(
        forVirtualFolder folderID: String,
        sessions: [SessionSummary],
        assignments: [String: String],
        folders: [VirtualFolder],
        fallback: URL
    ) -> URL {
        if let shared = mostCommonCwd(inVirtualFolder: folderID, sessions: sessions, assignments: assignments) {
            return shared
        }
        if let project = enclosingProjectPath(ofVirtualFolder: folderID, folders: folders) {
            return URL(fileURLWithPath: project, isDirectory: true)
        }
        return fallback
    }

    private static func mostCommonCwd(
        inVirtualFolder folderID: String, sessions: [SessionSummary], assignments: [String: String]
    ) -> URL? {
        let own = sessions.filter { assignments[$0.fileURL.standardizedFileURL.path] == folderID }
        guard !own.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for session in own { counts[session.cwd.standardizedFileURL.path, default: 0] += 1 }
        let topCount = counts.values.max() ?? 0
        let tiedPaths = Set(counts.filter { $0.value == topCount }.map(\.key))
        let winner = own
            .filter { tiedPaths.contains($0.cwd.standardizedFileURL.path) }
            .max { $0.modifiedAt < $1.modifiedAt }
        return winner.map { URL(fileURLWithPath: $0.cwd.standardizedFileURL.path, isDirectory: true) }
    }

    /// Walks up through parent virtual folders — cycle-safe like `effectiveParentID`, which this
    /// reuses at every step — until it finds a filesystem project parent or runs out of ancestors.
    private static func enclosingProjectPath(ofVirtualFolder folderID: String, folders: [VirtualFolder]) -> String? {
        var visited: Set<String> = [folderID]
        var currentID = folderID
        while let folder = folders.first(where: { $0.id == currentID }) {
            guard let parent = effectiveParentID(of: folder, in: folders) else { return nil }
            guard let parentFolderID = virtualFolderID(fromGroupID: parent) else { return parent }
            guard visited.insert(parentFolderID).inserted else { return nil }
            currentID = parentFolderID
        }
        return nil
    }
}

extension AppPersistence {
    @discardableResult
    func createVirtualFolder(named name: String, parentID: String? = nil) -> VirtualFolder? {
        var result: VirtualFolder?
        updateState { result = WorkspaceOrganization.create(named: name, parentID: parentID, in: &$0.virtualFolders) }
        return result
    }

    func renameVirtualFolder(id: String, to name: String) -> Bool {
        var changed = false
        updateState { changed = WorkspaceOrganization.rename(id: id, to: name, in: &$0.virtualFolders) }
        return changed
    }

    @discardableResult
    func reparentVirtualFolder(id: String, to parentID: String?) -> Bool {
        var changed = false
        updateState { changed = WorkspaceOrganization.reparent(id: id, to: parentID, in: &$0.virtualFolders) }
        return changed
    }

    func deleteVirtualFolder(id: String) -> Bool {
        var changed = false
        updateState { state in
            var folders = state.virtualFolders
            var assignments = state.virtualFolderAssignments
            changed = WorkspaceOrganization.delete(id: id, folders: &folders, assignments: &assignments)
            if changed {
                state.virtualFolders = folders
                state.virtualFolderAssignments = assignments
            }
        }
        return changed
    }

    func moveSession(path: String, toVirtualFolder folderID: String?) {
        updateState { state in
            var assignments = state.virtualFolderAssignments
            WorkspaceOrganization.move(
                sessionPath: path,
                to: folderID,
                folders: state.virtualFolders,
                assignments: &assignments
            )
            state.virtualFolderAssignments = assignments
        }
    }

    /// Returns true only when this is a different completion from the last one persisted.
    @discardableResult
    func observeCompletedEntry(
        path: String, completionID: String, modifiedAt: Date, markSeen: Bool
    ) -> Bool {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        let previous = state.latestCompletedEntryIDBySessionPath[key]
        updateState { state in
            if previous == nil, let legacyReadAt = state.lastReadAt[key], modifiedAt <= legacyReadAt {
                state.lastSeenCompletedEntryIDBySessionPath[key] = completionID
            }
            state.lastReadAt.removeValue(forKey: key)
            state.latestCompletedEntryIDBySessionPath[key] = completionID
            if markSeen { state.lastSeenCompletedEntryIDBySessionPath[key] = completionID }
            state.pruneCompletionState(preferredPath: key)
        }
        return previous != completionID
    }

    func markSessionRead(path: String, completionID: String?) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        updateState { state in
            state.lastReadAt.removeValue(forKey: key)
            if let completionID {
                state.latestCompletedEntryIDBySessionPath[key] = completionID
                state.lastSeenCompletedEntryIDBySessionPath[key] = completionID
                state.pruneCompletionState(preferredPath: key)
            }
            state.manuallyUnreadSessionPaths.remove(key)
        }
    }

    func markSessionUnread(path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        updateState { $0.manuallyUnreadSessionPaths.insert(key) }
    }

    func pruneCompletionState(retainingSessionPaths paths: [String]) {
        let normalized = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var pruned = state
        pruned.pruneCompletionState(retaining: normalized)
        guard pruned.latestCompletedEntryIDBySessionPath != state.latestCompletedEntryIDBySessionPath
                || pruned.lastSeenCompletedEntryIDBySessionPath != state.lastSeenCompletedEntryIDBySessionPath
                || pruned.lastReadAt != state.lastReadAt
                || pruned.manuallyUnreadSessionPaths != state.manuallyUnreadSessionPaths else { return }
        updateState { $0 = pruned }
    }
}

@MainActor
extension AppStore {
    /// "Nowhere" is deliberately ordinary and safe: Pi starts in ~/Desktop until the user
    /// chooses another cwd. This is the integration surface for NewChatView.
    static var nowhereFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    var virtualFolders: [VirtualFolder] { persistence.state.virtualFolders }
    var virtualFolderAssignments: [String: String] { persistence.state.virtualFolderAssignments }

    func virtualFolderID(for session: SessionSummary) -> String? {
        let path = session.fileURL.standardizedFileURL.path
        let candidate = persistence.state.virtualFolderAssignments[path]
        return virtualFolders.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    func displayFolderName(for session: SessionSummary) -> String {
        guard let id = virtualFolderID(for: session), let folder = virtualFolders.first(where: { $0.id == id }) else {
            return session.folderName
        }
        return folder.name
    }

    @discardableResult
    func createVirtualFolder(named name: String, parentID: String? = nil) -> VirtualFolder? {
        guard let folder = persistence.createVirtualFolder(named: name, parentID: parentID) else { return nil }
        objectWillChange.send()
        return folder
    }

    func renameVirtualFolder(id: String, to name: String) {
        guard persistence.renameVirtualFolder(id: id, to: name) else { return }
        objectWillChange.send()
    }

    func reparentVirtualFolder(id: String, to parentID: String?) {
        guard persistence.reparentVirtualFolder(id: id, to: parentID) else { return }
        objectWillChange.send()
    }

    func deleteVirtualFolder(id: String) {
        guard persistence.deleteVirtualFolder(id: id) else { return }
        objectWillChange.send()
    }

    func moveSession(_ session: SessionSummary, toVirtualFolder folderID: String?) {
        persistence.moveSession(path: session.fileURL.path, toVirtualFolder: folderID)
        objectWillChange.send()
    }

    /// Working directory for a chat started via a virtual folder's `+`/"New Chat Here"; see
    /// `WorkspaceOrganization.defaultWorkingDirectory` for the exact preference order.
    /// `selectedFolder` stands in for "the current default" (its last tier): it already holds
    /// whichever folder a plain "New chat" would use — the most recently used one, or the safe
    /// home-directory fallback before any folder has ever been chosen.
    func defaultWorkingDirectory(forVirtualFolder folderID: String) -> URL {
        WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: folderID,
            sessions: sessions,
            assignments: virtualFolderAssignments,
            folders: virtualFolders,
            fallback: selectedFolder ?? Self.nowhereFolderURL
        )
    }

    func markRead(_ session: SessionSummary) {
        let path = session.fileURL.standardizedFileURL.path
        let completionID = activityMonitor.activity(forPath: path)?.latestCompletedEntryID
            ?? persistence.state.latestCompletedEntryIDBySessionPath[path]
        persistence.markSessionRead(path: path, completionID: completionID)
        objectWillChange.send()
    }

    func markUnread(_ session: SessionSummary) {
        persistence.markSessionUnread(path: session.fileURL.path)
        objectWillChange.send()
    }

    func isUnread(_ session: SessionSummary) -> Bool {
        let path = session.fileURL.standardizedFileURL.path
        if persistence.state.manuallyUnreadSessionPaths.contains(path) { return true }
        if selectedSession?.fileURL.standardizedFileURL.path == path { return false }
        guard let latest = activityMonitor.activity(forPath: path)?.latestCompletedEntryID
                ?? persistence.state.latestCompletedEntryIDBySessionPath[path] else { return false }
        return persistence.state.lastSeenCompletedEntryIDBySessionPath[path] != latest
    }

    /// Free global shortcut: Option-Command-U marks the selected conversation unread.
    func markSelectedUnread() {
        guard let selectedSession else { return }
        markUnread(selectedSession)
    }
}
