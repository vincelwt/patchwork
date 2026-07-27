import Foundation
import Network

/// One native path observer for the app lifetime. Pi still classifies the provider failure;
/// path status only tells Desktop when to pause that retry and when it is worth continuing.
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.pi.desktop.connectivity")
    private var started = false

    func start(_ update: @escaping @Sendable (Bool) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in update(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
