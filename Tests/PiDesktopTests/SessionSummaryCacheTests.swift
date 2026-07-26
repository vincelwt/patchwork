import Foundation
import XCTest
@testable import PiDesktop

final class SessionSummaryCacheTests: XCTestCase {
    func testWarmHitInvalidationAndPruning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopCache-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("--project--", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = project.appendingPathComponent("session.jsonl")
        try fixture().write(to: session)
        let cacheURL = root.appendingPathComponent("cache.json")
        let cache = SessionSummaryCache(fileURL: cacheURL)
        let repository = FileSessionRepository(rootURL: root, summaryCache: cache)

        let cold = try await repository.discoverSessions(archivedIDs: [])
        XCTAssertEqual(cold.count, 1)
        let coldMisses = await cache.missCount
        XCTAssertEqual(coldMisses, 1)

        let warm = try await repository.discoverSessions(archivedIDs: ["cache-session"])
        XCTAssertEqual(warm.first?.isArchived, true, "Archive flags are applied after lookup")
        let warmHits = await cache.hitCount
        XCTAssertEqual(warmHits, 1)

        let persisted = SessionSummaryCache(fileURL: cacheURL)
        _ = try await FileSessionRepository(rootURL: root, summaryCache: persisted).discoverSessions(archivedIDs: [])
        let persistedHits = await persisted.hitCount
        XCTAssertEqual(persistedHits, 1, "A new cache instance should hit the atomically persisted entry")

        var changed = try Data(contentsOf: session)
        changed.append(Data("{\"type\":\"label\",\"id\":\"later\",\"parentId\":\"user\"}\n".utf8))
        try changed.write(to: session, options: .atomic)
        _ = try await FileSessionRepository(rootURL: root, summaryCache: persisted).discoverSessions(archivedIDs: [])
        let invalidationMisses = await persisted.missCount
        XCTAssertGreaterThanOrEqual(invalidationMisses, 1, "Size/mtime changes invalidate the entry")

        try FileManager.default.removeItem(at: session)
        let pruned = await persisted.pruneMissingFiles()
        let remaining = await persisted.count()
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(remaining, 0)
    }

    private func fixture() throws -> Data {
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "cache-session", "timestamp": "2026-01-01T12:00:00.000Z", "cwd": "/tmp/project"],
            ["type": "message", "id": "user", "parentId": NSNull(), "message": ["role": "user", "content": "Cached prompt"]]
        ]
        return try lines.reduce(into: Data()) { data, line in
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
    }
}
