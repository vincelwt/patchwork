import AppKit
import Foundation

/// The one place the app process and its in-process control service share a lifecycle. A SwiftUI
/// view task fires at view granularity, not the launch/quit boundary this service must follow.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemonSupervisor = DaemonSupervisor()
    private var serviceLaunchTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        serviceLaunchTask = Task { await daemonSupervisor.appDidLaunch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let launch = serviceLaunchTask
        Task {
            await launch?.value
            await daemonSupervisor.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
