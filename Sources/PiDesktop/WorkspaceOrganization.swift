import Foundation

/// An app-owned organizational folder. It never maps to, creates, or mutates a filesystem
/// directory; assignments are Pi Desktop metadata keyed by the session file's stable path.
struct VirtualFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date

    init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Pure CRUD/move rules shared by persistence and tests.
enum WorkspaceOrganization {
    static func cleanedName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(80))
    }

    static func create(named name: String, in folders: inout [VirtualFolder]) -> VirtualFolder? {
        guard let clean = cleanedName(name) else { return nil }
        let folder = VirtualFolder(name: clean)
        folders.append(folder)
        return folder
    }

    @discardableResult
    static func rename(id: String, to name: String, in folders: inout [VirtualFolder]) -> Bool {
        guard let clean = cleanedName(name), let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        folders[index].name = clean
        return true
    }

    @discardableResult
    static func delete(id: String, folders: inout [VirtualFolder], assignments: inout [String: String]) -> Bool {
        guard folders.contains(where: { $0.id == id }) else { return false }
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
}

extension AppPersistence {
    @discardableResult
    func createVirtualFolder(named name: String) -> VirtualFolder? {
        var result: VirtualFolder?
        updateState { result = WorkspaceOrganization.create(named: name, in: &$0.virtualFolders) }
        return result
    }

    func renameVirtualFolder(id: String, to name: String) -> Bool {
        var changed = false
        updateState { changed = WorkspaceOrganization.rename(id: id, to: name, in: &$0.virtualFolders) }
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

    func markSessionRead(path: String, at date: Date) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        updateState {
            $0.lastReadAt[key] = date
            $0.manuallyUnreadSessionPaths.remove(key)
        }
    }

    func markSessionUnread(path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        updateState { $0.manuallyUnreadSessionPaths.insert(key) }
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
    func createVirtualFolder(named name: String) -> VirtualFolder? {
        guard let folder = persistence.createVirtualFolder(named: name) else { return nil }
        objectWillChange.send()
        return folder
    }

    func renameVirtualFolder(id: String, to name: String) {
        guard persistence.renameVirtualFolder(id: id, to: name) else { return }
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

    func markRead(_ session: SessionSummary) {
        persistence.markSessionRead(path: session.fileURL.path, at: liveModifiedAt(session))
        objectWillChange.send()
    }

    func markUnread(_ session: SessionSummary) {
        persistence.markSessionUnread(path: session.fileURL.path)
        objectWillChange.send()
    }

    func isUnread(_ session: SessionSummary) -> Bool {
        let path = session.fileURL.standardizedFileURL.path
        if persistence.state.manuallyUnreadSessionPaths.contains(path) { return true }
        if selectedSession?.id == session.id { return false }
        guard let viewed = persistence.state.lastReadAt[path] else { return true }
        return liveModifiedAt(session) > viewed
    }

    /// Free global shortcut: Option-Command-U marks the selected conversation unread.
    func markSelectedUnread() {
        guard let selectedSession else { return }
        markUnread(selectedSession)
    }
}
