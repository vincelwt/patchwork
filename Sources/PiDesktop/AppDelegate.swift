import AppKit
import Foundation

/// The one place the app's process lifecycle (not `AppStore`'s conversation state) lives.
/// `DaemonSupervisor` needs real `applicationDidFinishLaunching`/`applicationShouldTerminate`
/// hooks — a SwiftUI `.task` on some view fires at the wrong granularity (view identity, not app
/// lifecycle) for "start once at launch, and delay quitting until we've stopped what we started".
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemonSupervisor = DaemonSupervisor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await daemonSupervisor.appDidLaunch() }
    }

    /// Always goes through the async `.terminateLater` path rather than trying to decide up
    /// front whether there is anything to stop: `stopForQuit` is already a fast no-op when this
    /// instance owns nothing (LaunchAgent-managed, externally-started, or never started), so a
    /// second decision point here could only drift out of sync with the one inside it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await daemonSupervisor.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
