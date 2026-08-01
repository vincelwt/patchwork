import Foundation

/// One app-owned macOS sleep hold, shared by every running conversation.
///
/// `ProcessInfo` covers ordinary idle/display sleep without a child process. The lease keeps the
/// already-installed closed-lid companion informed; it is intentionally silent and optional, so
/// a lease write failure never turns into notification spam or disables the native assertion.
@MainActor
final class SleepPreventionController {
    static let heartbeatInterval: TimeInterval = 5

    private let leaseURL: URL
    private let leaseQueue = DispatchQueue(label: "app.patchwork.desktop.sleep-lease", qos: .utility)
    private var activity: NSObjectProtocol?
    private var heartbeat: DispatchSourceTimer?

    init(leaseURL: URL = SleepPreventionController.defaultLeaseURL()) {
        self.leaseURL = leaseURL
    }

    static func liveHandler() -> SleepPreventionHandler {
        let controller = SleepPreventionController()
        return { controller.setActive($0) }
    }

    func setActive(_ active: Bool) {
        guard active != (activity != nil) else { return }
        if active {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "A Pi thread is running"
            )
            leaseQueue.sync { Self.refreshLease(at: leaseURL) }
            let timer = DispatchSource.makeTimerSource(queue: leaseQueue)
            timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
            timer.setEventHandler { [leaseURL] in Self.refreshLease(at: leaseURL) }
            heartbeat = timer
            timer.resume()
        } else {
            heartbeat?.cancel()
            heartbeat = nil
            // The serial queue makes this removal happen after any heartbeat already in flight,
            // so stopping cannot resurrect the lease that it just removed.
            leaseQueue.sync { try? FileManager.default.removeItem(at: leaseURL) }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    nonisolated static func defaultLeaseURL(
        fileManager: FileManager = .default,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/pi-caffeinate/leases", isDirectory: true)
            .appendingPathComponent("\(processID).lease", isDirectory: false)
    }

    private nonisolated static func refreshLease(at url: URL, fileManager: FileManager = .default) {
        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            let pid = ProcessInfo.processInfo.processIdentifier
            try Data("{\"pid\":\(pid),\"updatedAt\":\(milliseconds)}\n".utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Native sleep prevention remains active. The root companion expires a missing lease
            // on its own, so there is nothing useful—or user-actionable—to notify here.
        }
    }
}

typealias SleepPreventionHandler = @MainActor (_ active: Bool) -> Void
