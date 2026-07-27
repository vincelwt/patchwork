import Foundation
import PiDeskKit

/// Fan-out for `GET /v1/events`. Publishing never blocks on a slow subscriber: each subscriber
/// gets its own serial queue and a bounded backlog, so one stalled SSE connection (a laptop that
/// slept mid-stream, a web remote over a bad tunnel) cannot stall a route handler that just
/// mutated state and is publishing the result, and cannot grow memory without bound either.
final class EventBus: @unchecked Sendable {
    private final class Subscription: @unchecked Sendable {
        let queue = DispatchQueue(label: "dev.pi.desktop.daemon.sse")
        let deliver: (String, Data) -> Void
        private let lock = NSLock()
        private var pending = 0
        private let maxPending: Int

        init(maxPending: Int, deliver: @escaping (String, Data) -> Void) {
            self.maxPending = maxPending
            self.deliver = deliver
        }

        func enqueue(name: String, payload: Data) {
            lock.lock()
            guard pending < maxPending else { lock.unlock(); return }
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
    func subscribe(_ deliver: @escaping (String, Data) -> Void) -> UUID {
        let id = UUID()
        let subscription = Subscription(maxPending: maxPendingPerSubscriber, deliver: deliver)
        lock.lock(); subscriptions[id] = subscription; lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock(); subscriptions.removeValue(forKey: id); lock.unlock()
    }

    func publish(_ event: PiDeskEvent) {
        let payload: Data
        switch event {
        case let .thread(value): payload = (try? PiDeskJSON.encoder.encode(value)) ?? Data()
        case let .activity(value): payload = (try? PiDeskJSON.encoder.encode(value)) ?? Data()
        case let .run(value): payload = (try? PiDeskJSON.encoder.encode(value)) ?? Data()
        case let .schedule(value): payload = (try? PiDeskJSON.encoder.encode(value)) ?? Data()
        case let .interaction(value): payload = (try? PiDeskJSON.encoder.encode(value)) ?? Data()
        case let .unknown(_, data): payload = (try? PiDeskJSON.encoder.encode(data)) ?? Data()
        }
        guard !payload.isEmpty else { return }
        lock.lock(); let subs = subscriptions; lock.unlock()
        for subscription in subs.values { subscription.enqueue(name: event.name, payload: payload) }
    }

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscriptions.count }
}
