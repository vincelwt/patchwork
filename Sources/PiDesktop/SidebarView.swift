import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var archiveExpanded = false

    var body: some View {
        let snapshot = SidebarSnapshot(
            sessions: store.sessions,
            query: store.searchText,
            virtualFolders: store.virtualFolders,
            assignments: store.virtualFolderAssignments
        )
        VStack(spacing: 0) {
            SidebarActionRow(title: "New chat", symbol: "square.and.pencil", shortcut: "⌘N", action: store.openNewChat)
            SidebarActionRow(
                title: "New folder", symbol: "folder.badge.plus", shortcut: "",
                action: { store.newVirtualFolderRequested = true }
            )
            SidebarActionRow(
                title: "Automations", symbol: "clock.arrow.2.circlepath", shortcut: "⌥⌘S",
                action: { store.schedulesPresented = true },
                selected: store.schedulesPresented
            )
            .padding(.bottom, PiTheme.space6)

            if store.isScanning, snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                VStack(spacing: PiTheme.space8) {
                    ProgressView().controlSize(.small)
                    Text("Finding Pi sessions…").font(SidebarTypography.status).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.scanError, snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                ContentUnavailableView("Sessions unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                ContentUnavailableView(
                    store.searchText.isEmpty ? "No conversations yet" : "No matches",
                    systemImage: store.searchText.isEmpty ? "bubble.left" : "magnifyingglass"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                        ForEach(snapshot.activeGroups) { group in
                            SessionFolderSection(group: group, forceExpanded: snapshot.isFiltering)
                        }
                    }
                    .padding(.horizontal, PiTheme.space6)
                    .padding(.bottom, PiTheme.space12)
                }
                .scrollIndicators(.automatic)

                // Pinned below the scroller instead of living inside it, so Archived always
                // sits in the same quiet spot above the footer instead of floating mid-list.
                if !snapshot.archivedGroups.isEmpty {
                    PiHairline()
                    ArchiveSection(groups: snapshot.archivedGroups, expanded: $archiveExpanded,
                                   forceExpanded: snapshot.isFiltering)
                        .padding(.horizontal, PiTheme.space6)
                }
            }

            PiHairline()
            SidebarFooter()
        }
        // Search now lives only in the ⌘K quick switcher; `store.searchText` (and the
        // filtering it drives below) stays wired for when a query is ever supplied again.
    }
}

private struct SidebarActionRow: View {
    let title: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
    var selected = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: PiTheme.space6) {
                // Sits in the shared icon column, so the title starts on the sidebar text origin.
                Image(systemName: symbol)
                    .font(.system(size: PiIcon.small, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: PiTheme.sidebarIconColumn, alignment: .center)
                Text(title).font(SidebarTypography.conversationTitle(selected: selected))
                Spacer(minLength: PiTheme.space4)
                if !shortcut.isEmpty {
                    Text(shortcut).font(SidebarTypography.metadata).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, PiTheme.sidebarIconInset)
            .padding(.trailing, PiTheme.space8)
            .frame(height: PiTheme.sidebarRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: selected, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, PiTheme.space6)
        .help(shortcut.isEmpty ? title : "\(title) (\(shortcut))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var store: AppStore
    private var runningCount: Int { store.runningSessions.count }

    var body: some View {
        HStack(spacing: PiTheme.space6) {
            StatusDot(color: runningCount > 0 ? .piGreen : .secondary, isPulsing: runningCount > 0)
            if let label {
                Text(label).font(SidebarTypography.status).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Session activity")
                    .accessibilityValue(label)
            }
            Spacer(minLength: PiTheme.space4)
            Button { Task { await store.refreshSessions() } } label: {
                Group {
                    if store.isScanning { ProgressView().controlSize(.mini) }
                    else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: PiIcon.small, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                // A 22pt square target, so the glyph size does not decide the hit area.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh sessions")
        }
        .padding(.leading, PiTheme.space12)
        .padding(.trailing, PiTheme.space6)
        .frame(height: PiTheme.statusBarHeight)
    }

    /// `nil` when idle: there is deliberately no "ready"/"idle" copy, only real activity.
    private var label: String? {
        if runningCount == 1 { return "1 session running" }
        if runningCount > 1 { return "\(runningCount) sessions running" }
        return nil
    }
}

// MARK: - Grouping

struct SidebarSnapshot {
    let all: [SessionSummary]
    let activeGroups: [SessionFolderGroup]
    let archivedGroups: [SessionFolderGroup]
    let isFiltering: Bool

    init(
        sessions: [SessionSummary],
        query: String,
        virtualFolders: [VirtualFolder] = [],
        assignments: [String: String] = [:]
    ) {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isFiltering = !folded.isEmpty
        let validVirtualIDs = Set(virtualFolders.map(\.id))
        all = folded.isEmpty ? sessions : sessions.filter { session in
            if session.searchKey.contains(folded) { return true }
            let path = session.fileURL.standardizedFileURL.path
            guard let id = assignments[path],
                  let folder = virtualFolders.first(where: { $0.id == id }) else { return false }
            return folder.name.lowercased().contains(folded)
        }
        activeGroups = Self.groups(
            all.filter { !$0.isArchived },
            virtualFolders: virtualFolders,
            assignments: assignments,
            validVirtualIDs: validVirtualIDs,
            includeEmptyVirtualFolders: !isFiltering
        )
        archivedGroups = Self.groups(
            all.filter(\.isArchived),
            virtualFolders: virtualFolders,
            assignments: assignments,
            validVirtualIDs: validVirtualIDs,
            includeEmptyVirtualFolders: false
        )
    }

    /// Builds the folder forest: filesystem project roots plus top-level virtual folders, each
    /// carrying its own nested virtual folders (any depth) alongside its directly assigned
    /// sessions. A folder's own `.sessions` never include a descendant's, so every session in
    /// `sessions` still appears exactly once across the whole tree.
    private static func groups(
        _ sessions: [SessionSummary],
        virtualFolders: [VirtualFolder],
        assignments: [String: String],
        validVirtualIDs: Set<String>,
        includeEmptyVirtualFolders: Bool
    ) -> [SessionFolderGroup] {
        var virtualSessions: [String: [SessionSummary]] = [:]
        var filesystemSessions: [String: [SessionSummary]] = [:]
        for session in sessions {
            let sessionPath = session.fileURL.standardizedFileURL.path
            if let id = assignments[sessionPath], validVirtualIDs.contains(id) {
                virtualSessions[id, default: []].append(session)
            } else {
                filesystemSessions[session.cwd.standardizedFileURL.path, default: []].append(session)
            }
        }

        // Every folder is bucketed under its cycle/dangling-safe effective parent (see
        // `WorkspaceOrganization.effectiveParentID`), keyed exactly like `SessionFolderGroup.id`
        // ("" stands for top level here, since that can never collide with a real path or a
        // "virtual:" id) \u2014 this is what lets a project or another folder host children at any depth.
        var childrenByParent: [String: [VirtualFolder]] = [:]
        for folder in virtualFolders {
            let key = WorkspaceOrganization.effectiveParentID(of: folder, in: virtualFolders) ?? ""
            childrenByParent[key, default: []].append(folder)
        }

        func keep(_ group: SessionFolderGroup) -> Bool {
            includeEmptyVirtualFolders || !group.sessions.isEmpty || !group.children.isEmpty
        }

        // `depth` only guards this recursion against a pathologically deep (but already acyclic,
        // hence never truly infinite) parent chain; real folder trees are nowhere near this deep.
        func build(_ folder: VirtualFolder, depth: Int) -> SessionFolderGroup {
            let own = (virtualSessions[folder.id] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
            let nested = depth >= PiTheme.sidebarMaxFolderDepth ? [] : childrenByParent[WorkspaceOrganization.groupID(forVirtualFolderID: folder.id)] ?? []
            let children = nested.map { build($0, depth: depth + 1) }.filter(keep).sorted(by: groupSort)
            return SessionFolderGroup(virtualFolder: folder, sessions: own, children: children)
        }

        let topVirtual = (childrenByParent[""] ?? []).map { build($0, depth: 0) }.filter(keep)

        let projectPaths = Set(filesystemSessions.keys)
            .union(childrenByParent.keys.filter { !$0.isEmpty && !$0.hasPrefix("virtual:") })
        let projectGroups = projectPaths.map { path -> SessionFolderGroup in
            let own = (filesystemSessions[path] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
            let children = (childrenByParent[path] ?? []).map { build($0, depth: 0) }.filter(keep).sorted(by: groupSort)
            return SessionFolderGroup(path: path, sessions: own, children: children)
        }.filter { !$0.sessions.isEmpty || !$0.children.isEmpty }

        return (topVirtual + projectGroups).sorted(by: groupSort)
    }

    private static func groupSort(_ lhs: SessionFolderGroup, _ rhs: SessionFolderGroup) -> Bool {
        let left = lhs.sessions.first?.modifiedAt ?? lhs.createdAt ?? .distantPast
        let right = rhs.sessions.first?.modifiedAt ?? rhs.createdAt ?? .distantPast
        if left == right { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
        return left > right
    }
}

struct SessionFolderGroup: Identifiable {
    let id: String
    let path: String
    let sessions: [SessionSummary]
    let virtualFolderID: String?
    let virtualName: String?
    let createdAt: Date?
    /// Nested virtual folders (any depth) that live inside this group. Filesystem groups can
    /// have children; virtual folders can have both children and, recursively, grandchildren.
    let children: [SessionFolderGroup]

    init(path: String, sessions: [SessionSummary], children: [SessionFolderGroup] = []) {
        id = path
        self.path = path
        self.sessions = sessions
        virtualFolderID = nil
        virtualName = nil
        createdAt = nil
        self.children = children
    }

    init(virtualFolder: VirtualFolder, sessions: [SessionSummary], children: [SessionFolderGroup] = []) {
        id = "virtual:\(virtualFolder.id)"
        path = id
        self.sessions = sessions
        virtualFolderID = virtualFolder.id
        virtualName = virtualFolder.name
        createdAt = virtualFolder.createdAt
        self.children = children
    }

    var isVirtual: Bool { virtualFolderID != nil }

    /// Retained as a pure recency query for callers/tests; visibility no longer depends on it.
    static let recencyWindow: TimeInterval = 14 * 24 * 60 * 60
    func isRecent(now: Date = Date()) -> Bool {
        guard let newest = sessions.first?.modifiedAt else { return false }
        return now.timeIntervalSince(newest) <= Self.recencyWindow
    }

    static func projectName(forPath path: String) -> String {
        let value = URL(fileURLWithPath: path).lastPathComponent
        return value.isEmpty ? path : value
    }

    var name: String {
        if let virtualName { return virtualName }
        return Self.projectName(forPath: path)
    }
}

/// Caps the pinned, expanded archive so a long archive grows in place instead of crowding out
/// the active list above it or pushing the footer out of the sidebar.
private let archiveExpandedMaxHeight: CGFloat = 220

private struct ArchiveSection: View {
    let groups: [SessionFolderGroup]
    @Binding var expanded: Bool
    let forceExpanded: Bool
    @State private var hovering = false
    private var isOpen: Bool { expanded || forceExpanded }
    private var totalCount: Int { groups.reduce(0) { $0 + $1.sessions.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PiTheme.space6) {
                    Image(systemName: "archivebox")
                        .font(.system(size: PiIcon.small)).foregroundStyle(.tertiary)
                        .frame(width: PiTheme.sidebarIconColumn, alignment: .center)
                    Text("Archived").font(SidebarTypography.folderHeader).foregroundStyle(.secondary)
                    Spacer(minLength: PiTheme.space4)
                }
                .padding(.horizontal, PiTheme.space8)
                .frame(height: PiTheme.folderHeaderHeight)
                .contentShape(Rectangle())
                .piRowBackground(selected: false, hovering: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            // The count no longer has an on-screen home, but VoiceOver still gets it.
            .accessibilityLabel("Archived, \(totalCount) conversations")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")

            if isOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: PiTheme.space2) {
                        ForEach(groups) { group in
                            SessionFolderSection(group: group, archived: true, forceExpanded: forceExpanded)
                        }
                    }
                }
                .frame(maxHeight: archiveExpandedMaxHeight)
            }
        }
        .padding(.top, PiTheme.space8)
    }
}

private struct SessionFolderSection: View {
    @EnvironmentObject private var store: AppStore
    let group: SessionFolderGroup
    var archived = false
    var forceExpanded = false
    var depth = 0
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameValue = ""
    @State private var confirmingDelete = false
    @State private var creatingChild = false
    @State private var childName = ""

    private var hasRunning: Bool { group.sessions.contains { store.isRunning($0) } }
    /// All active project folders open by default. Explicit user collapse still wins.
    private var defaultExpanded: Bool { true }
    private var isOpen: Bool { forceExpanded || store.isFolderExpanded(path: group.id, defaultExpanded: defaultExpanded) }
    private var indent: CGFloat { CGFloat(min(depth, PiTheme.sidebarMaxFolderDepth)) * PiTheme.sidebarIndentStep }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space2) {
            Button {
                if !group.isVirtual { store.chooseFolder(URL(fileURLWithPath: group.path, isDirectory: true)) }
                store.setFolderExpanded(!isOpen, path: group.id)
            } label: {
                HStack(spacing: PiTheme.space6) {
                    // No chevron column: the icon itself carries open/closed state, and the
                    // whole row (not a disclosure glyph) is the click target.
                    Image(systemName: isOpen ? "folder.fill" : "folder")
                        .font(.system(size: PiIcon.small)).foregroundStyle(.tertiary)
                        .frame(width: PiTheme.sidebarIconColumn, alignment: .center)
                    Text(group.name)
                        .font(SidebarTypography.folderHeader).foregroundStyle(.secondary).lineLimit(1)
                    if hasRunning { StatusDot(color: .piGreen, isPulsing: true) }
                    Spacer(minLength: PiTheme.space4)
                    newChatButton
                }
                .padding(.leading, PiTheme.space8 + indent)
                .padding(.trailing, PiTheme.space8)
                .frame(height: PiTheme.folderHeaderHeight)
                .contentShape(Rectangle())
                .piRowBackground(selected: false, hovering: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(group.isVirtual ? "Virtual folder" : group.path)
            .accessibilityLabel("\(group.name) folder, \(group.sessions.count) conversations")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            .contextMenu {
                if let id = group.virtualFolderID {
                    Button("New Folder Inside…") { childName = ""; creatingChild = true }
                    Button("New Chat Here") { newChatHere() }
                    Button("Rename Folder…") { renameValue = group.name; renaming = true }
                    Menu("Move Folder to…") {
                        Button("Top level") { store.reparentVirtualFolder(id: id, to: nil) }
                        if !projectDestinations.isEmpty { Divider() }
                        ForEach(projectDestinations, id: \.self) { path in
                            Button(SessionFolderGroup.projectName(forPath: path)) {
                                store.reparentVirtualFolder(id: id, to: path)
                            }
                        }
                        let folderDestinations = availableFolderDestinations(excluding: id)
                        if !folderDestinations.isEmpty { Divider() }
                        ForEach(folderDestinations) { entry in
                            Button(String(repeating: "  ", count: entry.depth) + entry.folder.name) {
                                store.reparentVirtualFolder(id: id, to: WorkspaceOrganization.groupID(forVirtualFolderID: entry.folder.id))
                            }
                        }
                    }
                    Button("Delete Folder…", role: .destructive) { confirmingDelete = true }
                } else {
                    Button("New Folder Inside…") { childName = ""; creatingChild = true }
                    Button("New Chat Here") { newChatHere() }
                }
            }
            .dropDestination(for: String.self) { paths, _ in
                for path in paths {
                    guard let session = store.sessions.first(where: { $0.fileURL.standardizedFileURL.path == path }) else { continue }
                    store.moveSession(session, toVirtualFolder: group.virtualFolderID)
                }
                return !paths.isEmpty
            }

            if isOpen {
                ForEach(group.children) { child in
                    SessionFolderSection(group: child, archived: archived, forceExpanded: forceExpanded, depth: depth + 1)
                }
                ForEach(group.sessions) { SessionRow(session: $0, archived: archived, depth: depth + 1) }
            }
        }
        .padding(.top, PiTheme.space6)
        .alert("Rename virtual folder", isPresented: $renaming) {
            TextField("Folder name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = group.virtualFolderID { store.renameVirtualFolder(id: id, to: renameValue) }
            }
        }
        .alert("New folder", isPresented: $creatingChild) {
            TextField("Folder name", text: $childName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { store.createVirtualFolder(named: childName, parentID: group.id) }
        }
        .confirmationDialog("Delete “\(group.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Folder", role: .destructive) {
                if let id = group.virtualFolderID { store.deleteVirtualFolder(id: id) }
            }
        } message: {
            Text("Subfolders move up a level and conversations return to their project or Desktop group. Session files are not changed.")
        }
    }

    /// Reserves the same fixed slot whether or not it is showing, so hovering a folder never
    /// shifts its header — mirrors `SessionRow.leadingIcon`'s hover-swap, which does the same for
    /// the archive button.
    @ViewBuilder
    private var newChatButton: some View {
        if hovering {
            Image(systemName: "plus")
                .font(.system(size: PiIcon.small, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PiTheme.sidebarIconColumn, height: PiTheme.folderHeaderHeight, alignment: .center)
                .contentShape(Rectangle())
                // Higher priority than the header's own Button, so this click starts a chat
                // here instead of also toggling the folder open/closed.
                .highPriorityGesture(TapGesture().onEnded { newChatHere() })
                .help("New chat in \(group.name)")
                .accessibilityLabel("New chat in \(group.name)")
                .accessibilityAddTraits(.isButton)
        } else {
            Color.clear
                .frame(width: PiTheme.sidebarIconColumn, height: PiTheme.folderHeaderHeight)
                .accessibilityHidden(true)
        }
    }

    /// A project group's "folder" is just its cwd, so the new chat can use it immediately. A
    /// virtual folder has no cwd of its own; see `WorkspaceOrganization.defaultWorkingDirectory`
    /// for the rule that picks one, and `NewChatFolderIntent` for how the assignment survives
    /// until Pi actually creates the session.
    private func newChatHere() {
        store.openNewChat()
        if let id = group.virtualFolderID {
            let cwd = store.defaultWorkingDirectory(forVirtualFolder: id)
            store.chooseFolder(cwd)
            NewChatFolderIntent.shared.arm(folderID: id, cwd: cwd, store: store)
        } else {
            store.chooseFolder(URL(fileURLWithPath: group.path, isDirectory: true))
        }
    }

    /// Known project paths, from live sessions, as candidate "Move Folder to…" destinations.
    private var projectDestinations: [String] {
        Set(store.sessions.map { $0.cwd.standardizedFileURL.path }).sorted {
            SessionFolderGroup.projectName(forPath: $0).localizedCaseInsensitiveCompare(SessionFolderGroup.projectName(forPath: $1)) == .orderedAscending
        }
    }

    /// The whole folder tree minus `id` and its own descendants, so the menu never offers a
    /// move that `reparent` would refuse as a cycle.
    private func availableFolderDestinations(excluding id: String) -> [WorkspaceOrganization.FolderTreeEntry] {
        WorkspaceOrganization.allFolderEntries(store.virtualFolders)
            .filter { $0.folder.id != id && !WorkspaceOrganization.wouldCreateCycle(moving: id, into: $0.folder.id, in: store.virtualFolders) }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionSummary
    let archived: Bool
    var depth = 0
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameValue = ""

    private var selected: Bool {
        guard !store.schedulesPresented else { return false }
        if case let .session(id) = store.route { return id == session.id }
        return false
    }
    private var running: Bool { store.isRunning(session) }
    private var unread: Bool { store.isUnread(session) }
    private var git: GitSnapshot { store.folderGit[session.cwd.standardizedFileURL.path] ?? .none }
    private var indent: CGFloat { CGFloat(min(depth, PiTheme.sidebarMaxFolderDepth)) * PiTheme.sidebarIndentStep }

    var body: some View {
        Button { store.selectSession(session) } label: {
            HStack(spacing: PiTheme.space6) {
                leadingIcon
                Text(session.displayName)
                    .font(SidebarTypography.conversationTitle(selected: selected))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: PiTheme.space4)
                trailingAccessory
            }
            .padding(.leading, PiTheme.sidebarIconInset + indent)
            .padding(.trailing, PiTheme.space8)
            .frame(height: PiTheme.sidebarRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: selected, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .draggable(session.fileURL.standardizedFileURL.path)
        .contextMenu {
            Button("Rename…") { renameValue = session.displayName; renaming = true }
            Menu("Move to…") {
                Button("Project / Desktop") { store.moveSession(session, toVirtualFolder: nil) }
                let entries = WorkspaceOrganization.allFolderEntries(store.virtualFolders)
                if !entries.isEmpty { Divider() }
                ForEach(entries) { entry in
                    Button(String(repeating: "  ", count: entry.depth) + entry.folder.name) {
                        store.moveSession(session, toVirtualFolder: entry.folder.id)
                    }
                }
            }
            Button("Mark as unread") { store.markUnread(session) }
            Button(archived ? "Restore" : "Archive") { store.toggleArchive(session) }
            Divider()
            Button("Reveal Session File") { NSWorkspace.shared.activateFileViewerSelecting([session.fileURL]) }
        }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Conversation name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameSession(session, to: renameValue) }
        }
        .help(session.cwd.path)
        .accessibilityLabel("\(session.displayName), \(store.liveModifiedAt(session).relativeShort)\(running ? ", running" : "")\(unread ? ", unread" : "")")
    }

    /// The unread dot and the hover archive/restore button share this one column, so a thread
    /// title never shifts sideways when the row is hovered or read.
    @ViewBuilder
    private var leadingIcon: some View {
        if hovering {
            Image(systemName: archived ? "tray.and.arrow.up" : "archivebox")
                .font(.system(size: PiIcon.small, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PiTheme.sidebarIconColumn, height: PiTheme.sidebarRowHeight, alignment: .center)
                .contentShape(Rectangle())
                // Higher priority than the row's own Button gesture, so this click archives
                // instead of also selecting/opening the conversation underneath it.
                .highPriorityGesture(TapGesture().onEnded { store.toggleArchive(session) })
                .help(archived ? "Restore" : "Archive")
                .accessibilityLabel(archived ? "Restore conversation" : "Archive conversation")
                .accessibilityAddTraits(.isButton)
        } else {
            Circle()
                .fill(unread ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
                .frame(width: PiTheme.sidebarIconColumn, alignment: .center)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if running {
            ProgressView().controlSize(.mini).help("Pi is working")
        } else if hovering {
            Text(store.liveModifiedAt(session).relativeShort).font(SidebarTypography.metadata).foregroundStyle(.tertiary)
        } else if GitIndicatorPolicy.showsBranchIndicator(git) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: PiIcon.micro)).foregroundStyle(.tertiary)
                .help([git.branch, git.statusHint].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// A branch indicator only earns its place on a dirty checkout that has actually drifted from
/// the trunk; `main`/`master` are where the user expects to be, so they render nothing.
enum GitIndicatorPolicy {
    static let defaultBranchNames: Set<String> = ["main", "master"]

    static func showsBranchIndicator(_ snapshot: GitSnapshot) -> Bool {
        guard snapshot.isRepository, snapshot.isDirty else { return false }
        // Detached HEAD has no branch name but is never "on trunk" either, so it still qualifies.
        if snapshot.isDetached { return true }
        guard let branch = snapshot.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return false
        }
        return !defaultBranchNames.contains(branch.lowercased())
    }
}
