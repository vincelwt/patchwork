import Foundation
import PatchworkKit

/// Publishes changes from terminal and app heartbeat files to connected remote clients. The
/// observed timestamp is deliberately excluded from the comparison so an idle system emits no
/// traffic merely because another poll completed.
actor ActivityPublisher {
    private struct Signature: Equatable {
        var running: [RunningThread]
        var unreadCount: Int
    }

    private let bus: EventBus
    private let intervalNanoseconds: UInt64
    private let snapshot: @Sendable () async -> ActivitySnapshot
    private var task: Task<Void, Never>?
    private var lastSignature: Signature?

    init(
        bus: EventBus,
        interval: TimeInterval = 2,
        snapshot: @escaping @Sendable () async -> ActivitySnapshot
    ) {
        self.bus = bus
        intervalNanoseconds = UInt64(max(0.05, interval) * 1_000_000_000)
        self.snapshot = snapshot
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() async {
        let runningTask = task
        task = nil
        runningTask?.cancel()
        await runningTask?.value
        lastSignature = nil
    }

    @discardableResult
    func publishIfChanged() async -> Bool {
        let value = await snapshot()
        let signature = Signature(
            running: value.running.sorted(by: Self.activityOrder),
            unreadCount: value.unreadCount
        )
        guard signature != lastSignature else { return false }
        lastSignature = signature
        bus.publish(.activity(value))
        return true
    }

    private func run() async {
        while !Task.isCancelled {
            if bus.subscriberCount > 0 { _ = await publishIfChanged() }
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private static func activityOrder(_ lhs: RunningThread, _ rhs: RunningThread) -> Bool {
        let left = [lhs.threadPath ?? "", lhs.threadId, lhs.source.rawValue, lhs.since.ISO8601Format()]
        let right = [rhs.threadPath ?? "", rhs.threadId, rhs.source.rawValue, rhs.since.ISO8601Format()]
        return left.lexicographicallyPrecedes(right)
    }
}
