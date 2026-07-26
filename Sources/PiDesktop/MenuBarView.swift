import AppKit
import SwiftUI

/// The menu bar list of currently running threads. It reuses the same `SessionActivityMonitor`
/// as the sidebar, so nothing extra is polled or timed for this scene.
struct MenuBarContentView: View {
    @EnvironmentObject private var store: AppStore

    private var running: [SessionSummary] { store.runningSessions }

    var body: some View {
        Group {
            if running.isEmpty {
                Text("No sessions running")
                Divider()
            } else {
                ForEach(running.prefix(12)) { session in
                    Button {
                        activate(session)
                    } label: {
                        Text(label(for: session))
                    }
                }
                if running.count > 12 {
                    Text("\(running.count - 12) more…")
                }
                Divider()
            }

            Button("Open Pi Desktop") { MenuBarActivation.activateMainWindow() }
            Button("New Chat") {
                MenuBarActivation.activateMainWindow()
                store.openNewChat()
            }
            Button("Refresh Sessions") { Task { await store.refreshSessions() } }
            Divider()
            Button("Quit Pi Desktop") { NSApplication.shared.terminate(nil) }
        }
    }

    /// `folder · title · elapsed/state`
    private func label(for session: SessionSummary) -> String {
        let elapsed = store.runningSince(session).map { NumberFormatting.elapsed(since: $0) }
        let state = elapsed.map { "working \($0)" } ?? "working"
        return "\(session.folderName) · \(session.displayName.prefix(38)) · \(state)"
    }

    private func activate(_ session: SessionSummary) {
        MenuBarActivation.activateMainWindow()
        store.selectSession(session)
    }
}

/// The label shown in the menu bar itself: a count badge only while something is running.
struct MenuBarLabelView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let count = store.runningSessions.count
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "circle.fill" : "circle")
            if count > 0 { Text("\(count)") }
        }
        .accessibilityLabel(count == 0 ? "Pi Desktop, nothing running" : "Pi Desktop, \(count) running")
    }
}

enum MenuBarActivation {
    /// Brings the main window forward without creating a second one.
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
