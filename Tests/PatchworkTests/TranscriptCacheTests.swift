import Foundation
import XCTest
@testable import Patchwork

final class TranscriptCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiTranscriptCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real file's fingerprint: `SessionFileFingerprint` only has an `init(url:values:)`, so
    /// tests derive one the same way production code does rather than hand-constructing one.
    private func fingerprint(name: String) throws -> SessionFileFingerprint {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SessionFileFingerprint(url: url, values: values)
    }

    private func conversation(id: String, textByteCount: Int = 1) -> SessionConversation {
        let text = String(repeating: "a", count: textByteCount)
        let message = ChatMessage(
            id: id, role: .assistant, blocks: [MessageBlock(id: "\(id)-b", kind: .text(text))],
            timestamp: nil, raw: .null
        )
        return SessionConversation(messages: [message], leafID: id, rawEntryCount: 1)
    }

    func testStoreThenHitReturnsTheSameConversationForAMatchingFingerprint() throws {
        let cache = TranscriptCache()
        let fp = try fingerprint(name: "a.jsonl")
        let conversation = conversation(id: "a")

        let miss = cache.conversation(for: "a", fingerprint: fp)
        XCTAssertNil(miss, "Nothing cached yet")
        cache.store(conversation, for: "a", fingerprint: fp)
        let hit = cache.conversation(for: "a", fingerprint: fp)
        XCTAssertEqual(hit?.leafID, "a")
        XCTAssertEqual(cache.count, 1)
    }

    /// The whole point of Task 1's fast path: a hit never needs `await` to resolve, so
    /// `AppStore.selectSession` can check it inline before publishing any loading state.
    func testConversationLookupIsSynchronousNotAsync() throws {
        let cache = TranscriptCache()
        let fp = try fingerprint(name: "sync.jsonl")
        cache.store(conversation(id: "sync"), for: "sync", fingerprint: fp)
        let hit: SessionConversation? = cache.conversation(for: "sync", fingerprint: fp) // no `await`
        XCTAssertEqual(hit?.leafID, "sync")
    }

    func testPagedWindowKeepsItsOlderCursor() throws {
        let url = directory.appendingPathComponent("paged.jsonl")
        try Data("""
        {"type":"session","id":"paged"}
        {"type":"message","id":"one","parentId":null,"message":{"role":"user","content":"one"}}
        {"type":"message","id":"two","parentId":"one","message":{"role":"assistant","content":"two"}}

        """.utf8).write(to: url)
        let page = try SessionParser.conversationPage(at: url, target: 1, alignToTurnBoundary: false)
        let fp = try SessionFileFingerprint(
            url: url,
            values: url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        )
        let cache = TranscriptCache()

        cache.store(page, for: url.path, fingerprint: fp)

        let hit = try XCTUnwrap(cache.page(for: url.path, fingerprint: fp))
        XCTAssertEqual(hit.messages.map(\.id), ["two"])
        XCTAssertEqual(hit.olderCursor, page.olderCursor)
    }

    func testStaleFingerprintIsAMissNotStaleData() throws {
        // The file changed on disk (still running in a terminal) since it was cached: serving
        // the old parse would show the user out-of-date content.
        let cache = TranscriptCache()
        let originalFingerprint = try fingerprint(name: "a.jsonl")
        cache.store(conversation(id: "a"), for: "a", fingerprint: originalFingerprint)

        try Data("longer content changes size".utf8).write(to: directory.appendingPathComponent("a.jsonl"))
        let values = try directory.appendingPathComponent("a.jsonl").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let changedFingerprint = SessionFileFingerprint(url: directory.appendingPathComponent("a.jsonl"), values: values)

        XCTAssertNotEqual(originalFingerprint, changedFingerprint)
        let staleHit = cache.conversation(for: "a", fingerprint: changedFingerprint)
        XCTAssertNil(staleHit)
    }

    func testEntryCountCeilingEvictsTheLeastRecentlyUsedEntryFirst() throws {
        let cache = TranscriptCache(entryCapacity: 2, byteCapacity: .max)
        let fpA = try fingerprint(name: "a.jsonl")
        let fpB = try fingerprint(name: "b.jsonl")
        let fpC = try fingerprint(name: "c.jsonl")

        cache.store(conversation(id: "a"), for: "a", fingerprint: fpA)
        cache.store(conversation(id: "b"), for: "b", fingerprint: fpB)
        // A third entry over the cap evicts "a" (the least recently touched), not "b".
        cache.store(conversation(id: "c"), for: "c", fingerprint: fpC)

        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }

    func testTouchingAnEntryProtectsItFromTheNextEviction() throws {
        let cache = TranscriptCache(entryCapacity: 2, byteCapacity: .max)
        let fpA = try fingerprint(name: "a.jsonl")
        let fpB = try fingerprint(name: "b.jsonl")
        let fpC = try fingerprint(name: "c.jsonl")

        cache.store(conversation(id: "a"), for: "a", fingerprint: fpA)
        cache.store(conversation(id: "b"), for: "b", fingerprint: fpB)
        // Re-reading "a" makes it the most recently used, so "b" is evicted instead.
        _ = cache.conversation(for: "a", fingerprint: fpA)
        cache.store(conversation(id: "c"), for: "c", fingerprint: fpC)

        XCTAssertTrue(cache.contains("a"), "Touched entries survive the next eviction")
        XCTAssertFalse(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }

    func testByteCostCeilingEvictsEvenUnderTheEntryCountLimit() throws {
        // A tiny byte budget forces eviction well before the (generous) entry-count ceiling.
        let cache = TranscriptCache(entryCapacity: 100, byteCapacity: 25)
        let fpA = try fingerprint(name: "a.jsonl")
        let fpB = try fingerprint(name: "b.jsonl")

        cache.store(conversation(id: "a", textByteCount: 20), for: "a", fingerprint: fpA)
        XCTAssertTrue(cache.contains("a"))
        cache.store(conversation(id: "b", textByteCount: 20), for: "b", fingerprint: fpB)

        XCTAssertFalse(cache.contains("a"), "Over the byte budget: the older entry is evicted")
        XCTAssertTrue(cache.contains("b"))
    }

    func testRemoveAndRemoveAllDropEntriesAndTheirCost() throws {
        let cache = TranscriptCache()
        let fpA = try fingerprint(name: "a.jsonl")
        cache.store(conversation(id: "a", textByteCount: 50), for: "a", fingerprint: fpA)
        cache.remove("a")
        XCTAssertFalse(cache.contains("a"))

        let fpB = try fingerprint(name: "b.jsonl")
        cache.store(conversation(id: "b"), for: "b", fingerprint: fpB)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testEstimatedCostSumsTextAndImageBytesPlusAFlatChargeForStructuredBlocks() {
        let text = ChatMessage(id: "m1", role: .assistant, blocks: [MessageBlock(id: "b1", kind: .text("12345"))], timestamp: nil, raw: .null)
        let image = ChatMessage(
            id: "m2", role: .user,
            blocks: [MessageBlock(id: "b2", kind: .image(ImagePayload(id: "i1", data: Data(count: 100), mimeType: "image/png", fileName: nil)))],
            timestamp: nil, raw: .null
        )
        let conversation = SessionConversation(messages: [text, image], leafID: "m2", rawEntryCount: 2)
        XCTAssertEqual(TranscriptCache.estimatedCost(of: conversation), 5 + 100)
    }

    /// Concurrent readers/writers (main-actor selection reads, background prefetch writes) must
    /// never corrupt the LRU bookkeeping now that it is lock-based instead of actor-isolated.
    /// Values are precomputed and captured by the task closures instead of `self`, since a
    /// `@Sendable` closure cannot capture the (non-`Sendable`) test case.
    func testConcurrentStoresFromMultipleThreadsNeverCorruptBookkeeping() async throws {
        let cache = TranscriptCache(entryCapacity: 8, byteCapacity: .max)
        let fingerprints = try (0..<8).map { try fingerprint(name: "p\($0).jsonl") }
        let conversations = (0..<8).map { conversation(id: "p\($0)") }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                let slot = index % 8
                let fp = fingerprints[slot]
                let convo = conversations[slot]
                group.addTask {
                    cache.store(convo, for: "p\(slot)", fingerprint: fp)
                    _ = cache.conversation(for: "p\(slot)", fingerprint: fp)
                }
            }
        }
        XCTAssertLessThanOrEqual(cache.count, 8)
    }
}
