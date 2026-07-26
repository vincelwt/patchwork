import Foundation
import XCTest
@testable import PiDesktop

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

    func testStoreThenHitReturnsTheSameConversationForAMatchingFingerprint() async throws {
        let cache = TranscriptCache()
        let fp = try fingerprint(name: "a.jsonl")
        let conversation = conversation(id: "a")

        let miss = await cache.conversation(for: "a", fingerprint: fp)
        XCTAssertNil(miss, "Nothing cached yet")
        await cache.store(conversation, for: "a", fingerprint: fp)
        let hit = await cache.conversation(for: "a", fingerprint: fp)
        XCTAssertEqual(hit?.leafID, "a")
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }

    func testStaleFingerprintIsAMissNotStaleData() async throws {
        // The file changed on disk (still running in a terminal) since it was cached: serving
        // the old parse would show the user out-of-date content.
        let cache = TranscriptCache()
        let originalFingerprint = try fingerprint(name: "a.jsonl")
        await cache.store(conversation(id: "a"), for: "a", fingerprint: originalFingerprint)

        try Data("longer content changes size".utf8).write(to: directory.appendingPathComponent("a.jsonl"))
        let values = try directory.appendingPathComponent("a.jsonl").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let changedFingerprint = SessionFileFingerprint(url: directory.appendingPathComponent("a.jsonl"), values: values)

        XCTAssertNotEqual(originalFingerprint, changedFingerprint)
        let staleHit = await cache.conversation(for: "a", fingerprint: changedFingerprint)
        XCTAssertNil(staleHit)
    }

    func testEntryCountCeilingEvictsTheLeastRecentlyUsedEntryFirst() async throws {
        let cache = TranscriptCache(entryCapacity: 2, byteCapacity: .max)
        let fpA = try fingerprint(name: "a.jsonl")
        let fpB = try fingerprint(name: "b.jsonl")
        let fpC = try fingerprint(name: "c.jsonl")

        await cache.store(conversation(id: "a"), for: "a", fingerprint: fpA)
        await cache.store(conversation(id: "b"), for: "b", fingerprint: fpB)
        // A third entry over the cap evicts "a" (the least recently touched), not "b".
        await cache.store(conversation(id: "c"), for: "c", fingerprint: fpC)

        let count = await cache.count
        let hasA = await cache.contains("a")
        let hasB = await cache.contains("b")
        let hasC = await cache.contains("c")
        XCTAssertEqual(count, 2)
        XCTAssertFalse(hasA)
        XCTAssertTrue(hasB)
        XCTAssertTrue(hasC)
    }

    func testTouchingAnEntryProtectsItFromTheNextEviction() async throws {
        let cache = TranscriptCache(entryCapacity: 2, byteCapacity: .max)
        let fpA = try fingerprint(name: "a.jsonl")
        let fpB = try fingerprint(name: "b.jsonl")
        let fpC = try fingerprint(name: "c.jsonl")

        await cache.store(conversation(id: "a"), for: "a", fingerprint: fpA)
        await cache.store(conversation(id: "b"), for: "b", fingerprint: fpB)
        // Re-reading "a" makes it the most recently used, so "b" is evicted instead.
        _ = await cache.conversation(for: "a", fingerprint: fpA)
        await cache.store(conversation(id: "c"), for: "c", fingerprint: fpC)

        let hasA = await cache.contains("a")
        let hasB = await cache.contains("b")
        let hasC = await cache.contains("c")
        XCTAssertTrue(hasA, "Touched entries survive the next eviction")
        XCTAssertFalse(hasB)
        XCTAssertTrue(hasC)
    }

    func testByteCostCeilingEvictsEvenUnderTheEntryCountLimit() async throws {
        // A tiny byte budget forces eviction well before the (generous) entry-count ceiling.
        let cache = TranscriptCache(entryCapacity: 100, byteCapacity: 25)
        let fpA = try fingerprint(name: "a.jsonl")
        let fpB = try fingerprint(name: "b.jsonl")

        await cache.store(conversation(id: "a", textByteCount: 20), for: "a", fingerprint: fpA)
        let hasAInitially = await cache.contains("a")
        XCTAssertTrue(hasAInitially)
        await cache.store(conversation(id: "b", textByteCount: 20), for: "b", fingerprint: fpB)

        let hasA = await cache.contains("a")
        let hasB = await cache.contains("b")
        XCTAssertFalse(hasA, "Over the byte budget: the older entry is evicted")
        XCTAssertTrue(hasB)
    }

    func testRemoveAndRemoveAllDropEntriesAndTheirCost() async throws {
        let cache = TranscriptCache()
        let fpA = try fingerprint(name: "a.jsonl")
        await cache.store(conversation(id: "a", textByteCount: 50), for: "a", fingerprint: fpA)
        await cache.remove("a")
        let hasA = await cache.contains("a")
        XCTAssertFalse(hasA)

        let fpB = try fingerprint(name: "b.jsonl")
        await cache.store(conversation(id: "b"), for: "b", fingerprint: fpB)
        await cache.removeAll()
        let count = await cache.count
        XCTAssertEqual(count, 0)
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
}
