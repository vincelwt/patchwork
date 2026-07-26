import Foundation
import XCTest
@testable import PiDesktop

final class SessionDiscoveryTests: XCTestCase {
    func testEveryTopLevelProjectSummaryIsDiscoveredExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDiscovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let projectA = root.appendingPathComponent("--project-a--", isDirectory: true)
        let oldProject = root.appendingPathComponent(".old-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldProject, withIntermediateDirectories: true)

        let expected = [
            root.appendingPathComponent("root.jsonl"),
            projectA.appendingPathComponent("a.jsonl"),
            projectA.appendingPathComponent("b.JSONL"),
            oldProject.appendingPathComponent("old.jsonl")
        ]
        for (index, url) in expected.enumerated() {
            try fixture(id: "session-\(index)", cwd: "/tmp/project-\(index)").write(to: url)
        }

        // Pi may put subordinate run logs deeper below a project session. They are not user
        // threads and must not inflate the sidebar.
        let nested = projectA.appendingPathComponent("run/worker/session.jsonl")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture(id: "subordinate", cwd: "/tmp").write(to: nested)

        let cache = SessionSummaryCache(fileURL: root.appendingPathComponent("cache.json"))
        let repository = FileSessionRepository(rootURL: root, summaryCache: cache)
        let summaries = try await repository.discoverSessions(archivedIDs: [])

        XCTAssertEqual(summaries.count, expected.count)
        XCTAssertEqual(Set(summaries.map(\.id)), Set((0..<expected.count).map { "session-\($0)" }))
        XCTAssertEqual(Dictionary(grouping: summaries, by: { $0.fileURL.standardizedFileURL.path }).values.map(\.count).max(), 1)
        XCTAssertFalse(summaries.contains { $0.id == "subordinate" })
    }

    private func fixture(id: String, cwd: String) throws -> Data {
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": id, "timestamp": "2026-01-01T12:00:00.000Z", "cwd": cwd],
            ["type": "message", "id": "user-\(id)", "parentId": NSNull(), "message": ["role": "user", "content": "Prompt \(id)"]]
        ]
        return try lines.reduce(into: Data()) { data, line in
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
    }
}
