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
                            Button { activate(session) } label: {
                                HStack(spacing: PiTheme.space8) {
                                    ProgressView().controlSize(.mini)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(session.displayName)
                                            .font(PiFont.row).lineLimit(1).truncationMode(.tail)
                                        Text("\(store.displayFolderName(for: session)) · \(state(for: session))")
                                            .font(PiFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, PiTheme.space8)
                                .frame(height: 38)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
            accountSection
            PiHairline()

            VStack(spacing: PiTheme.space2) {
                menuButton("Open Pi Desktop", symbol: "macwindow") { MenuBarActivation.activateMainWindow() }
                menuButton("New Chat", symbol: "square.and.pencil") {
                    MenuBarActivation.activateMainWindow(); store.openNewChat()
                }
                menuButton("New Virtual Folder…", symbol: "folder.badge.plus") {
                    MenuBarActivation.activateMainWindow(); store.newVirtualFolderRequested = true
                }
                menuButton("Refresh Sessions", symbol: "arrow.clockwise") { Task { await store.refreshSessions() } }
                menuButton("Quit Pi Desktop", symbol: "power") { NSApplication.shared.terminate(nil) }
            }
            .padding(PiTheme.space4)
        }
        .frame(width: PiTheme.menuBarWidth)
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: PiTheme.space4) {
            HStack {
                Text("ACCOUNT LIMITS").font(PiFont.micro.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer()
                if !store.statusModel.isLive {
                    Text(account == nil ? "unknown" : "cached").font(PiFont.micro).foregroundStyle(.tertiary)
                }
            }
            if let account {
                Text(account.account).font(PiFont.caption).lineLimit(1).truncationMode(.middle)
                Text(account.compactUsage ?? "Usage windows unavailable")
                    .font(PiFont.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Text("Account limits unavailable")
                    .font(PiFont.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, PiTheme.space12)
        .padding(.vertical, PiTheme.space8)
    }

    private var runningTitle: String {
        running.isEmpty ? "Ready" : "\(running.count) running"
    }

    private func state(for session: SessionSummary) -> String {
        store.runningSince(session).map { "working \(NumberFormatting.elapsed(since: $0))" } ?? "working"
    }

    private func menuButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
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
        }
        .buttonStyle(.plain)
    }

    private func activate(_ session: SessionSummary) {
        MenuBarActivation.activateMainWindow()
        store.selectSession(session)
    }
}

struct MenuBarLabelView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let count = store.runningSessions.count
        HStack(spacing: 3) {
            if count > 0 { ProgressView().controlSize(.mini) }
            else { Image(systemName: "circle") }
            if count > 0 { Text("\(count)") }
        }
        .accessibilityLabel(count == 0 ? "Pi Desktop, nothing running" : "Pi Desktop, \(count) running")
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
