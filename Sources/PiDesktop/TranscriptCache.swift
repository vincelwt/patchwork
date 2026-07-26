import Foundation

/// Bounded in-memory LRU of parsed transcripts, so reselecting a recent conversation reuses the
/// existing parse instead of reading and reprojecting its JSONL again. Never persisted: this is
/// purely a warm-start cache for the current app run.
///
/// Bounded two ways at once: an entry-count ceiling keeps the bookkeeping itself small, and a
/// byte-cost ceiling (approximate: text length plus already-budgeted image bytes) keeps a
/// handful of image-heavy conversations from ballooning memory the way an unbounded cache would.
/// Either ceiling evicts the least-recently-used entry first.
actor TranscriptCache {
    static let defaultEntryCapacity = 24
    static let defaultByteCapacity = 96 * 1_024 * 1_024

    private struct Entry {
        let conversation: SessionConversation
        let fingerprint: SessionFileFingerprint
        let cost: Int
    }

    private let entryCapacity: Int
    private let byteCapacity: Int
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
        guard let entry = storage[path], entry.fingerprint == fingerprint else { return nil }
        touch(path)
        return entry.conversation
    }

    func store(_ conversation: SessionConversation, for path: String, fingerprint: SessionFileFingerprint) {
        let cost = Self.estimatedCost(of: conversation)
        if let previous = storage[path] { totalCost -= previous.cost }
        storage[path] = Entry(conversation: conversation, fingerprint: fingerprint, cost: cost)
        totalCost += cost
        touch(path)
        evictIfNeeded()
    }

    func remove(_ path: String) {
        if let removed = storage.removeValue(forKey: path) { totalCost -= removed.cost }
        recency.removeAll { $0 == path }
    }

    func removeAll() {
        storage.removeAll()
        recency.removeAll()
        totalCost = 0
    }

    var count: Int { storage.count }
    func contains(_ path: String) -> Bool { storage[path] != nil }

    private func touch(_ path: String) {
        recency.removeAll { $0 == path }
        recency.append(path)
    }

    private func evictIfNeeded() {
        while (recency.count > entryCapacity || totalCost > byteCapacity), !recency.isEmpty {
            let stale = recency.removeFirst()
            if let removed = storage.removeValue(forKey: stale) { totalCost -= removed.cost }
        }
    }

    /// Approximate resident size of a parsed conversation: block text/thinking length plus raw
    /// image bytes (already bounded per conversation by `ImageBudget`), with a small flat charge
    /// per structured block so an all-tool-calls conversation is not costed as free.
    nonisolated static func estimatedCost(of conversation: SessionConversation) -> Int {
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
