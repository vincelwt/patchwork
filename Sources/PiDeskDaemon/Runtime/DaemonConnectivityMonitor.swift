import Foundation
import Network

/// A prompt always needs a provider path. Keep durable occurrences pending while macOS knows the
/// laptop is offline, so Pi never accepts a prompt that is guaranteed to fail moments later.
final class DaemonConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.pi.desktop.daemon.connectivity")
    private let lock = NSLock()
    private var online = false

    var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock(); online = path.status == .satisfied; lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
