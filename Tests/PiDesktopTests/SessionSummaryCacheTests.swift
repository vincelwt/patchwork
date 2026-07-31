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

    func testOneVersionOldCachePaintsImmediatelyThenReparsesForTheNewMetadata() async throws {
        struct LegacyEntry: Encodable {
            let fingerprint: SessionFileFingerprint
            let summary: SessionSummary
        }
        struct LegacyEnvelope: Encodable {
            let version: Int
            let entries: [String: LegacyEntry]
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopCacheMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try fixture().write(to: file)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = SessionFileFingerprint(url: file, values: values)
        var summary = try SessionParser.summary(at: file)
        let legacy = LegacyEnvelope(
            version: 5,
            entries: [file.standardizedFileURL.path: LegacyEntry(fingerprint: fingerprint, summary: summary)]
        )
        try JSONEncoder().encode(legacy).write(
            to: root.appendingPathComponent("session-summaries-v5.json"), options: .atomic
        )

        let currentURL = root.appendingPathComponent("session-summaries-v6.json")
        let cache = SessionSummaryCache(fileURL: currentURL)
        let hydrated = await cache.liveSummaries(archivedIDs: [])
        let staleLookup = await cache.summary(for: fingerprint, archivedIDs: [])
        XCTAssertEqual(hydrated.map(\.id), ["cache-session"])
        XCTAssertNil(staleLookup, "Legacy entries must reparse in the background")

        summary.pullRequestURL = URL(string: "https://github.com/acme/widgets/pull/4")
        summary.pullRequestCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await cache.store(summary, fingerprint: fingerprint)
        try await cache.persist()
        let reloaded = SessionSummaryCache(fileURL: currentURL)
        let upgraded = await reloaded.summary(for: fingerprint, archivedIDs: [])
        XCTAssertEqual(upgraded?.pullRequestURL, summary.pullRequestURL)
        XCTAssertEqual(upgraded?.pullRequestCreatedAt, summary.pullRequestCreatedAt)
    }

    func testRefreshSummarySeesAnAppendThroughADiscoveredURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopCacheRefresh-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("--project--", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = project.appendingPathComponent("session.jsonl")
        try fixture().write(to: file)
        let repository = FileSessionRepository(
            rootURL: root,
            summaryCache: SessionSummaryCache(fileURL: root.appendingPathComponent("cache.json"))
        )
        let discovered = try await repository.discoverSessions(archivedIDs: [])
        let original = try XCTUnwrap(discovered.first)
        _ = try original.fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        let entry = try JSONSerialization.data(withJSONObject: [
            "type": "session_info", "id": "name", "parentId": "user", "name": "Fresh title"
        ])
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: entry)
        try writer.write(contentsOf: Data([0x0A]))
        try writer.close()

        let refreshed = try await repository.refreshSummary(at: original.fileURL, archivedIDs: [])
        XCTAssertEqual(refreshed.displayName, "Fresh title")
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
