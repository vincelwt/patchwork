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
            projectPaths: store.sidebarFolders.map(\.path),
            virtualFolders: store.virtualFolders,
            assignments: store.virtualFolderAssignments,
            projectAssignments: store.projectFolderAssignments,
            managedWorktreeProjects: store.managedWorktreeProjects,
            archivedAt: store.archivedDate
        )
        VStack(spacing: 0) {
            SidebarActionRow(title: "New chat", symbol: "square.and.pencil", shortcut: "⌘N", action: store.openNewChat)
            SidebarActionRow(
                title: "Import folder", symbol: "folder.badge.plus", shortcut: "", action: store.importProjectFolder
            )
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

            if store.isScanning, snapshot.activeGroups.isEmpty, snapshot.archivedSessions.isEmpty {
                VStack(spacing: PiTheme.space8) {
                    ProgressView().controlSize(.small)
                    Text("Finding Pi sessions…").font(SidebarTypography.status).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.scanError, snapshot.activeGroups.isEmpty, snapshot.archivedSessions.isEmpty {
                PiUnavailableView(
                    "Sessions unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: error
                )
            } else if snapshot.activeGroups.isEmpty, snapshot.archivedSessions.isEmpty {
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
                if !snapshot.archivedSessions.isEmpty, archiveExpanded || snapshot.isFiltering {
                    PiHairline()
                    ArchiveSection(sessions: snapshot.archivedSessions)
                        .padding(.horizontal, PiTheme.space6)
                }
            }

            if store.hiddenForeignCount > 0, !store.showsForeignConversations {
                PiHairline()
                ForeignConversationsRow(count: store.hiddenForeignCount)
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
            Button("Import Folder…", action: store.importProjectFolder)
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

/// Conversations this app did not start are hidden by default, so this says how many and offers
/// to show them. Silently swallowing a few hundred conversations would look like data loss.
private struct ForeignConversationsRow: View {
    @EnvironmentObject private var store: AppStore
    let count: Int
    @State private var hovering = false

    var body: some View {
        Button { store.setShowsForeignConversations(true) } label: {
            HStack(spacing: PiTheme.space6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: PiIcon.micro))
                    .foregroundStyle(.tertiary)
                Text("\(count) started elsewhere")
                    .font(SidebarTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: PiTheme.space4)
                Text("Show")
                    .font(SidebarTypography.metadata)
                    .foregroundStyle(hovering ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, PiTheme.sidebarIconInset)
            .frame(height: PiTheme.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Conversations started in a terminal, another app, or by an automation are hidden. Driving one from here would mean two processes writing the same transcript.")
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var store: AppStore
    let archivedCount: Int
    @Binding var archiveExpanded: Bool
    let archiveForcedOpen: Bool
    @State private var remoteAccessPresented = false
    private var runningCount: Int { store.runningSessions.count }
    private var resourceUsage: ThreadResourceUsage? { store.aggregateResourceUsage }
    private var archiveOpen: Bool { archiveExpanded || archiveForcedOpen }

    var body: some View {
        HStack(spacing: PiTheme.space6) {
            StatusDot(color: runningCount > 0 ? .piGreen : .secondary, pulsing: runningCount > 0)
            TimelineView(.periodic(from: .now, by: SessionActivityMonitor.pollInterval)) { _ in
                if let label {
                    Text(label).font(SidebarTypography.status.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        .help(activityDescription)
                        .accessibilityLabel("Session activity")
                        .accessibilityValue(activityDescription)
                }
            }
            Spacer(minLength: PiTheme.space4)
            Image(systemName: store.isCaffeinated ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: PiIcon.small, weight: .medium))
                .foregroundStyle(store.isCaffeinated ? Color.piGreen : .secondary)
                .frame(width: 22, height: 22)
                .help(store.isCaffeinated
                    ? "Keeping this Mac awake while a thread runs"
                    : "Sleep prevention turns on automatically when a thread runs")
                .accessibilityLabel("Automatic sleep prevention")
                .accessibilityValue(store.isCaffeinated ? "on" : "off")
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

    /// Resource totals remain useful while an idle thread's managed process is still working.
    private var label: String? {
        if let resourceUsage { return NumberFormatting.resources(resourceUsage) }
        if runningCount == 1 { return "1 session running" }
        if runningCount > 1 { return "\(runningCount) sessions running" }
        return nil
    }

    private var activityDescription: String {
        let sessions = runningCount == 0 ? "No sessions running"
            : runningCount == 1 ? "1 session running" : "\(runningCount) sessions running"
        guard let resourceUsage else { return sessions }
        return "\(sessions), \(NumberFormatting.cpuPercent(resourceUsage.cpuPercent)) CPU, \(NumberFormatting.memoryBytes(resourceUsage.memoryBytes)) memory"
    }
}

// MARK: - Grouping

struct SidebarSnapshot {
    let all: [SessionSummary]
    let activeGroups: [SessionFolderGroup]
    /// Flat and sorted by archive recency, not grouped: see `ArchiveSection`.
    let archivedSessions: [SessionSummary]
    let isFiltering: Bool

    init(
        sessions: [SessionSummary],
        query: String,
        projectPaths: [String] = [],
        virtualFolders: [VirtualFolder] = [],
        assignments: [String: String] = [:],
        projectAssignments: [String: String] = [:],
        managedWorktreeProjects: [String: String] = [:],
        archivedAt: (SessionSummary) -> Date = { $0.modifiedAt }
    ) {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isFiltering = !folded.isEmpty
        let validVirtualIDs = Set(virtualFolders.map(\.id))
        all = folded.isEmpty ? sessions : sessions.filter { session in
            if session.searchKey.contains(folded) { return true }
            if WorkspaceOrganization.projectPath(
                of: session,
                managedWorktreeProjects: managedWorktreeProjects
            ).lowercased().contains(folded) { return true }
            let path = session.fileURL.standardizedFileURL.path
            guard let id = assignments[path],
                  let folder = virtualFolders.first(where: { $0.id == id }) else { return false }
            return folder.name.lowercased().contains(folded)
        }
        let visibleProjectPaths = projectPaths.filter {
            folded.isEmpty || $0.lowercased().contains(folded)
        }
        activeGroups = Self.groups(
            all.filter { !$0.isArchived },
            knownProjectPaths: Set(visibleProjectPaths),
            virtualFolders: virtualFolders,
            assignments: assignments,
            projectAssignments: projectAssignments,
            managedWorktreeProjects: managedWorktreeProjects,
            validVirtualIDs: validVirtualIDs,
            includeEmptyVirtualFolders: !isFiltering
        )
        archivedSessions = all.filter(\.isArchived).sorted { archivedAt($0) > archivedAt($1) }
    }

    /// Builds one alternating forest: virtual folders can contain projects, and projects can
    /// still contain virtual folders. Conversation assignments override their real project, so
    /// every session appears exactly once.
    private static func groups(
        _ sessions: [SessionSummary],
        knownProjectPaths: Set<String>,
        virtualFolders: [VirtualFolder],
        assignments: [String: String],
        projectAssignments: [String: String],
        managedWorktreeProjects: [String: String],
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
                let project = WorkspaceOrganization.projectPath(
                    of: session,
                    managedWorktreeProjects: managedWorktreeProjects
                )
                filesystemSessions[project, default: []].append(session)
            }
        }

        var virtualByGroupID: [String: VirtualFolder] = [:]
        for folder in virtualFolders {
            let groupID = WorkspaceOrganization.groupID(forVirtualFolderID: folder.id)
            if virtualByGroupID[groupID] == nil { virtualByGroupID[groupID] = folder }
        }
        var projectPaths = Set(filesystemSessions.keys).union(knownProjectPaths)
        for folder in virtualFolders {
            guard let parent = WorkspaceOrganization.effectiveParentID(
                of: folder,
                in: virtualFolders,
                projectAssignments: projectAssignments
            ), WorkspaceOrganization.virtualFolderID(fromGroupID: parent) == nil else { continue }
            projectPaths.insert(parent)
        }

        var childrenByParent: [String: [String]] = [:]
        for groupID in virtualByGroupID.keys {
            let parent = WorkspaceOrganization.effectiveParentID(
                ofGroupID: groupID,
                folders: virtualFolders,
                projectAssignments: projectAssignments
            ) ?? ""
            childrenByParent[parent, default: []].append(groupID)
        }
        for path in projectPaths {
            let parent = WorkspaceOrganization.effectiveParentID(
                ofGroupID: path,
                folders: virtualFolders,
                projectAssignments: projectAssignments
            ) ?? ""
            childrenByParent[parent, default: []].append(path)
        }

        func build(_ groupID: String, depth: Int) -> SessionFolderGroup? {
            let childIDs = depth >= PiTheme.sidebarMaxFolderDepth ? [] : childrenByParent[groupID] ?? []
            let children = childIDs.compactMap { build($0, depth: depth + 1) }.sorted(by: groupSort)
            if let folder = virtualByGroupID[groupID] {
                let own = (virtualSessions[folder.id] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
                let group = SessionFolderGroup(virtualFolder: folder, sessions: own, children: children)
                return includeEmptyVirtualFolders || !own.isEmpty || !children.isEmpty ? group : nil
            }
            guard projectPaths.contains(groupID) else { return nil }
            let own = (filesystemSessions[groupID] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
            guard knownProjectPaths.contains(groupID) || !own.isEmpty || !children.isEmpty else { return nil }
            return SessionFolderGroup(path: groupID, sessions: own, children: children)
        }

        return (childrenByParent[""] ?? [])
            .compactMap { build($0, depth: 0) }
            .sorted(by: groupSort)
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
    /// Nested virtual folders or real projects. Either kind can contain the other.
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
    case pullRequest = "Open PRs"
    case done = "Done"
    case automated = "Automated"
}

struct SidebarStatusGroup: Identifiable {
    let section: SidebarStatusSection
    let sessions: [SessionSummary]
    var id: String { section.rawValue }

    /// The shared status priority used by the sidebar and Dock badge.
    static func section(
        for session: SessionSummary,
        isRunning: Bool,
        isUnread: Bool,
        hasOpenPullRequest: Bool,
        isAutomated: Bool
    ) -> SidebarStatusSection? {
        guard !session.isArchived else { return nil }
        if isRunning { return .running }
        if isUnread { return .unread }
        if hasOpenPullRequest { return .pullRequest }
        if isAutomated { return .automated }
        return .done
    }

    /// Files every non-archived conversation exactly once: running, else unread, else open PR,
    /// else targeted by an automation, else done. It sorts running by its stable turn start and
    /// everything else by live modification date. Pure: the caller hands in the store's
    /// predicates and dates, so the partition is testable without a runtime.
    static func groups(
        _ sessions: [SessionSummary],
        isRunning: (SessionSummary) -> Bool,
        isUnread: (SessionSummary) -> Bool,
        hasOpenPullRequest: (SessionSummary) -> Bool,
        isAutomated: (SessionSummary) -> Bool,
        runningAt: (SessionSummary) -> Date,
        modifiedAt: (SessionSummary) -> Date
    ) -> [SidebarStatusGroup] {
        var buckets: [SidebarStatusSection: [SessionSummary]] = [:]
        for session in sessions {
            guard let section = Self.section(
                for: session,
                isRunning: isRunning(session),
                isUnread: isUnread(session),
                hasOpenPullRequest: hasOpenPullRequest(session),
                isAutomated: isAutomated(session)
            ) else { continue }
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
    /// Which buckets are folded away is a way of looking at the same list, like `SidebarMode`:
    /// local state, everything open until this session says otherwise.
    @State private var collapsed: Set<SidebarStatusSection> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                ForEach(groups) { group in
                    let expanded = !collapsed.contains(group.section)
                    StatusSectionHeader(section: group.section, count: group.sessions.count, expanded: expanded) {
                        if expanded { collapsed.insert(group.section) } else { collapsed.remove(group.section) }
                    }
                    if expanded {
                        ForEach(group.sessions) { SessionRow(session: $0, archived: false, hint: hint(for: $0)) }
                    }
                }
            }
            .padding(.horizontal, PiTheme.space6)
            .padding(.bottom, PiTheme.space12)
        }
        .scrollIndicators(.automatic)
    }

    private var groups: [SidebarStatusGroup] { store.statusGroups(sessions) }

    /// Everything above the conversation itself, so a row torn out of its folder still says where
    /// it lives. Same helper the toolbar breadcrumb uses, so the two can never disagree.
    private func hint(for session: SessionSummary) -> String? {
        let ancestors = store.categorization(of: session).dropLast()
        return ancestors.isEmpty ? nil : ancestors.joined(separator: " > ")
    }
}

/// Every Status bucket is a real disclosure, Automated included: a chevron, the whole header row
/// as the click target, and the same header type, height, and hover treatment as the folder tree.
private struct StatusSectionHeader: View {
    let section: SidebarStatusSection
    let count: Int
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: PiTheme.space6) {
                // The chevron takes the shared icon column, so a section title starts on the
                // same text origin as folder headers and conversation rows.
                PiChevron(expanded: expanded)
                    .frame(width: PiTheme.sidebarIconColumn, alignment: .center)
                Text(section.rawValue)
                    .font(SidebarTypography.folderHeader).foregroundStyle(.secondary).lineLimit(1)
                Text("\(count)")
                    .font(SidebarTypography.metadata.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer(minLength: PiTheme.space4)
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: PiTheme.folderHeaderHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, PiTheme.space6)
        .help(expanded ? "Hide \(section.rawValue)" : "Show \(section.rawValue)")
        .accessibilityLabel("\(section.rawValue), \(count) conversations")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }
}

/// Caps the pinned, expanded archive so a long archive grows in place instead of crowding out
/// the active list above it or pushing the footer out of the sidebar.
private let archiveExpandedMaxHeight: CGFloat = 220

/// Deliberately not the folder tree the active list uses: an archive is a history, so it reads
/// as one flat list, most recently archived first, with each row's folder as its hint.
private struct ArchiveSection: View {
    @EnvironmentObject private var store: AppStore
    let sessions: [SessionSummary]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                ForEach(sessions) {
                    SessionRow(
                        session: $0,
                        archived: true,
                        hint: SessionFolderGroup.projectName(forPath: store.projectFolder(for: $0).path)
                    )
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
    private var projectGit: GitSnapshot {
        guard !group.isVirtual, !group.isGlobal else { return .none }
        let snapshots = store.sessions.compactMap { session -> GitSnapshot? in
            guard store.projectFolder(for: session).standardizedFileURL.path == group.path else { return nil }
            return store.folderGit[session.cwd.standardizedFileURL.path]
        }
        return snapshots.first(where: { $0.isDirty })
            ?? snapshots.first(where: { $0.isRepository })
            ?? store.folderGit[group.path]
            ?? .none
    }
    private var headerSymbol: String {
        if group.isGlobal { return isOpen ? "clock.fill" : "clock" }
        if group.isVirtual { return isOpen ? "folder.fill" : "folder" }
        return projectGit.isRepository ? "arrow.triangle.branch" : "externaldrive"
    }
    private var headerHelp: String {
        if group.isGlobal { return "Global conversations" }
        if group.isVirtual { return "Virtual folder" }
        let status = [projectGit.branch, projectGit.statusHint].compactMap { $0 }.joined(separator: " · ")
        return status.isEmpty ? group.path : "\(group.path) · \(status)"
    }
    private var headerAccessibilityLabel: String {
        if group.isGlobal { return "Recents, global conversations, \(group.sessions.count) conversations" }
        if group.isVirtual { return "\(group.name), virtual folder, \(group.sessions.count) conversations" }
        let kind = projectGit.isRepository ? "Git repository" : "real folder"
        let status = projectGit.statusHint.map { ", \($0)" } ?? ""
        return "\(group.name), \(kind)\(status), \(group.sessions.count) conversations"
    }
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
                    Image(systemName: headerSymbol)
                        .font(.system(size: PiIcon.small))
                        .foregroundStyle(projectGit.isDirty ? Color.piOrange : Color.secondary)
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
            .help(headerHelp)
            .accessibilityLabel(headerAccessibilityLabel)
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
                        let projects = projectDestinations(excluding: id)
                        if !projects.isEmpty { Divider() }
                        ForEach(projects, id: \.self) { path in
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
                    Menu("Move Folder to…") {
                        Button("Top level") { store.moveProjectFolder(path: group.path, toVirtualFolder: nil) }
                        let destinations = availableProjectDestinations
                        if !destinations.isEmpty { Divider() }
                        ForEach(destinations) { entry in
                            Button(String(repeating: "  ", count: entry.depth) + entry.folder.name) {
                                store.moveProjectFolder(path: group.path, toVirtualFolder: entry.folder.id)
                            }
                        }
                    }
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
            Text("Subfolders move up a level. Nested projects return to top level or the enclosing virtual folder. Directly filed conversations return to their project or Recents group. Session files are not changed.")
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

    /// Known project paths that would not put this virtual folder under one of its descendants.
    private func projectDestinations(excluding id: String) -> [String] {
        Set(store.sessions.map { store.projectFolder(for: $0).standardizedFileURL.path })
            .filter { path in
                !WorkspaceOrganization.isGlobalWorkingDirectory(URL(fileURLWithPath: path, isDirectory: true))
                    && !WorkspaceOrganization.wouldCreateGroupCycle(
                        moving: WorkspaceOrganization.groupID(forVirtualFolderID: id),
                        into: path,
                        folders: store.virtualFolders,
                        projectAssignments: store.projectFolderAssignments
                    )
            }
            .sorted {
                SessionFolderGroup.projectName(forPath: $0).localizedCaseInsensitiveCompare(SessionFolderGroup.projectName(forPath: $1)) == .orderedAscending
            }
    }

    private func availableFolderDestinations(excluding id: String) -> [WorkspaceOrganization.FolderTreeEntry] {
        WorkspaceOrganization.allFolderEntries(
            store.virtualFolders,
            projectAssignments: store.projectFolderAssignments
        ).filter {
            $0.folder.id != id && !WorkspaceOrganization.wouldCreateCycle(
                moving: id,
                into: $0.folder.id,
                in: store.virtualFolders,
                projectAssignments: store.projectFolderAssignments
            )
        }
    }

    private var availableProjectDestinations: [WorkspaceOrganization.FolderTreeEntry] {
        WorkspaceOrganization.allFolderEntries(
            store.virtualFolders,
            projectAssignments: store.projectFolderAssignments
        ).filter {
            !WorkspaceOrganization.wouldCreateGroupCycle(
                moving: group.path,
                into: WorkspaceOrganization.groupID(forVirtualFolderID: $0.folder.id),
                folders: store.virtualFolders,
                projectAssignments: store.projectFolderAssignments
            )
        }
    }
}

enum SidebarRunningLabel {
    static func text(since date: Date?, now: Date, usage: ThreadResourceUsage?, hovering: Bool) -> String {
        if hovering, let usage { return NumberFormatting.resources(usage) }
        guard let date else { return "working" }
        return NumberFormatting.elapsed(since: date, now: now)
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
                let entries = WorkspaceOrganization.allFolderEntries(
                    store.virtualFolders,
                    projectAssignments: store.projectFolderAssignments
                )
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
        .help(hint ?? store.projectFolder(for: session).path)
        .accessibilityLabel("\(session.displayName)\(hint.map { ", in \($0)" } ?? ""), \(store.liveModifiedAt(session).relativeShort)\(waitingForQuestion ? ", waiting for your answer" : (running ? ", running" : ""))\(resourceUsage.map { ", \(NumberFormatting.cpuPercent($0.cpuPercent)) CPU, \(NumberFormatting.memoryBytes($0.memoryBytes)) memory" } ?? "")\(unread ? ", unread" : "")\(scheduled ? ", scheduled" : "")")
    }

    /// Hover archive/restore, and otherwise the agent that wrote this conversation. Status still
    /// lives on the trailing edge, so this column keeps one fixed width and the title never
    /// shifts sideways whichever of the three it is showing. The badge is suppressed when only
    /// one agent has any history, where it would be noise on every row.
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
        } else if store.showsAgentBadges {
            AgentBadge(agent: session.agent, isProminent: selected || running)
                .frame(width: PiTheme.sidebarIconColumn, height: PiTheme.sidebarRowHeight, alignment: .center)
        } else {
            Color.clear
                .frame(width: PiTheme.sidebarIconColumn, height: PiTheme.sidebarRowHeight)
                .accessibilityHidden(true)
        }
    }

    /// Context first (run time with resources on hover, else modification time/branch), then the
    /// clock, then one status dot. Waiting for an answer outranks running, which outranks unread.
    private var trailingAccessory: some View {
        HStack(spacing: PiTheme.space6) {
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(SidebarRunningLabel.text(
                        since: store.runningSince(session), now: context.date,
                        usage: resourceUsage, hovering: hovering
                    ))
                    .font(SidebarTypography.metadata.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                .help(resourceUsage.map {
                    "\(NumberFormatting.cpuPercent($0.cpuPercent)) CPU · \(NumberFormatting.memoryBytes($0.memoryBytes)) memory"
                } ?? "\(session.agent.displayName) is working")
                .accessibilityHidden(true)
            } else if hovering {
                Text(store.liveModifiedAt(session).relativeShort).font(SidebarTypography.metadata).foregroundStyle(.tertiary)
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
