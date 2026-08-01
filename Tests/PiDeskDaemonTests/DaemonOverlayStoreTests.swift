import Foundation
import PiDeskKit
import XCTest
@testable import PiDeskDaemon

final class DaemonOverlayStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = TestSupport.tempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testArchiveMutationRollsBackInMemoryWhenPersistenceFails() async throws {
        let invalidParent = directory.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: invalidParent)
        let invalidTarget = invalidParent.appendingPathComponent("overlay.json")
        let store = DaemonOverlayStore(fileURL: invalidTarget)

        do {
            try await store.setArchived(true, threadID: "thread", path: "/tmp/thread.jsonl")
            XCTFail("expected persistence to fail")
        } catch {
            // expected
        }

        let archived = await store.isArchived("thread", path: "/tmp/thread.jsonl")
        XCTAssertFalse(archived)

        do {
            try await store.setUnread(true, path: "/tmp/thread.jsonl")
            XCTFail("expected unread persistence to fail")
        } catch {
            // expected
        }
        let unread = await store.unreadOverride(
            path: "/tmp/thread.jsonl", currentUpdatedAt: .distantPast
        )
        XCTAssertNil(unread)
    }

    func testArchiveAndLegacyRestoreCapsAlwaysRetainThePathBeingChanged() async throws {
        let overlayURL = directory.appendingPathComponent("overlay.json")
        let existing = (0..<ArchiveStateBounds.itemLimit).map {
            String(format: "/z/%05d.jsonl", $0)
        }
        let payload: [String: Any] = [
            "archivedThreadIDs": ["legacy"],
            "archivedThreadPaths": existing,
            "archiveExemptThreadPaths": existing
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: overlayURL)
        let store = DaemonOverlayStore(fileURL: overlayURL)
        let currentArchive = "/a/current-archive.jsonl"
        let currentRestore = "/a/current-restore.jsonl"

        try await store.setArchived(true, threadID: "new", path: currentArchive)
        try await store.setArchived(false, threadID: "legacy", path: currentRestore)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.archivedThreadPaths.count, ArchiveStateBounds.itemLimit)
        XCTAssertTrue(snapshot.archivedThreadPaths.contains(currentArchive))
        XCTAssertEqual(snapshot.archiveExemptThreadPaths.count, ArchiveStateBounds.itemLimit)
        XCTAssertTrue(snapshot.archiveExemptThreadPaths.contains(currentRestore))
        XCTAssertFalse(snapshot.isArchived("legacy", path: currentRestore))
    }

    func testArchiveCheckpointRestoresEveryEntryEvictedByTheMutation() async throws {
        let overlayURL = directory.appendingPathComponent("overlay.json")
        let existing = (0..<ArchiveStateBounds.itemLimit).map {
            String(format: "/z/%05d.jsonl", $0)
        }
        let payload: [String: Any] = [
            "archivedThreadIDs": ["legacy"],
            "archivedThreadPaths": existing,
            "archiveExemptThreadPaths": existing
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: overlayURL)
        let store = DaemonOverlayStore(fileURL: overlayURL)
        try await store.setUnread(true, path: "/tmp/read.jsonl")
        try await store.recordManagedThread(path: "/tmp/managed.jsonl")
        let before = await store.snapshot()

        let checkpoint = try await store.setArchived(
            true, threadID: "new", path: "/a/current.jsonl"
        )
        try await store.restoreArchive(checkpoint)

        let after = await store.snapshot()
        XCTAssertEqual(after.archivedThreadPaths, before.archivedThreadPaths)
        XCTAssertEqual(after.archiveExemptThreadPaths, before.archiveExemptThreadPaths)
        XCTAssertEqual(after.managedThreadPaths, before.managedThreadPaths)
        XCTAssertEqual(after.readOverrides.keys.sorted(), before.readOverrides.keys.sorted())
    }

    func testStaleArchiveCheckpointCannotClobberANewerMutation() async throws {
        let store = DaemonOverlayStore(fileURL: directory.appendingPathComponent("overlay.json"))
        let checkpoint = try await store.setArchived(
            true, threadID: "first", path: "/tmp/first.jsonl"
        )
        try await store.setArchived(true, threadID: "second", path: "/tmp/second.jsonl")

        do {
            try await store.restoreArchive(checkpoint)
            XCTFail("expected a stale checkpoint to be rejected")
        } catch DaemonOverlayStore.ArchiveRestoreError.staleCheckpoint {
            // expected
        }

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.archivedThreadPaths.contains("/tmp/first.jsonl"))
        XCTAssertTrue(snapshot.archivedThreadPaths.contains("/tmp/second.jsonl"))
    }

    func testReadAndManagedThreadBoundsRetainThePathJustWritten() async throws {
        let overlayURL = directory.appendingPathComponent("overlay.json")
        let existing = (0..<ArchiveStateBounds.itemLimit).map {
            String(format: "/z/%05d.jsonl", $0)
        }
        let readOverrides = Dictionary(uniqueKeysWithValues: existing.map {
            ($0, ["unread": true, "markedAt": "2026-01-01T00:00:00.000Z"] as [String: Any])
        })
        let payload: [String: Any] = [
            "managedThreadPaths": existing,
            "readOverrides": readOverrides
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: overlayURL)
        let store = DaemonOverlayStore(fileURL: overlayURL)
        let current = "/a/current.jsonl"

        try await store.setUnread(true, path: current)
        try await store.recordManagedThread(path: current)

        for snapshot in [await store.snapshot(), await DaemonOverlayStore(fileURL: overlayURL).snapshot()] {
            XCTAssertEqual(snapshot.readOverrides.count, ArchiveStateBounds.itemLimit)
            XCTAssertNotNil(snapshot.readOverrides[current])
            XCTAssertEqual(snapshot.managedThreadPaths.count, ArchiveStateBounds.itemLimit)
            XCTAssertTrue(snapshot.managedThreadPaths.contains(current))
        }
    }

    func testPersistencePrunesBeforeTheOverlayCanExceedTheReaderBudget() async throws {
        let overlayURL = directory.appendingPathComponent("overlay.json")
        let count = 4_000
        var lower = 1
        var upper = 3_000
        var seed = Data()
        while lower <= upper {
            let length = (lower + upper) / 2
            let suffix = String(repeating: "x", count: length)
            let paths = (0..<count).map { "/seed/\($0)-\(suffix).jsonl" }
            let candidate = try JSONSerialization.data(withJSONObject: [
                "archivedThreadPaths": paths
            ])
            if candidate.count <= DaemonWorktreeProjects.maximumPayloadBytes - 4_096 {
                seed = candidate
                lower = length + 1
            } else {
                upper = length - 1
            }
        }
        XCTAssertGreaterThan(seed.count, DaemonWorktreeProjects.maximumPayloadBytes - 20_000)
        try seed.write(to: overlayURL)
        let store = DaemonOverlayStore(fileURL: overlayURL)
        let current = "/current/\(String(repeating: "y", count: 8_192)).jsonl"

        try await store.setArchived(true, threadID: "current", path: current)

        let bytes = try Data(contentsOf: overlayURL).count
        XCTAssertLessThanOrEqual(bytes, DaemonWorktreeProjects.maximumPayloadBytes)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.archivedThreadPaths.contains(
            URL(fileURLWithPath: current).standardizedFileURL.path
        ))
        XCTAssertFalse(snapshot.archivedThreadPaths.isEmpty)
        let projected = DaemonWorktreeProjects.loadSnapshot(from: overlayURL)
        XCTAssertEqual(projected.archivedThreadPaths, snapshot.archivedThreadPaths)
    }
}
