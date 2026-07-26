import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var archiveExpanded = false

    var body: some View {
        let snapshot = SidebarSnapshot(sessions: store.sessions, query: store.searchText)
        VStack(spacing: 0) {
            SidebarActionRow(
                title: "New chat",
                symbol: "square.and.pencil",
                shortcut: "⌘N",
                action: store.openNewChat
            )
            SidebarActionRow(
                title: "Quick switch",
                symbol: "magnifyingglass",
                shortcut: "⌘K",
                action: { store.quickSwitchPresented = true }
            )
            .padding(.bottom, PiTheme.space6)

            if store.isScanning, snapshot.all.isEmpty {
                VStack(spacing: PiTheme.space8) {
                    ProgressView().controlSize(.small)
                    Text("Finding Pi sessions…").font(PiFont.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.scanError, snapshot.all.isEmpty {
                ContentUnavailableView("Sessions unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if snapshot.all.isEmpty {
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
                Text(shortcut)
                    .font(PiFont.micro)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: PiTheme.sidebarRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, PiTheme.space6)
        .help("\(title) (\(shortcut))")
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
            Text(label)
                .font(PiFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        .frame(height: PiTheme.statusBarHeight + PiTheme.space4)
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
    /// While searching, every folder is shown open so matches are never hidden by a collapse.
    let isFiltering: Bool

    init(sessions: [SessionSummary], query: String) {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isFiltering = !folded.isEmpty
        all = folded.isEmpty ? sessions : sessions.filter { $0.searchKey.contains(folded) }
        activeGroups = Self.groups(all.filter { !$0.isArchived })
        archivedGroups = Self.groups(all.filter(\.isArchived))
    }

    private static func groups(_ sessions: [SessionSummary]) -> [SessionFolderGroup] {
        Dictionary(grouping: sessions, by: { $0.cwd.standardizedFileURL.path })
            .map { SessionFolderGroup(path: $0.key, sessions: $0.value.sorted { $0.modifiedAt > $1.modifiedAt }) }
            .sorted { ($0.sessions.first?.modifiedAt ?? .distantPast) > ($1.sessions.first?.modifiedAt ?? .distantPast) }
    }
}

struct SessionFolderGroup: Identifiable {
    var id: String { path }
    let path: String
    let sessions: [SessionSummary]

    var name: String {
        let value = URL(fileURLWithPath: path).lastPathComponent
        return value.isEmpty ? path : value
    }

    /// Folders touched within two weeks open by default; older projects start collapsed.
    static let recencyWindow: TimeInterval = 14 * 24 * 60 * 60

    func isRecent(now: Date = Date()) -> Bool {
        guard let newest = sessions.first?.modifiedAt else { return false }
        return now.timeIntervalSince(newest) <= Self.recencyWindow
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
                    Image(systemName: "archivebox")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("Archived")
                        .font(PiFont.captionEmphasis)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(groups.reduce(0) { $0 + $1.sessions.count })")
                        .font(PiFont.micro.monospacedDigit())
                        .foregroundStyle(.tertiary)
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

    private var hasRunning: Bool { group.sessions.contains { store.isRunning($0) } }
    private var defaultExpanded: Bool { archived ? true : (group.isRecent() || hasRunning) }
    private var isOpen: Bool {
        forceExpanded || store.isFolderExpanded(path: group.path, defaultExpanded: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space2) {
            Button {
                store.setFolderExpanded(!isOpen, path: group.path)
            } label: {
                HStack(spacing: PiTheme.space6) {
                    PiChevron(expanded: isOpen)
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(group.name)
                        .font(PiFont.captionEmphasis)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if hasRunning {
                        StatusDot(color: .piGreen, isPulsing: true)
                    }
                    Spacer(minLength: PiTheme.space4)
                    Text("\(group.sessions.count)")
                        .font(PiFont.micro.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, PiTheme.space8)
                .frame(height: PiTheme.folderHeaderHeight)
                .contentShape(Rectangle())
                .piRowBackground(selected: false, hovering: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(group.path)
            .accessibilityLabel("\(group.name) folder, \(group.sessions.count) conversations")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")

            if isOpen {
                ForEach(group.sessions) { SessionRow(session: $0, archived: archived) }
            }
        }
        .padding(.top, PiTheme.space6)
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
    private var git: GitSnapshot { store.folderGit[session.cwd.standardizedFileURL.path] ?? .none }

    var body: some View {
        Button { store.selectSession(session) } label: {
            HStack(spacing: PiTheme.space6) {
                Text(session.displayName)
                    .font(selected ? PiFont.rowEmphasis : PiFont.row)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: PiTheme.space4)
                trailingAccessory
            }
            // Rows align their text with the folder label above them.
            .padding(.leading, PiTheme.space8 + PiTheme.space12)
            .padding(.trailing, PiTheme.space8)
            .frame(height: PiTheme.sidebarRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: selected, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { renameValue = session.displayName; renaming = true }
            // Deliberately no keyboardShortcut here: a per-row key equivalent would register
            // once per visible row and fire for all of them at once. ⌘⇧A lives in the
            // Conversation menu and always applies to the selected conversation only.
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
        .accessibilityLabel("\(session.displayName), \(store.liveModifiedAt(session).relativeShort)\(running ? ", running" : "")")
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if running {
            ProgressView().controlSize(.mini).help("Pi is working")
        } else if hovering {
            Text(store.liveModifiedAt(session).relativeShort)
                .font(PiFont.micro)
                .foregroundStyle(.tertiary)
        } else if git.isRepository, git.isDirty {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help([git.branch, git.statusHint].compactMap { $0 }.joined(separator: " · "))
        }
    }
}
