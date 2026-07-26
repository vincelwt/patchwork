import Foundation
import PiDeskKit

/// Tracks `POST /v1/threads/{id}/lease` announcements. In-memory only and intentionally so: a
/// lease means "a runtime is attached to this thread right now", which cannot be true across a
/// daemon restart anyway (the app would have to reconnect and re-announce). A default TTL means
/// a crashed holder's lease lapses on its own instead of a thread staying un-schedulable forever.
actor LeaseStore {
    struct Lease {
        var owner: String
        var expiresAt: Date
    }

    private var leases: [String: Lease] = [:]
    private let defaultTTL: TimeInterval

    init(defaultTTL: TimeInterval = 10 * 60) {
        self.defaultTTL = defaultTTL
    }

    @discardableResult
    func acquire(threadId: String, owner: String, ttlSeconds: Int?, now: Date = Date()) -> Lease {
        let ttl = ttlSeconds.map(TimeInterval.init) ?? defaultTTL
        let lease = Lease(owner: owner, expiresAt: now.addingTimeInterval(max(1, ttl)))
        leases[threadId] = lease
        return lease
    }

    func release(threadId: String, owner: String) {
        // Only the holder can release its own lease, so an unrelated request cannot evict it.
        guard leases[threadId]?.owner == owner else { return }
        leases.removeValue(forKey: threadId)
    }

    func isLeased(threadId: String, now: Date = Date()) -> Bool {
        guard let lease = leases[threadId] else { return false }
        guard lease.expiresAt > now else { leases.removeValue(forKey: threadId); return false }
        return true
    }

    func current(threadId: String, now: Date = Date()) -> Lease? {
        guard let lease = leases[threadId], lease.expiresAt > now else { return nil }
        return lease
    }

    /// Every thread id with a currently-valid lease, pruning expired ones as a side effect —
    /// used by the scheduler to fold "leased" into "busy" for a whole tick at once instead of
    /// checking one thread at a time.
    func leasedThreadIDs(now: Date = Date()) -> Set<String> {
        leases = leases.filter { $0.value.expiresAt > now }
        return Set(leases.keys)
    }
}
