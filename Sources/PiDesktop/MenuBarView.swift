import AppKit
import SwiftUI

/// Reuses the shared activity monitor; the menu bar never starts its own timer or file poll.
struct MenuBarContentView: View {
    @EnvironmentObject private var store: AppStore
    private var running: [SessionSummary] { store.runningSessions }
    private var account: CodexAccountStatus? { store.statusModel.codexAccount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PiTheme.space8) {
                if !running.isEmpty { ProgressView().controlSize(.small) }
                Text(runningTitle).font(PiFont.rowEmphasis)
                Spacer()
                Text("Pi Desktop").font(PiFont.micro).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PiTheme.space12)
            .frame(height: 38)

            PiHairline()

            if running.isEmpty {
                Text("No sessions running")
                    .font(PiFont.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, PiTheme.space12)
                    .frame(height: 32)
            } else {
                ScrollView {
                    VStack(spacing: PiTheme.space2) {
                        ForEach(running.prefix(12)) { session in
                            RunningSessionRow(session: session)
                        }
                        if running.count > 12 {
                            Text("\(running.count - 12) more running")
                                .font(PiFont.micro).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(PiTheme.space4)
                }
                .frame(maxHeight: 12 * 40)
            }

            PiHairline()
            // The same all-account `/limits` report the main window's account chip shows on
            // hover — cached instantly, refreshed periodically in the background by
            // `LimitsReportStore`, never fetched directly by this view.
            ScrollView { LimitsPopoverView(fallback: account) }
                .frame(maxHeight: 320)
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
                ProgressView().controlSize(.mini)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(PiFont.row).lineLimit(1).truncationMode(.tail)
                    Text("\(store.displayFolderName(for: session)) \u{b7} \(state)")
                        .font(PiFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: 38)
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
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(title).font(PiFont.row).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, PiTheme.space8)
            .frame(height: 27)
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

struct MenuBarLabelView: View {
    @EnvironmentObject private var store: AppStore

    private var unreadCount: Int {
        store.sessions.filter { !$0.isArchived && store.isUnread($0) }.count
    }

    private var state: MenuBarCircleState {
        MenuBarCircleState.resolve(runningCount: store.runningSessions.count, unreadCount: unreadCount)
    }

    var body: some View {
        Image(systemName: state.symbolName)
            .renderingMode(state.usesOriginalColor ? .original : .template)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(state.tint)
            .accessibilityLabel(state.accessibilityLabel)
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
