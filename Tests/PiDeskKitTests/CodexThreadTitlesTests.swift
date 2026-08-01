import Foundation
import SQLite3
import XCTest
@testable import PiDeskKit

final class CodexThreadTitlesTests: XCTestCase {
    func testSnapshotInvalidatesWhenOnlyTheWriteAheadLogChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDeskTitles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = directory.appendingPathComponent("state_5.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        guard let handle else { return XCTFail("database did not open") }
        defer { sqlite3_close_v2(handle) }

        try execute("PRAGMA journal_mode=WAL", on: handle)
        try execute("PRAGMA wal_autocheckpoint=0", on: handle)
        try execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)", on: handle)
        try execute("INSERT INTO threads VALUES ('thread-1', 'First title', NULL)", on: handle)

        let reader = CodexThreadTitles(directory: directory)
        XCTAssertEqual(reader.snapshot()["thread-1"], "First title")

        try execute("UPDATE threads SET name = 'Second title' WHERE id = 'thread-1'", on: handle)
        XCTAssertEqual(reader.snapshot()["thread-1"], "Second title")
    }

    private func execute(_ sql: String, on handle: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        if result != SQLITE_OK {
            throw NSError(
                domain: "CodexThreadTitlesTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? sql]
            )
        }
    }
}
