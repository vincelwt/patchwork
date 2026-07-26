import Foundation

/// Bounded in-memory LRU of parsed transcripts, so reselecting a recent conversation reuses the
/// existing parse instead of reading and reprojecting its JSONL again. Never persisted: this is
/// purely a warm-start cache for the current app run.
///
/// A plain lock-protected class, not an `actor`: `AppStore.selectSession` needs a zero-suspension
/// synchronous hit check. An `await` here — even one that resolves immediately — forces at least
/// one SwiftUI render pass to elapse before the cached transcript can be published, which is
/// exactly the empty-then-content flash this cache exists to avoid. Every method below is safe to
/// call from any thread; the lock is only ever held for plain dictionary bookkeeping, never while
/// parsing or computing `estimatedCost`.
///
/// Bounded two ways at once: an entry-count ceiling keeps the bookkeeping itself small, and a
/// byte-cost ceiling (approximate: text length plus already-budgeted image bytes) keeps a
/// handful of image-heavy conversations from ballooning memory the way an unbounded cache would.
/// Either ceiling evicts the least-recently-used entry first.
final class TranscriptCache: @unchecked Sendable {
    static let defaultEntryCapacity = 24
    static let defaultByteCapacity = 96 * 1_024 * 1_024

    private struct Entry {
        let conversation: SessionConversation
        let fingerprint: SessionFileFingerprint
        let cost: Int
    }

    private let entryCapacity: Int
    private let byteCapacity: Int
    private let lock = NSLock()
    private var storage: [String: Entry] = [:]
    /// Least-recently-used first.
    private var recency: [String] = []
    private var totalCost = 0

    /// Capacities are injectable so tests can exercise eviction with tiny bounds instead of
    /// allocating real megabytes; production always uses the defaults above.
    init(entryCapacity: Int = TranscriptCache.defaultEntryCapacity, byteCapacity: Int = TranscriptCache.defaultByteCapacity) {
        self.entryCapacity = entryCapacity
        self.byteCapacity = byteCapacity
    }

    /// A hit requires the fingerprint (size + mtime) to still match what was cached: a
    /// conversation that changed on disk since it was cached (e.g. it kept running in a
    /// terminal) must never be served stale.
    func conversation(for path: String, fingerprint: SessionFileFingerprint) -> SessionConversation? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[path], entry.fingerprint == fingerprint else { return nil }
        touch(path)
        return entry.conversation
    }

    func store(_ conversation: SessionConversation, for path: String, fingerprint: SessionFileFingerprint) {
        // Computed before the lock is taken: on a multi-megabyte conversation this walks every
        // block, and the lock only needs to guard the dictionary mutation itself.
        let cost = Self.estimatedCost(of: conversation)
        lock.lock()
        defer { lock.unlock() }
        if let previous = storage[path] { totalCost -= previous.cost }
        storage[path] = Entry(conversation: conversation, fingerprint: fingerprint, cost: cost)
        totalCost += cost
        touch(path)
        evictIfNeeded()
    }

    func remove(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        if let removed = storage.removeValue(forKey: path) { totalCost -= removed.cost }
        recency.removeAll { $0 == path }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        recency.removeAll()
        totalCost = 0
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[path] != nil
    }

    /// Callers must already hold `lock`.
    private func touch(_ path: String) {
        recency.removeAll { $0 == path }
        recency.append(path)
    }

    /// Callers must already hold `lock`.
    private func evictIfNeeded() {
        while (recency.count > entryCapacity || totalCost > byteCapacity), !recency.isEmpty {
            let stale = recency.removeFirst()
            if let removed = storage.removeValue(forKey: stale) { totalCost -= removed.cost }
        }
    }

    /// Approximate resident size of a parsed conversation: block text/thinking length plus raw
    /// image bytes (already bounded per conversation by `ImageBudget`), with a small flat charge
    /// per structured block so an all-tool-calls conversation is not costed as free.
    static func estimatedCost(of conversation: SessionConversation) -> Int {
        conversation.messages.reduce(0) { total, message in
            total + message.blocks.reduce(0) { blockTotal, block in
                switch block.kind {
                case let .text(text): return blockTotal + text.utf8.count
                case let .thinking(text): return blockTotal + text.utf8.count
                case let .image(image): return blockTotal + image.data.count
                case .toolCall, .unknown: return blockTotal + 256
                }
            }
        }
    }
}
