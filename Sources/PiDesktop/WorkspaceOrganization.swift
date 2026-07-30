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
    /// Pi requires a cwd even for a conversation that is not tied to a project.
    static let globalWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true)

    static func isGlobalWorkingDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.path == globalWorkingDirectory.standardizedFileURL.path
    }

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

    static func normalizedProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func normalizedGroupID(_ groupID: String) -> String {
        virtualFolderID(fromGroupID: groupID) == nil ? normalizedProjectPath(groupID) : groupID
    }

    /// Raw parent lookup across both node kinds. A virtual folder stores its parent directly;
    /// a real project stores the virtual folder it was filed under in `projectAssignments`.
    private static func rawParentGroupID(
        of groupID: String,
        folders: [VirtualFolder],
        projectAssignments: [String: String]
    ) -> String? {
        if let folderID = virtualFolderID(fromGroupID: groupID) {
            return folders.first(where: { $0.id == folderID })?.parentID.map(normalizedGroupID)
        }
        let projectPath = normalizedProjectPath(groupID)
        guard let folderID = projectAssignments[projectPath], folders.contains(where: { $0.id == folderID }) else { return nil }
        return self.groupID(forVirtualFolderID: folderID)
    }

    /// One cycle rule for the alternating tree (virtual → project → virtual is valid). Walking
    /// raw parents keeps this usable while validating an edit; repeated corrupt ancestry also
    /// refuses the edit instead of making the corruption harder to recover from.
    static func wouldCreateGroupCycle(
        moving groupID: String,
        into parentGroupID: String,
        folders: [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> Bool {
        let movingID = normalizedGroupID(groupID)
        var current: String? = normalizedGroupID(parentGroupID)
        var visited: Set<String> = [movingID]
        while let node = current {
            guard visited.insert(node).inserted else { return true }
            current = rawParentGroupID(of: node, folders: folders, projectAssignments: projectAssignments)
        }
        return false
    }

    /// Effective parent for either a virtual folder group id or a real project path. Dangling
    /// virtual targets and hand-edited cycles degrade to top level, so every node remains visible.
    static func effectiveParentID(
        ofGroupID groupID: String,
        folders: [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> String? {
        let normalizedID = normalizedGroupID(groupID)
        guard let parent = rawParentGroupID(
            of: normalizedID, folders: folders, projectAssignments: projectAssignments
        ) else { return nil }
        if let parentFolderID = virtualFolderID(fromGroupID: parent),
           !folders.contains(where: { $0.id == parentFolderID }) { return nil }
        guard !wouldCreateGroupCycle(
            moving: normalizedID, into: parent, folders: folders, projectAssignments: projectAssignments
        ) else { return nil }
        return parent
    }

    /// Ancestor virtual-folder ids, nearest first, crossing real project wrappers when needed.
    static func ancestorFolderIDs(
        of folderID: String,
        in folders: [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> [String] {
        var chain: [String] = []
        var visited: Set<String> = [groupID(forVirtualFolderID: folderID)]
        var current = groupID(forVirtualFolderID: folderID)
        while let parent = effectiveParentID(
            ofGroupID: current, folders: folders, projectAssignments: projectAssignments
        ) {
            guard visited.insert(parent).inserted else { break }
            if let parentFolderID = virtualFolderID(fromGroupID: parent) { chain.append(parentFolderID) }
            current = parent
        }
        return chain
    }

    static func wouldCreateCycle(
        moving folderID: String,
        into newParentFolderID: String,
        in folders: [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> Bool {
        wouldCreateGroupCycle(
            moving: groupID(forVirtualFolderID: folderID),
            into: groupID(forVirtualFolderID: newParentFolderID),
            folders: folders,
            projectAssignments: projectAssignments
        )
    }

    static func effectiveParentID(
        of folder: VirtualFolder,
        in folders: [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> String? {
        effectiveParentID(
            ofGroupID: groupID(forVirtualFolderID: folder.id),
            folders: folders,
            projectAssignments: projectAssignments
        )
    }

    /// `parentID` may be top level, a filesystem project path (always accepted \u2014 projects are
    /// derived from live sessions, never persisted as entities), or another folder's group id
    /// (must already exist).
    static func create(named name: String, parentID: String? = nil, in folders: inout [VirtualFolder]) -> VirtualFolder? {
        guard let clean = cleanedName(name) else { return nil }
        let parentID = parentID.map(normalizedGroupID)
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
    static func reparent(
        id: String,
        to newParentGroupID: String?,
        in folders: inout [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let parent = newParentGroupID.map(normalizedGroupID)
        if let parent {
            if let parentFolderID = virtualFolderID(fromGroupID: parent),
               !folders.contains(where: { $0.id == parentFolderID }) { return false }
            guard !wouldCreateGroupCycle(
                moving: groupID(forVirtualFolderID: id),
                into: parent,
                folders: folders,
                projectAssignments: projectAssignments
            ) else { return false }
        }
        folders[index].parentID = parent
        return true
    }

    /// Deleting a folder reparents its direct children up to the deleted folder's own parent
    /// (least destructive: a subtree stays together instead of scattering to top level) and
    /// clears only assignments that pointed at the deleted folder itself \u2014 sessions filed under
    /// a surviving child or grandchild keep their assignment untouched.
    @discardableResult
    static func delete(id: String, folders: inout [VirtualFolder], assignments: inout [String: String]) -> Bool {
        var projectAssignments: [String: String] = [:]
        return delete(
            id: id,
            folders: &folders,
            assignments: &assignments,
            projectAssignments: &projectAssignments
        )
    }

    static func delete(
        id: String,
        folders: inout [VirtualFolder],
        assignments: inout [String: String],
        projectAssignments: inout [String: String]
    ) -> Bool {
        guard let target = folders.first(where: { $0.id == id }) else { return false }
        let deletedGroupID = groupID(forVirtualFolderID: id)
        for index in folders.indices where folders[index].parentID == deletedGroupID {
            folders[index].parentID = target.parentID
        }
        if let parent = target.parentID, let parentFolderID = virtualFolderID(fromGroupID: parent) {
            let promotedProjects = projectAssignments.keys.filter { projectAssignments[$0] == id }
            for path in promotedProjects { projectAssignments[path] = parentFolderID }
        } else {
            projectAssignments = projectAssignments.filter { $0.value != id }
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

    @discardableResult
    static func moveProject(
        path: String,
        to folderID: String?,
        folders: [VirtualFolder],
        assignments: inout [String: String]
    ) -> Bool {
        let path = normalizedProjectPath(path)
        guard !isGlobalWorkingDirectory(URL(fileURLWithPath: path, isDirectory: true)) else { return false }
        guard let folderID else {
            assignments.removeValue(forKey: path)
            return true
        }
        guard folders.contains(where: { $0.id == folderID }),
              !wouldCreateGroupCycle(
                moving: path,
                into: groupID(forVirtualFolderID: folderID),
                folders: folders,
                projectAssignments: assignments
              ) else { return false }
        assignments[path] = folderID
        return true
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
        of parentGroupID: String?,
        in folders: [VirtualFolder],
        projectAssignments: [String: String] = [:],
        depth: Int = 0,
        maxDepth: Int = 48
    ) -> [FolderTreeEntry] {
        guard depth < maxDepth else { return [] }
        let direct = folders
            .filter { effectiveParentID(of: $0, in: folders, projectAssignments: projectAssignments) == parentGroupID }
            .sorted { $0.createdAt < $1.createdAt }
        return direct.flatMap { folder in
            [FolderTreeEntry(folder: folder, depth: depth)]
                + orderedChildren(
                    of: groupID(forVirtualFolderID: folder.id),
                    in: folders,
                    projectAssignments: projectAssignments,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
        }
    }

    /// Every folder exactly once: the top-level subtree first, then each filesystem project
    /// that hosts folders (first-seen order), so a flat picker can show the whole tree with
    /// simple per-depth indentation.
    static func allFolderEntries(
        _ folders: [VirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> [FolderTreeEntry] {
        var roots: [String?] = [nil]
        var seenProjectPaths: Set<String> = []
        for folder in folders {
            guard let parent = effectiveParentID(
                of: folder, in: folders, projectAssignments: projectAssignments
            ), virtualFolderID(fromGroupID: parent) == nil,
                  seenProjectPaths.insert(parent).inserted else { continue }
            roots.append(parent)
        }
        return roots.flatMap {
            orderedChildren(of: $0, in: folders, projectAssignments: projectAssignments)
        }
    }

    // MARK: - Categorization path

    /// App-created worktrees remain execution details: organization uses the project they were
    /// cut from while Pi continues to use the session's real cwd.
    static func projectPath(
        of session: SessionSummary,
        managedWorktreeProjects: [String: String] = [:]
    ) -> String {
        let cwd = session.cwd.standardizedFileURL.path
        guard let project = managedWorktreeProjects[cwd] else { return cwd }
        return URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL.path
    }

    /// Where a conversation actually sits in the sidebar, outermost ancestor first and the
    /// conversation itself last, so a breadcrumb can never disagree with the tree that
    /// `SidebarSnapshot` draws from the same folder and project assignment state. It walks the
    /// alternating project/virtual ancestry for either a directly filed session or its real
    /// project, then appends the conversation.
    ///
    /// Cycle- and dangling-safe: it walks with `effectiveParentID`, keeps a visited set, and stops
    /// at `maxDepth`, so hand-edited state yields a bounded, visible path instead of looping.
    static func categorization(
        of session: SessionSummary,
        folders: [VirtualFolder],
        assignments: [String: String],
        projectAssignments: [String: String] = [:],
        managedWorktreeProjects: [String: String] = [:],
        maxDepth: Int = 48
    ) -> [String] {
        let assigned = assignments[session.fileURL.standardizedFileURL.path]
        var current = assigned.flatMap { id in
            folders.contains(where: { $0.id == id }) ? groupID(forVirtualFolderID: id) : nil
        } ?? projectPath(of: session, managedWorktreeProjects: managedWorktreeProjects)
        var chain: [String] = []
        var visited: Set<String> = []
        while chain.count < maxDepth, visited.insert(current).inserted {
            chain.append(label(forGroupID: current, folders: folders))
            guard let parent = effectiveParentID(
                ofGroupID: current,
                folders: folders,
                projectAssignments: projectAssignments
            ) else { break }
            current = parent
        }
        return Array(chain.reversed()) + [session.displayName]
    }

    private static func label(forGroupID groupID: String, folders: [VirtualFolder]) -> String {
        if let folderID = virtualFolderID(fromGroupID: groupID),
           let folder = folders.first(where: { $0.id == folderID }) { return folder.name }
        return isGlobalWorkingDirectory(URL(fileURLWithPath: groupID, isDirectory: true))
            ? "Recents"
            : SessionFolderGroup.projectName(forPath: groupID)
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
        fallback: URL,
        managedWorktreeProjects: [String: String] = [:],
        projectAssignments: [String: String] = [:]
    ) -> URL {
        if let shared = mostCommonCwd(
            inVirtualFolder: folderID,
            sessions: sessions,
            assignments: assignments,
            managedWorktreeProjects: managedWorktreeProjects
        ) {
            return shared
        }
        if let project = enclosingProjectPath(
            ofVirtualFolder: folderID,
            folders: folders,
            projectAssignments: projectAssignments
        ) {
            return URL(fileURLWithPath: project, isDirectory: true)
        }
        return fallback
    }

    private static func mostCommonCwd(
        inVirtualFolder folderID: String,
        sessions: [SessionSummary],
        assignments: [String: String],
        managedWorktreeProjects: [String: String]
    ) -> URL? {
        let own = sessions.filter { assignments[$0.fileURL.standardizedFileURL.path] == folderID }
        guard !own.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for session in own {
            counts[projectPath(of: session, managedWorktreeProjects: managedWorktreeProjects), default: 0] += 1
        }
        let topCount = counts.values.max() ?? 0
        let tiedPaths = Set(counts.filter { $0.value == topCount }.map(\.key))
        let winner = own
            .filter { tiedPaths.contains(projectPath(of: $0, managedWorktreeProjects: managedWorktreeProjects)) }
            .max { $0.modifiedAt < $1.modifiedAt }
        return winner.map {
            URL(fileURLWithPath: projectPath(of: $0, managedWorktreeProjects: managedWorktreeProjects), isDirectory: true)
        }
    }

    /// Walks up through parent virtual folders — cycle-safe like `effectiveParentID`, which this
    /// reuses at every step — until it finds a filesystem project parent or runs out of ancestors.
    private static func enclosingProjectPath(
        ofVirtualFolder folderID: String,
        folders: [VirtualFolder],
        projectAssignments: [String: String]
    ) -> String? {
        var visited: Set<String> = [groupID(forVirtualFolderID: folderID)]
        var current = groupID(forVirtualFolderID: folderID)
        while let parent = effectiveParentID(
            ofGroupID: current,
            folders: folders,
            projectAssignments: projectAssignments
        ) {
            guard visited.insert(parent).inserted else { return nil }
            if virtualFolderID(fromGroupID: parent) == nil { return parent }
            current = parent
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
        updateState { state in
            changed = WorkspaceOrganization.reparent(
                id: id,
                to: parentID,
                in: &state.virtualFolders,
                projectAssignments: state.projectFolderAssignments
            )
        }
        return changed
    }

    func deleteVirtualFolder(id: String) -> Bool {
        var changed = false
        updateState { state in
            var folders = state.virtualFolders
            var assignments = state.virtualFolderAssignments
            var projectAssignments = state.projectFolderAssignments
            changed = WorkspaceOrganization.delete(
                id: id,
                folders: &folders,
                assignments: &assignments,
                projectAssignments: &projectAssignments
            )
            if changed {
                state.virtualFolders = folders
                state.virtualFolderAssignments = assignments
                state.projectFolderAssignments = projectAssignments
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

    func moveProject(path: String, toVirtualFolder folderID: String?) -> Bool {
        var changed = false
        updateState { state in
            var assignments = state.projectFolderAssignments
            changed = WorkspaceOrganization.moveProject(
                path: path,
                to: folderID,
                folders: state.virtualFolders,
                assignments: &assignments
            )
            if changed {
                let path = WorkspaceOrganization.normalizedProjectPath(path)
                state.setProjectFolderAssignment(projectPath: path, folderID: assignments[path])
            }
        }
        return changed
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
    var virtualFolders: [VirtualFolder] { persistence.state.virtualFolders }
    var virtualFolderAssignments: [String: String] { persistence.state.virtualFolderAssignments }
    var projectFolderAssignments: [String: String] { persistence.state.projectFolderAssignments }
    var managedWorktreeProjects: [String: String] { persistence.state.managedWorktreeProjects }

    func projectFolder(for session: SessionSummary) -> URL {
        URL(
            fileURLWithPath: WorkspaceOrganization.projectPath(
                of: session,
                managedWorktreeProjects: managedWorktreeProjects
            ),
            isDirectory: true
        )
    }

    func virtualFolderID(for session: SessionSummary) -> String? {
        let path = session.fileURL.standardizedFileURL.path
        let candidate = persistence.state.virtualFolderAssignments[path]
        return virtualFolders.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    /// Sidebar categorization path for a conversation; see `WorkspaceOrganization.categorization`.
    func categorization(of session: SessionSummary) -> [String] {
        WorkspaceOrganization.categorization(
            of: session,
            folders: virtualFolders,
            assignments: virtualFolderAssignments,
            projectAssignments: projectFolderAssignments,
            managedWorktreeProjects: managedWorktreeProjects
        )
    }

    func displayFolderName(for session: SessionSummary) -> String {
        guard let id = virtualFolderID(for: session), let folder = virtualFolders.first(where: { $0.id == id }) else {
            let project = projectFolder(for: session)
            return WorkspaceOrganization.isGlobalWorkingDirectory(project)
                ? "Global"
                : SessionFolderGroup.projectName(forPath: project.path)
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

    func moveProjectFolder(path: String, toVirtualFolder folderID: String?) {
        guard persistence.moveProject(path: path, toVirtualFolder: folderID) else { return }
        objectWillChange.send()
    }

    /// Working directory for a chat started via a virtual folder's `+`/"New Chat Here"; see
    /// `WorkspaceOrganization.defaultWorkingDirectory` for the exact preference order.
    /// `selectedFolder` stands in for the current default (its last tier). `openNewChat()` sets
    /// it to the global Desktop cwd before a folder-scoped action chooses anything else.
    func defaultWorkingDirectory(forVirtualFolder folderID: String) -> URL {
        WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: folderID,
            sessions: sessions,
            assignments: virtualFolderAssignments,
            folders: virtualFolders,
            fallback: selectedFolder ?? WorkspaceOrganization.globalWorkingDirectory,
            managedWorktreeProjects: managedWorktreeProjects,
            projectAssignments: projectFolderAssignments
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
