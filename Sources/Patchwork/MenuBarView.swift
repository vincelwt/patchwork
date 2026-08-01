import AppKit
import SwiftUI

/// Budgets the panel's two scrollable regions so account limits and actions stay on-screen.
enum MenuBarPanelLayout {
    static let sessionDisplayLimit = 50

    static var availableScreenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? PatchworkTheme.menuBarFallbackScreenHeight
    }

    static func heights(availableHeight: CGFloat) -> (sessions: CGFloat, limits: CGFloat) {
        let budget = max(0, availableHeight - PatchworkTheme.menuBarScreenMargin - PatchworkTheme.menuBarFixedHeight)
        let limits = min(
            PatchworkTheme.menuBarLimitsIdealHeight,
            max(min(PatchworkTheme.menuBarLimitsMinHeight, budget), budget - PatchworkTheme.menuBarSessionsMinHeight)
        )
        let sessions = min(PatchworkTheme.menuBarSessionsIdealHeight, max(0, budget - limits))
        return (sessions, limits)
    }

    /// The buckets worth a glance from the menu bar, in display order. Open PRs and Automated
    /// stay in the sidebar; because `SidebarStatusGroup.groups` files each conversation exactly
    /// once, dropping them here cannot leak them into Done.
    static let sections: [SidebarStatusSection] = [.running, .unread, .done]

    /// Fills Running, then Unread, then Done up to the one shared row bound and reports what did
    /// not fit, so a long tail becomes a single line instead of an unbounded list.
    static func boundedSections(_ groups: [SidebarStatusGroup]) -> (sections: [SidebarStatusGroup], hidden: Int) {
        var remaining = sessionDisplayLimit
        var visible: [SidebarStatusGroup] = []
        var hidden = 0
        for group in groups where sections.contains(group.section) {
            let shown = min(remaining, group.sessions.count)
            hidden += group.sessions.count - shown
            remaining -= shown
            guard shown > 0 else { continue }
            visible.append(SidebarStatusGroup(section: group.section, sessions: Array(group.sessions.prefix(shown))))
        }
        return (visible, hidden)
    }

    static func sessionHeight(rows: Int, headers: Int, maxHeight: CGFloat) -> CGFloat {
        guard rows > 0 else { return 0 }
        let rows = min(rows, sessionDisplayLimit)
        let contentHeight = CGFloat(rows) * PatchworkTheme.menuBarSessionRowHeight
            + CGFloat(headers) * PatchworkTheme.folderHeaderHeight
            + CGFloat(rows + headers - 1) * PatchworkTheme.space2
            + 2 * PatchworkTheme.space4
        return min(contentHeight, maxHeight)
    }

    /// x origin that centers a `panelWidth`-wide panel under `clickX`, kept inside `visibleFrame`.
    static func anchoredX(clickX: CGFloat, panelWidth: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let rightmost = max(visibleFrame.minX, visibleFrame.maxX - panelWidth)
        return min(max(clickX - panelWidth / 2, visibleFrame.minX), rightmost)
    }

    /// macOS 27 beta opens the `.window` MenuBarExtra panel at the screen's top-right instead of
    /// under the clicked status item. Called as the panel's content appears — while the pointer is
    /// still in the menu bar strip — this nudges only the panel's x origin back under that click.
    /// Native y placement and dismissal are untouched.
    /// ponytail: no version gate; centering under the click is correct on every macOS.
    @MainActor
    static func anchorPanelToClick() {
        let click = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(click) }) ?? NSScreen.main,
              click.y >= screen.visibleFrame.maxY else { return }  // pointer is not in the menu bar
        let visibleFrame = screen.visibleFrame
        // The panel does not exist yet on this turn of the main loop.
        DispatchQueue.main.async {
            guard let panel = NSApplication.shared.windows.first(where: {
                $0.isVisible && $0.level == .popUpMenu
            }) else { return }
            let x = anchoredX(clickX: click.x, panelWidth: panel.frame.width, visibleFrame: visibleFrame)
            panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.origin.y))
        }
    }
}

/// Reuses the shared activity monitor; the menu bar never starts its own timer or file poll.
struct MenuBarContentView: View {
    @EnvironmentObject private var store: AppStore
    private var running: [SessionSummary] { store.runningSessions }
    private var account: CodexAccountStatus? { store.statusModel.codexAccount }
    private var heights: (sessions: CGFloat, limits: CGFloat) {
        MenuBarPanelLayout.heights(availableHeight: MenuBarPanelLayout.availableScreenHeight)
    }

    var body: some View {
        let visible = MenuBarPanelLayout.boundedSections(store.statusGroups(store.sessions))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PatchworkTheme.space8) {
                if !running.isEmpty { StatusDot(color: .patchworkGreen, pulsing: true) }
                Text(runningTitle).font(PatchworkFont.rowEmphasis)
                Spacer()
                Text("Patchwork").font(PatchworkFont.micro).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PatchworkTheme.space12)
            .frame(height: PatchworkTheme.menuBarHeaderHeight)

            PatchworkHairline()

            if visible.sections.isEmpty {
                Text("Nothing to show")
                    .font(PatchworkFont.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, PatchworkTheme.space12)
                    .frame(height: PatchworkTheme.menuBarEmptyStateHeight)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                        ForEach(visible.sections) { group in
                            Text(group.section.rawValue)
                                .font(SidebarTypography.folderHeader)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, PatchworkTheme.space8)
                                .frame(height: PatchworkTheme.folderHeaderHeight, alignment: .leading)
                                .accessibilityLabel("\(group.section.rawValue), \(group.sessions.count) conversations")
                            ForEach(group.sessions) { MenuBarSessionRow(session: $0, section: group.section) }
                        }
                        if visible.hidden > 0 {
                            Text("\(visible.hidden) more")
                                .font(PatchworkFont.micro).foregroundStyle(.tertiary)
                                .padding(.horizontal, PatchworkTheme.space8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PatchworkTheme.space4)
                }
                .frame(height: MenuBarPanelLayout.sessionHeight(
                    rows: visible.sections.reduce(0) { $0 + $1.sessions.count },
                    headers: visible.sections.count,
                    maxHeight: heights.sessions
                ))
            }

            PatchworkHairline()
            // The same all-account `/limits` report the main window's account chip shows on
            // hover — cached instantly, refreshed periodically in the background by
            // `LimitsReportStore`, never fetched directly by this view.
            ScrollView { LimitsPopoverView(fallback: account) }
                .frame(height: heights.limits)
            PatchworkHairline()

            VStack(spacing: PatchworkTheme.space2) {
                MenuBarActionRow(title: "New Chat", symbol: "square.and.pencil") {
                    MenuBarActivation.activateMainWindow(); store.openNewChat()
                }
                MenuBarActionRow(title: "Quit Patchwork", symbol: "power") { NSApplication.shared.terminate(nil) }
            }
            .padding(PatchworkTheme.space4)
        }
        .frame(width: PatchworkTheme.menuBarWidth)
        .onAppear { MenuBarPanelLayout.anchorPanelToClick() }
    }

    private var runningTitle: String {
        running.isEmpty ? "Ready" : "\(running.count) running"
    }
}

/// One session row with real hover feedback and a click that brings the conversation on screen,
/// matching every other row list in the app.
private struct MenuBarSessionRow: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionSummary
    let section: SidebarStatusSection
    @State private var hovering = false

    var body: some View {
        Button { activate() } label: {
            HStack(spacing: PatchworkTheme.space8) {
                dot
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(PatchworkFont.row).lineLimit(1).truncationMode(.tail)
                    Text("\(store.displayFolderName(for: session)) \u{b7} \(state)")
                        .font(PatchworkFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PatchworkTheme.space8)
            .frame(height: PatchworkTheme.menuBarSessionRowHeight)
            .contentShape(Rectangle())
            .patchworkRowBackground(selected: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Done keeps the column without a mark of its own: a clear dot reuses the shared dot size
    /// rather than introducing a spacer constant.
    private var dot: some View {
        switch section {
        case .running: return StatusDot(color: .patchworkGreen, pulsing: true)
        case .unread: return StatusDot(color: .patchworkBlue)
        default: return StatusDot(color: .clear)
        }
    }

    private var state: String {
        guard section == .running else { return store.liveModifiedAt(session).relativeShort }
        return store.runningSince(session).map { "working \(NumberFormatting.elapsed(since: $0))" } ?? "working"
    }

    private func activate() {
        MenuBarActivation.activateMainWindow()
        store.selectSession(session)
    }
}

/// One bottom-of-menu action row, also with the standard hover treatment.
private struct MenuBarActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: PatchworkTheme.space8) {
                Image(systemName: symbol).frame(width: PatchworkTheme.gridIconColumn)
                    .font(.system(size: PatchworkIcon.small)).foregroundStyle(.secondary)
                Text(title).font(PatchworkFont.row).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, PatchworkTheme.space8)
            .frame(height: PatchworkTheme.menuBarActionRowHeight)
            .contentShape(Rectangle())
            .patchworkRowBackground(selected: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The menu bar's single glyph state, and the one place its precedence is decided: any running
/// thread wins (green, filled), otherwise any unread thread (blue, filled), otherwise an empty
/// outline. Exactly one case is ever shown — there is nothing to combine at the view layer.
enum MenuBarCircleState: Equatable {
    case running
    case unread
    case idle

    static func resolve(runningCount: Int, unreadCount: Int) -> MenuBarCircleState {
        if runningCount > 0 { return .running }
        if unreadCount > 0 { return .unread }
        return .idle
    }

    var symbolName: String { self == .idle ? "circle" : "circle.fill" }

    /// Idle stays a template image so AppKit tints it correctly against any menu bar background
    /// (light, dark, or a translucent wallpaper tint). The two active states carry real colour,
    /// which requires opting out of template rendering.
    var usesOriginalColor: Bool { self != .idle }

    var tint: Color {
        switch self {
        case .running: return .patchworkGreen
        case .unread: return .patchworkBlue
        case .idle: return .primary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .running: return "Patchwork, sessions running"
        case .unread: return "Patchwork, unread sessions"
        case .idle: return "Patchwork, idle"
        }
    }
}

enum ThreadCountBadge {
    static func label(for count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    @MainActor
    static func updateDock(doneCount: Int) {
        NSApplication.shared.dockTile.badgeLabel = label(for: doneCount)
    }
}

struct MenuBarLabelView: View {
    @EnvironmentObject private var store: AppStore

    private var runningCount: Int { store.runningSessions.count }

    private var unreadCount: Int {
        store.sessions.filter { !$0.isArchived && store.isUnread($0) }.count
    }

    private var state: MenuBarCircleState {
        MenuBarCircleState.resolve(runningCount: runningCount, unreadCount: unreadCount)
    }

    var body: some View {
        HStack(spacing: PatchworkTheme.space4) {
            Image(systemName: state.symbolName)
                .renderingMode(state.usesOriginalColor ? .original : .template)
                .font(.system(size: PatchworkIcon.medium, weight: .semibold))
                .foregroundStyle(state.tint)
                .accessibilityLabel(state.accessibilityLabel)
            if let count = ThreadCountBadge.label(for: runningCount) {
                Text(count)
                    .font(PatchworkFont.rowEmphasis.monospacedDigit())
                    .accessibilityLabel(runningCount == 1 ? "1 session running" : "\(runningCount) sessions running")
            }
        }
        .onAppear { ThreadCountBadge.updateDock(doneCount: store.doneSessionCount) }
        .onChange(of: store.doneSessionCount) { _, count in
            ThreadCountBadge.updateDock(doneCount: count)
        }
    }
}

enum MenuBarActivation {
    static func activateMainWindow() {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        let candidate = application.windows.first { window in
            window.canBecomeMain && !(window is NSPanel) && window.contentViewController != nil
        } ?? application.windows.first { $0.canBecomeMain }
        candidate?.makeKeyAndOrderFront(nil)
        candidate?.deminiaturize(nil)
    }
}
