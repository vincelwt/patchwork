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
                title: "Quick switch", symbol: "magnifyingglass", shortcut: "⌘K",
                action: { store.quickSwitchPresented = true }
            )
            SidebarActionRow(
                title: "New folder", symbol: "folder.badge.plus", shortcut: "",
                action: { store.newVirtualFolderRequested = true }
            )
            .padding(.bottom, PiTheme.space6)

            if store.isScanning, snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                VStack(spacing: PiTheme.space8) {
                    ProgressView().controlSize(.small)
                    Text("Finding Pi sessions…").font(PiFont.caption).foregroundStyle(.secondary)
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
                        if !snapshot.archivedGroups.isEmpty {
                            ArchiveSection(groups: snapshot.archivedGroups, expanded: $archiveExpanded,
                                           forceExpanded: snapshot.isFiltering)
                        }
                    }
                    .padding(.horizontal, PiTheme.space6)
                    .padding(.bottom, PiTheme.space12)
                }
                .scrollIndicators(.automatic)
            }

            PiHairline()
            SidebarFooter()
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search chats")
    }
}

private struct SidebarActionRow: View {
    let title: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: PiTheme.space8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: PiTheme.gridIconColumn, alignment: .center)
                Text(title).font(PiFont.row)
                Spacer()
                if !shortcut.isEmpty {
                    Text(shortcut).font(PiFont.micro).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: PiTheme.sidebarRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, PiTheme.space6)
        .help(shortcut.isEmpty ? title : "\(title) (\(shortcut))")
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var store: AppStore
    private var runningCount: Int { store.runningSessions.count }

    var body: some View {
        HStack(spacing: PiTheme.space6) {
            StatusDot(
                color: runningCount > 0 ? .piGreen : (store.runtimeState.isConnected ? .piGreen : .secondary),
                isPulsing: runningCount > 0
            )
            Text(label).font(PiFont.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: PiTheme.space4)
            Button { Task { await store.refreshSessions() } } label: {
                if store.isScanning { ProgressView().controlSize(.mini) }
                else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 18, height: 18)
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, PiTheme.space12)
        .frame(height: PiTheme.statusBarHeight)
    }

    private var label: String {
        if runningCount == 1 { return "1 session running" }
        if runningCount > 1 { return "\(runningCount) sessions running" }
        return store.runtimeState.isConnected ? "Pi ready" : "Ready on demand"
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

        var result = virtualFolders.compactMap { folder -> SessionFolderGroup? in
            let values = virtualSessions[folder.id] ?? []
            guard includeEmptyVirtualFolders || !values.isEmpty else { return nil }
            return SessionFolderGroup(virtualFolder: folder, sessions: values.sorted { $0.modifiedAt > $1.modifiedAt })
        }
        result += filesystemSessions.map {
            SessionFolderGroup(path: $0.key, sessions: $0.value.sorted { $0.modifiedAt > $1.modifiedAt })
        }
        return result.sorted { lhs, rhs in
            let left = lhs.sessions.first?.modifiedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.sessions.first?.modifiedAt ?? rhs.createdAt ?? .distantPast
            if left == right { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return left > right
        }
    }
}

struct SessionFolderGroup: Identifiable {
    let id: String
    let path: String
    let sessions: [SessionSummary]
    let virtualFolderID: String?
    let virtualName: String?
    let createdAt: Date?

    init(path: String, sessions: [SessionSummary]) {
        id = path
        self.path = path
        self.sessions = sessions
        virtualFolderID = nil
        virtualName = nil
        createdAt = nil
    }

    init(virtualFolder: VirtualFolder, sessions: [SessionSummary]) {
        id = "virtual:\(virtualFolder.id)"
        path = id
        self.sessions = sessions
        virtualFolderID = virtualFolder.id
        virtualName = virtualFolder.name
        createdAt = virtualFolder.createdAt
    }

    var isVirtual: Bool { virtualFolderID != nil }

    /// Retained as a pure recency query for callers/tests; visibility no longer depends on it.
    static let recencyWindow: TimeInterval = 14 * 24 * 60 * 60
    func isRecent(now: Date = Date()) -> Bool {
        guard let newest = sessions.first?.modifiedAt else { return false }
        return now.timeIntervalSince(newest) <= Self.recencyWindow
    }

    var name: String {
        if let virtualName { return virtualName }
        let value = URL(fileURLWithPath: path).lastPathComponent
        return value.isEmpty ? path : value
    }
}

private struct ArchiveSection: View {
    let groups: [SessionFolderGroup]
    @Binding var expanded: Bool
    let forceExpanded: Bool
    @State private var hovering = false
    private var isOpen: Bool { expanded || forceExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PiTheme.space6) {
                    PiChevron(expanded: isOpen)
                    Image(systemName: "archivebox").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text("Archived").font(PiFont.captionEmphasis).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(groups.reduce(0) { $0 + $1.sessions.count })")
                        .font(PiFont.micro.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, PiTheme.space8)
                .frame(height: PiTheme.folderHeaderHeight)
                .contentShape(Rectangle())
                .piRowBackground(selected: false, hovering: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isOpen {
                ForEach(groups) { group in
                    SessionFolderSection(group: group, archived: true, forceExpanded: forceExpanded)
                }
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
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameValue = ""
    @State private var confirmingDelete = false

    private var hasRunning: Bool { group.sessions.contains { store.isRunning($0) } }
    /// All active project folders open by default. Explicit user collapse still wins.
    private var defaultExpanded: Bool { true }
    private var isOpen: Bool { forceExpanded || store.isFolderExpanded(path: group.id, defaultExpanded: defaultExpanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space2) {
            Button {
                if !group.isVirtual { store.chooseFolder(URL(fileURLWithPath: group.path, isDirectory: true)) }
                store.setFolderExpanded(!isOpen, path: group.id)
            } label: {
                HStack(spacing: PiTheme.space6) {
                    PiChevron(expanded: isOpen)
                    Image(systemName: group.isVirtual ? "folder.fill" : "folder")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(group.name)
                        .font(PiFont.captionEmphasis).foregroundStyle(.secondary).lineLimit(1)
                    if hasRunning { StatusDot(color: .piGreen, isPulsing: true) }
                    Spacer(minLength: PiTheme.space4)
                    Text("\(group.sessions.count)")
                        .font(PiFont.micro.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, PiTheme.space8)
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
                if group.virtualFolderID != nil {
                    Button("Rename Folder…") { renameValue = group.name; renaming = true }
                    Button("Delete Folder…", role: .destructive) { confirmingDelete = true }
                } else {
                    Button("New Chat Here") {
                        store.openNewChat()
                        store.chooseFolder(URL(fileURLWithPath: group.path, isDirectory: true))
                    }
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
                ForEach(group.sessions) { SessionRow(session: $0, archived: archived) }
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
        .confirmationDialog("Delete “\(group.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Folder", role: .destructive) {
                if let id = group.virtualFolderID { store.deleteVirtualFolder(id: id) }
            }
        } message: {
            Text("Conversations return to their project or Desktop group. Session files are not changed.")
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionSummary
    let archived: Bool
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameValue = ""

    private var selected: Bool {
        if case let .session(id) = store.route { return id == session.id }
        return false
    }
    private var running: Bool { store.isRunning(session) }
    private var unread: Bool { store.isUnread(session) }
    private var git: GitSnapshot { store.folderGit[session.cwd.standardizedFileURL.path] ?? .none }

    var body: some View {
        Button { store.selectSession(session) } label: {
            HStack(spacing: PiTheme.space6) {
                if unread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(session.displayName)
                    .font(selected ? PiFont.rowEmphasis : PiFont.row)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: PiTheme.space4)
                trailingAccessory
            }
            .padding(.leading, PiTheme.space8 + PiTheme.space12)
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
                if !store.virtualFolders.isEmpty { Divider() }
                ForEach(store.virtualFolders) { folder in
                    Button(folder.name) { store.moveSession(session, toVirtualFolder: folder.id) }
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

    @ViewBuilder
    private var trailingAccessory: some View {
        if running {
            ProgressView().controlSize(.mini).help("Pi is working")
        } else if hovering {
            Text(store.liveModifiedAt(session).relativeShort).font(PiFont.micro).foregroundStyle(.tertiary)
        } else if git.isRepository, git.isDirty {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .help([git.branch, git.statusHint].compactMap { $0 }.joined(separator: " · "))
        }
    }
}
