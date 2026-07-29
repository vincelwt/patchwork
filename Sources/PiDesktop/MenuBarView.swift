import AppKit
import SwiftUI

/// Budgets the panel's two scrollable regions so account limits and actions stay on-screen.
enum MenuBarPanelLayout {
    static let sessionDisplayLimit = 50

    static var availableScreenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? PiTheme.menuBarFallbackScreenHeight
    }

    static func heights(availableHeight: CGFloat) -> (sessions: CGFloat, limits: CGFloat) {
        let budget = max(0, availableHeight - PiTheme.menuBarScreenMargin - PiTheme.menuBarFixedHeight)
        let limits = min(
            PiTheme.menuBarLimitsIdealHeight,
            max(min(PiTheme.menuBarLimitsMinHeight, budget), budget - PiTheme.menuBarSessionsMinHeight)
        )
        let sessions = min(PiTheme.menuBarSessionsIdealHeight, max(0, budget - limits))
        return (sessions, limits)
    }

    static func sessionHeight(count: Int, maxHeight: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = min(count, sessionDisplayLimit)
        let contentHeight = CGFloat(rows) * PiTheme.menuBarSessionRowHeight
            + CGFloat(rows - 1) * PiTheme.space2
            + 2 * PiTheme.space4
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
    private var sessionHeight: CGFloat {
        MenuBarPanelLayout.sessionHeight(count: running.count, maxHeight: heights.sessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PiTheme.space8) {
                if !running.isEmpty { StatusDot(color: .piGreen, pulsing: true) }
                Text(runningTitle).font(PiFont.rowEmphasis)
                Spacer()
                Text("Pi Desktop").font(PiFont.micro).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PiTheme.space12)
            .frame(height: PiTheme.menuBarHeaderHeight)

            PiHairline()

            if running.isEmpty {
                Text("No sessions running")
                    .font(PiFont.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, PiTheme.space12)
                    .frame(height: PiTheme.menuBarEmptyStateHeight)
            } else {
                ScrollView {
                    VStack(spacing: PiTheme.space2) {
                        ForEach(running.prefix(MenuBarPanelLayout.sessionDisplayLimit)) { session in
                            RunningSessionRow(session: session)
                        }
                        if running.count > MenuBarPanelLayout.sessionDisplayLimit {
                            Text("\(running.count - MenuBarPanelLayout.sessionDisplayLimit) more running")
                                .font(PiFont.micro).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(PiTheme.space4)
                }
                .frame(height: sessionHeight)
            }

            PiHairline()
            // The same all-account `/limits` report the main window's account chip shows on
            // hover — cached instantly, refreshed periodically in the background by
            // `LimitsReportStore`, never fetched directly by this view.
            ScrollView { LimitsPopoverView(fallback: account) }
                .frame(height: heights.limits)
            PiHairline()

            VStack(spacing: PiTheme.space2) {
                MenuBarActionRow(title: "New Chat", symbol: "square.and.pencil") {
                    MenuBarActivation.activateMainWindow(); store.openNewChat()
                }
                MenuBarActionRow(title: "Quit Pi Desktop", symbol: "power") { NSApplication.shared.terminate(nil) }
            }
            .padding(PiTheme.space4)
        }
        .frame(width: PiTheme.menuBarWidth)
        .onAppear { MenuBarPanelLayout.anchorPanelToClick() }
    }

    private var runningTitle: String {
        running.isEmpty ? "Ready" : "\(running.count) running"
    }
}

/// One running-session row with real hover feedback (previously none) and a click that brings
/// the conversation on screen, matching every other row list in the app.
private struct RunningSessionRow: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionSummary
    @State private var hovering = false

    var body: some View {
        Button { activate() } label: {
            HStack(spacing: PiTheme.space8) {
                StatusDot(color: .piGreen, pulsing: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(PiFont.row).lineLimit(1).truncationMode(.tail)
                    Text("\(store.displayFolderName(for: session)) \u{b7} \(state)")
                        .font(PiFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: PiTheme.menuBarSessionRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: false, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var state: String {
        store.runningSince(session).map { "working \(NumberFormatting.elapsed(since: $0))" } ?? "working"
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
            HStack(spacing: PiTheme.space8) {
                Image(systemName: symbol).frame(width: PiTheme.gridIconColumn)
                    .font(.system(size: PiIcon.small)).foregroundStyle(.secondary)
                Text(title).font(PiFont.row).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: PiTheme.menuBarActionRowHeight)
            .contentShape(Rectangle())
            .piRowBackground(selected: false, hovering: hovering)
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
        case .running: return .piGreen
        case .unread: return .piBlue
        case .idle: return .primary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .running: return "Pi Desktop, sessions running"
        case .unread: return "Pi Desktop, unread sessions"
        case .idle: return "Pi Desktop, idle"
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
        HStack(spacing: PiTheme.space4) {
            Image(systemName: state.symbolName)
                .renderingMode(state.usesOriginalColor ? .original : .template)
                .font(.system(size: PiIcon.medium, weight: .semibold))
                .foregroundStyle(state.tint)
                .accessibilityLabel(state.accessibilityLabel)
            if let count = ThreadCountBadge.label(for: runningCount) {
                Text(count)
                    .font(PiFont.rowEmphasis.monospacedDigit())
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
