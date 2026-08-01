import Foundation
import PiDeskKit

/// Tracks `POST /v1/threads/{id}/lease` announcements. In-memory only and intentionally so: a
/// lease means "a runtime is attached to this thread right now", which cannot be true across a
/// daemon restart anyway (the app would have to reconnect and re-announce). A default TTL means
/// a crashed holder's lease lapses on its own instead of a thread staying un-schedulable forever.
actor LeaseStore {
    struct RunAdmissionToken: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let thread: ThreadInstanceKey
    }

    struct Lease {
        var owner: String
        var expiresAt: Date
    }

    private var leases: [ThreadInstanceKey: Lease] = [:]
    /// Queue admission crosses an actor hop before the job is visible in `RunQueue`. These
    /// short-lived tokens close that gap so a runtime lease cannot be granted concurrently.
    private var runAdmissions: [ThreadInstanceKey: Set<UUID>] = [:]
    private let defaultTTL: TimeInterval

    init(defaultTTL: TimeInterval = 10 * 60) {
        self.defaultTTL = defaultTTL
    }

    @discardableResult
    func acquire(thread: ThreadInstanceKey, owner: String, ttlSeconds: Int?, now: Date = Date()) -> Lease {
        let ttl = ttlSeconds.map(TimeInterval.init) ?? defaultTTL
        let lease = Lease(owner: owner, expiresAt: now.addingTimeInterval(max(1, ttl)))
        leases[thread] = lease
        return lease
    }

    /// Acquires or renews without stealing another process's live runtime.
    func acquireIfAvailable(thread: ThreadInstanceKey, owner: String, ttlSeconds: Int?, now: Date = Date()) -> Lease? {
        guard runAdmissions[thread]?.isEmpty != false else { return nil }
        if let current = leases[thread], current.expiresAt > now, current.owner != owner { return nil }
        return acquire(thread: thread, owner: owner, ttlSeconds: ttlSeconds, now: now)
    }

    /// Reserves the lease boundary while an existing-thread job becomes visible in `RunQueue`.
    /// Multiple queued messages may reserve the same thread concurrently; a lease waits until
    /// every admission finishes, and the queue's own busy state then takes over.
    func beginRunAdmission(
        thread: ThreadInstanceKey, now: Date = Date()
    ) -> RunAdmissionToken? {
        if let current = leases[thread] {
            if current.expiresAt > now { return nil }
            leases.removeValue(forKey: thread)
        }
        let token = RunAdmissionToken(id: UUID(), thread: thread)
        runAdmissions[thread, default: []].insert(token.id)
        return token
    }

    func endRunAdmission(_ token: RunAdmissionToken) {
        guard runAdmissions[token.thread]?.remove(token.id) != nil else { return }
        if runAdmissions[token.thread]?.isEmpty == true {
            runAdmissions.removeValue(forKey: token.thread)
        }
    }

    func release(thread: ThreadInstanceKey, owner: String) {
        // Only the holder can release its own lease, so an unrelated request cannot evict it.
        guard leases[thread]?.owner == owner else { return }
        leases.removeValue(forKey: thread)
    }

    func isLeased(thread: ThreadInstanceKey, now: Date = Date()) -> Bool {
        guard let lease = leases[thread] else { return false }
        guard lease.expiresAt > now else { leases.removeValue(forKey: thread); return false }
        return true
    }

    func current(thread: ThreadInstanceKey, now: Date = Date()) -> Lease? {
        guard let lease = leases[thread], lease.expiresAt > now else { return nil }
        return lease
    }

    /// Every physical transcript with a currently valid lease, pruning expired ones as a side
    /// effect. The scheduler folds these into its busy snapshot once per tick.
    func leasedThreadKeys(now: Date = Date()) -> Set<ThreadInstanceKey> {
        leases = leases.filter { $0.value.expiresAt > now }
        return Set(leases.keys)
    }
}
