import Foundation
import PatchworkKit

/// Fan-out for `GET /v1/events`. Publishing never blocks on a slow subscriber: each subscriber
/// gets its own serial queue and a bounded backlog, so one stalled SSE connection (a laptop that
/// slept mid-stream, a web remote over a bad tunnel) cannot stall a route handler that just
/// mutated state and is publishing the result, and cannot grow memory without bound either.
final class EventBus: @unchecked Sendable {
    private final class Subscription: @unchecked Sendable {
        let queue = DispatchQueue(label: "app.patchwork.desktop.daemon.sse")
        let deliver: (String, Data) -> Void
        private let lock = NSLock()
        private var pending = 0
        private var overflowed = false
        private let maxPending: Int
        private let onOverflow: () -> Void

        init(maxPending: Int, onOverflow: @escaping () -> Void, deliver: @escaping (String, Data) -> Void) {
            self.maxPending = maxPending
            self.onOverflow = onOverflow
            self.deliver = deliver
        }

        func enqueue(name: String, payload: Data) {
            lock.lock()
            guard !overflowed else { lock.unlock(); return }
            guard pending < maxPending else {
                overflowed = true
                lock.unlock()
                onOverflow()
                return
            }
            pending += 1
            lock.unlock()
            queue.async { [weak self] in
                self?.deliver(name, payload)
                guard let self else { return }
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
            }
        }
    }

    private let lock = NSLock()
    private var subscriptions: [UUID: Subscription] = [:]
    private let maxPendingPerSubscriber: Int
    private let logger: DaemonLogger?

    init(maxPendingPerSubscriber: Int = 256, logger: DaemonLogger? = nil) {
        self.maxPendingPerSubscriber = maxPendingPerSubscriber
        self.logger = logger
    }

    @discardableResult
    func subscribe(
        initialName: String? = nil,
        initialPayload: Data = Data(),
        onOverflow: @escaping () -> Void = {},
        _ deliver: @escaping (String, Data) -> Void
    ) -> UUID {
        let id = UUID()
        let subscription = Subscription(
            maxPending: maxPendingPerSubscriber,
            onOverflow: onOverflow,
            deliver: deliver
        )
        lock.lock()
        subscriptions[id] = subscription
        if let initialName { subscription.enqueue(name: initialName, payload: initialPayload) }
        lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock(); subscriptions.removeValue(forKey: id); lock.unlock()
    }

    func publish(_ event: PatchworkEvent) {
        let payload: Data
        switch event {
        case let .thread(value): payload = (try? PatchworkJSON.encoder.encode(value)) ?? Data()
        case let .activity(value): payload = (try? PatchworkJSON.encoder.encode(value)) ?? Data()
        case let .run(value): payload = (try? PatchworkJSON.encoder.encode(value)) ?? Data()
        case let .schedule(value): payload = (try? PatchworkJSON.encoder.encode(value)) ?? Data()
        case let .interaction(value): payload = (try? PatchworkJSON.encoder.encode(value)) ?? Data()
        case let .unknown(_, data): payload = (try? PatchworkJSON.encoder.encode(data)) ?? Data()
        }
        guard !payload.isEmpty else { return }
        lock.lock(); let subs = subscriptions; lock.unlock()
        for subscription in subs.values { subscription.enqueue(name: event.name, payload: payload) }
    }

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscriptions.count }
}
