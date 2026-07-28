import AppKit
import SwiftUI

/// Which shape the sidebar lists conversations in. Deliberately local view state: it is a way of
/// looking at the same sessions, not a setting worth persisting.
enum SidebarMode: String {
    case tree = "Tree"
    case status = "Status"
}

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var archiveExpanded = false
    @State private var mode: SidebarMode = .tree

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
                title: "Automations", symbol: "clock.arrow.2.circlepath", shortcut: "⌥⌘S",
                action: { store.schedulesPresented = true },
                selected: store.schedulesPresented
            )
            .padding(.bottom, PiTheme.space6)

            Picker("View", selection: $mode) {
                Label("Tree", systemImage: "tree").tag(SidebarMode.tree)
                Label("Status", systemImage: "circle.fill").tag(SidebarMode.status)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PiTheme.space6)
            .padding(.bottom, PiTheme.space6)
            .help("Tree groups by project and folder; Status groups every project's conversations by what they need")

            if store.isScanning, snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                VStack(spacing: PiTheme.space8) {
                    ProgressView().controlSize(.small)
                    Text("Finding Pi sessions…").font(SidebarTypography.status).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.scanError, snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                PiUnavailableView(
                    "Sessions unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: error
                )
            } else if snapshot.activeGroups.isEmpty, snapshot.archivedGroups.isEmpty {
                PiUnavailableView(
                    store.searchText.isEmpty ? "No conversations yet" : "No matches",
                    systemImage: store.searchText.isEmpty ? "bubble.left" : "magnifyingglass"
                )
            } else {
                if mode == .status {
                    // Archived stay out of the sections here; they keep the pinned area below.
                    StatusListView(sessions: snapshot.all)
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
                }

                // Pinned below the scroller instead of living inside it, so Archived always
                // sits in the same quiet spot above the footer instead of floating mid-list.
                // Disclosure now lives in the status bar; the list only exists while open.
                if !snapshot.archivedGroups.isEmpty, archiveExpanded || snapshot.isFiltering {
                    PiHairline()
                    ArchiveSection(groups: snapshot.archivedGroups, forceExpanded: snapshot.isFiltering)
                        .padding(.horizontal, PiTheme.space6)
                }
            }

            PiHairline()
            SidebarFooter(
                archivedCount: snapshot.all.filter(\.isArchived).count,
                archiveExpanded: $archiveExpanded,
                archiveForcedOpen: snapshot.isFiltering
            )
        }
        .contextMenu {
            Button("New Folder…") { store.newVirtualFolderRequested = true }
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
    let archivedCount: Int
    @Binding var archiveExpanded: Bool
    let archiveForcedOpen: Bool
    @State private var remoteAccessPresented = false
    private var runningCount: Int { store.runningSessions.count }
    private var resourceUsage: ThreadResourceUsage? { store.runningResourceUsage }
    private var archiveOpen: Bool { archiveExpanded || archiveForcedOpen }

    var body: some View {
        HStack(spacing: PiTheme.space6) {
            StatusDot(color: runningCount > 0 ? .piGreen : .secondary, pulsing: runningCount > 0)
            if let label {
                Text(label).font(SidebarTypography.status.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .help(activityDescription)
                    .accessibilityLabel("Session activity")
                    .accessibilityValue(activityDescription)
            }
            Spacer(minLength: PiTheme.space4)
            Button { remoteAccessPresented = true } label: {
                Image(systemName: "iphone")
                    .font(.system(size: PiIcon.small, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pair or manage phone access")
            .accessibilityLabel("Pair or manage phone access")
            .sheet(isPresented: $remoteAccessPresented) { RemoteAccessView() }
            if archivedCount > 0 {
                Button { archiveExpanded.toggle() } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: PiIcon.small, weight: .medium))
                        .foregroundStyle(archiveOpen ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(archiveOpen ? "Hide archived (\(archivedCount))" : "Show archived (\(archivedCount))")
                .accessibilityLabel("Archived, \(archivedCount) conversations")
                .accessibilityValue(archiveOpen ? "expanded" : "collapsed")
            }
            Button { Task { await store.refreshSessions(); await store.refreshScheduledThreads() } } label: {
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
        if let resourceUsage { return NumberFormatting.resources(resourceUsage) }
        if runningCount == 1 { return "1 session running" }
        if runningCount > 1 { return "\(runningCount) sessions running" }
        return nil
    }

    private var activityDescription: String {
        let sessions = runningCount == 1 ? "1 session running" : "\(runningCount) sessions running"
        guard let resourceUsage else { return sessions }
        return "\(sessions), \(NumberFormatting.cpuPercent(resourceUsage.cpuPercent)) CPU, \(NumberFormatting.memoryBytes(resourceUsage.memoryBytes)) memory"
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
        if lhs.isGlobal != rhs.isGlobal { return lhs.isGlobal }
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
    var isGlobal: Bool {
        !isVirtual && WorkspaceOrganization.isGlobalWorkingDirectory(URL(fileURLWithPath: path, isDirectory: true))
    }

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
        return isGlobal ? "Recents" : Self.projectName(forPath: path)
    }
}

// MARK: - Status view

/// The flat cross-project buckets. Declaration order is the *visible* order; the priority a
/// conversation is filed by is deliberately different (see `SidebarStatusGroup.groups`).
enum SidebarStatusSection: String, CaseIterable {
    case running = "Running"
    case unread = "Unread"
    case done = "Done"
    case automated = "Automated"
}

struct SidebarStatusGroup: Identifiable {
    let section: SidebarStatusSection
    let sessions: [SessionSummary]
    var id: String { section.rawValue }

    /// Files every non-archived conversation exactly once — running, else unread, else targeted by
    /// an automation, else done — then sorts running by its stable turn start and everything
    /// else by live modification date. Pure: the caller hands in the store's predicates and
    /// dates, so the partition is testable without a runtime.
    static func groups(
        _ sessions: [SessionSummary],
        isRunning: (SessionSummary) -> Bool,
        isUnread: (SessionSummary) -> Bool,
        isAutomated: (SessionSummary) -> Bool,
        runningAt: (SessionSummary) -> Date,
        modifiedAt: (SessionSummary) -> Date
    ) -> [SidebarStatusGroup] {
        var buckets: [SidebarStatusSection: [SessionSummary]] = [:]
        for session in sessions where !session.isArchived {
            let section: SidebarStatusSection = isRunning(session) ? .running
                : isUnread(session) ? .unread
                : isAutomated(session) ? .automated : .done
            buckets[section, default: []].append(session)
        }
        return SidebarStatusSection.allCases.compactMap { section in
            guard let bucket = buckets[section], !bucket.isEmpty else { return nil }
            // The file path breaks a tie, so equal timestamps still order deterministically
            // instead of letting an unstable sort reshuffle rows between renders.
            let sorted = bucket.sorted {
                let left = section == .running ? runningAt($0) : modifiedAt($0)
                let right = section == .running ? runningAt($1) : modifiedAt($1)
                return left == right
                    ? $0.fileURL.standardizedFileURL.path < $1.fileURL.standardizedFileURL.path
                    : left > right
            }
            return SidebarStatusGroup(section: section, sessions: sorted)
        }
    }
}

private struct StatusListView: View {
    @EnvironmentObject private var store: AppStore
    let sessions: [SessionSummary]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                ForEach(groups) { group in
                    Text(group.section.rawValue)
                        .font(SidebarTypography.folderHeader)
                        .foregroundStyle(.secondary)
                        .padding(.leading, PiTheme.space8)
                        .padding(.top, PiTheme.space6)
                        .frame(height: PiTheme.folderHeaderHeight, alignment: .leading)
                        .accessibilityLabel("\(group.section.rawValue), \(group.sessions.count) conversations")
                    ForEach(group.sessions) { SessionRow(session: $0, archived: false, hint: hint(for: $0)) }
                }
            }
            .padding(.horizontal, PiTheme.space6)
            .padding(.bottom, PiTheme.space12)
        }
        .scrollIndicators(.automatic)
    }

    private var groups: [SidebarStatusGroup] {
        SidebarStatusGroup.groups(
            sessions,
            isRunning: { store.isRunning($0) },
            isUnread: { store.isUnread($0) },
            isAutomated: { store.scheduledThreadIDs.contains($0.id) },
            runningAt: { store.runningSortDate($0) },
            modifiedAt: { store.liveModifiedAt($0) }
        )
    }

    /// Everything above the conversation itself, so a row torn out of its folder still says where
    /// it lives. Same helper the toolbar breadcrumb uses, so the two can never disagree.
    private func hint(for session: SessionSummary) -> String? {
        let ancestors = store.categorization(of: session).dropLast()
        return ancestors.isEmpty ? nil : ancestors.joined(separator: " > ")
    }
}

/// Caps the pinned, expanded archive so a long archive grows in place instead of crowding out
/// the active list above it or pushing the footer out of the sidebar.
private let archiveExpandedMaxHeight: CGFloat = 220

private struct ArchiveSection: View {
    let groups: [SessionFolderGroup]
    let forceExpanded: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PiTheme.space2) {
                ForEach(groups) { group in
                    SessionFolderSection(group: group, archived: true, forceExpanded: forceExpanded)
                }
            }
        }
        .frame(maxHeight: archiveExpandedMaxHeight)
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
                    Image(systemName: group.isGlobal ? (isOpen ? "clock.fill" : "clock") : (isOpen ? "folder.fill" : "folder"))
                        .font(.system(size: PiIcon.small)).foregroundStyle(.tertiary)
                        .frame(width: PiTheme.sidebarIconColumn, alignment: .center)
                    Text(group.name)
                        .font(SidebarTypography.folderHeader).foregroundStyle(.secondary).lineLimit(1)
                    if hasRunning { StatusDot(color: .piGreen, pulsing: true) }
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
            .help(group.isGlobal ? "Global conversations" : (group.isVirtual ? "Virtual folder" : group.path))
            .accessibilityLabel(group.isGlobal
                ? "Recents, global conversations, \(group.sessions.count) conversations"
                : "\(group.name) folder, \(group.sessions.count) conversations")
            .accessibilityValue("\(isOpen ? "expanded" : "collapsed")\(hasRunning ? ", sessions running" : "")")
            .contextMenu {
                if group.isGlobal {
                    Button("New Chat") { store.openNewChat() }
                } else if let id = group.virtualFolderID {
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
                guard !group.isGlobal else { return false }
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
            Text("Subfolders move up a level and conversations return to their project or Recents group. Session files are not changed.")
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
                .help(group.isGlobal ? "New global chat" : "New chat in \(group.name)")
                .accessibilityLabel(group.isGlobal ? "New global chat" : "New chat in \(group.name)")
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
        Set(store.sessions.map { $0.cwd.standardizedFileURL.path })
            .filter { !WorkspaceOrganization.isGlobalWorkingDirectory(URL(fileURLWithPath: $0, isDirectory: true)) }
            .sorted {
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
    /// Quiet location line for cross-project lists (Status), where a row has no folder above it.
    /// Same single line and row height as everywhere else; only the tree passes nothing.
    var hint: String?
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameValue = ""

    private var selected: Bool {
        guard !store.schedulesPresented else { return false }
        if case let .session(path) = store.route {
            return path == session.fileURL.standardizedFileURL.path
        }
        return false
    }
    private var waitingForQuestion: Bool { store.isWaitingForQuestion(session) }
    private var running: Bool { store.isRunning(session) }
    private var unread: Bool { store.isUnread(session) }
    private var scheduled: Bool { store.scheduledThreadIDs.contains(session.id) }
    private var resourceUsage: ThreadResourceUsage? { store.resourceUsage(session) }
    private var git: GitSnapshot { store.folderGit[session.cwd.standardizedFileURL.path] ?? .none }
    private var indent: CGFloat { CGFloat(min(depth, PiTheme.sidebarMaxFolderDepth)) * PiTheme.sidebarIndentStep }

    var body: some View {
        Button { store.selectSession(session) } label: {
            HStack(spacing: PiTheme.space6) {
                leadingIcon
                Text(session.displayName)
                    .font(SidebarTypography.conversationTitle(selected: selected))
                    .lineLimit(1).truncationMode(.tail)
                    // The title claims its width first, so the hint truncates before the name does.
                    .layoutPriority(1)
                if let hint {
                    Text(hint)
                        .font(SidebarTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
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
                Button("Project / Recents") { store.moveSession(session, toVirtualFolder: nil) }
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
        .help(hint ?? session.cwd.path)
        .accessibilityLabel("\(session.displayName)\(hint.map { ", in \($0)" } ?? ""), \(store.liveModifiedAt(session).relativeShort)\(waitingForQuestion ? ", waiting for your answer" : (running ? ", running" : ""))\(resourceUsage.map { ", \(NumberFormatting.cpuPercent($0.cpuPercent)) CPU, \(NumberFormatting.memoryBytes($0.memoryBytes)) memory" } ?? "")\(unread ? ", unread" : "")\(scheduled ? ", scheduled" : "")")
    }

    /// Reserved for the hover archive/restore button alone: status lives on the trailing edge,
    /// so this column stays empty until the pointer arrives and the title never shifts sideways.
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
            Color.clear
                .frame(width: PiTheme.sidebarIconColumn, height: PiTheme.sidebarRowHeight)
                .accessibilityHidden(true)
        }
    }

    /// Context first (time on hover, else the branch hint), then the clock, then one status dot:
    /// waiting for an answer outranks running, which outranks unread. One explicit stack keeps
    /// the pair grouped and ordered on the trailing edge.
    private var trailingAccessory: some View {
        HStack(spacing: PiTheme.space6) {
            if hovering {
                Text(store.liveModifiedAt(session).relativeShort).font(SidebarTypography.metadata).foregroundStyle(.tertiary)
            } else if running, let resourceUsage {
                Text(NumberFormatting.resources(resourceUsage))
                    .font(SidebarTypography.metadata.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("\(NumberFormatting.cpuPercent(resourceUsage.cpuPercent)) CPU · \(NumberFormatting.memoryBytes(resourceUsage.memoryBytes)) memory")
                    .accessibilityHidden(true)
            } else if GitIndicatorPolicy.showsBranchIndicator(git) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: PiIcon.micro)).foregroundStyle(.tertiary)
                    .help([git.branch, git.statusHint].compactMap { $0 }.joined(separator: " · "))
            }
            if scheduled {
                Image(systemName: "clock")
                    .font(.system(size: PiIcon.micro)).foregroundStyle(.tertiary)
                    .help("Runs on a schedule")
            }
            if waitingForQuestion {
                StatusDot(color: .piPurple).help("Waiting for your answer")
            } else if running {
                StatusDot(color: .piGreen, pulsing: true).help("Pi is working")
            } else if unread {
                StatusDot(color: .piBlue).help("Unread")
            }
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
