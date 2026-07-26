import Foundation
import XCTest
@testable import PiDesktop

final class WorkspaceOrganizationTests: XCTestCase {
    @MainActor
    func testCRUDMoveAndPersistenceNeverTouchSessionFile() throws {
        let base = temporaryDirectory("WorkspaceState")
        defer { try? FileManager.default.removeItem(at: base) }
        let session = base.appendingPathComponent("thread.jsonl")
        let original = Data("{\"type\":\"session\"}\n".utf8)
        try original.write(to: session)

        let persistence = AppPersistence(baseURL: base)
        let first = try XCTUnwrap(persistence.createVirtualFolder(named: "  Focus  "))
        let second = try XCTUnwrap(persistence.createVirtualFolder(named: "Later"))
        XCTAssertEqual(persistence.state.virtualFolders.map(\.name), ["Focus", "Later"])

        persistence.moveSession(path: session.path, toVirtualFolder: first.id)
        XCTAssertEqual(persistence.state.virtualFolderAssignments[session.standardizedFileURL.path], first.id)
        XCTAssertTrue(persistence.renameVirtualFolder(id: first.id, to: "Today"))
        XCTAssertEqual(persistence.state.virtualFolders.first?.name, "Today")

        let reloaded = AppPersistence(baseURL: base)
        XCTAssertEqual(reloaded.state.virtualFolders.first?.name, "Today")
        XCTAssertEqual(reloaded.state.virtualFolderAssignments[session.standardizedFileURL.path], first.id)

        XCTAssertTrue(reloaded.deleteVirtualFolder(id: first.id))
        XCTAssertNil(reloaded.state.virtualFolderAssignments[session.standardizedFileURL.path])
        XCTAssertEqual(reloaded.state.virtualFolders.map(\.id), [second.id])
        XCTAssertEqual(try Data(contentsOf: session), original, "App organization must never rewrite Pi JSONL")
    }

    func testMoveBackToProjectRemovesOverrideAndInvalidTargetsAreIgnored() throws {
        var folders = [VirtualFolder(id: "one", name: "One")]
        var assignments: [String: String] = [:]
        let path = "/tmp/a.jsonl"
        WorkspaceOrganization.move(sessionPath: path, to: "missing", folders: folders, assignments: &assignments)
        XCTAssertTrue(assignments.isEmpty)
        WorkspaceOrganization.move(sessionPath: path, to: "one", folders: folders, assignments: &assignments)
        XCTAssertEqual(assignments[path], "one")
        WorkspaceOrganization.move(sessionPath: path, to: nil, folders: folders, assignments: &assignments)
        XCTAssertTrue(assignments.isEmpty)

        XCTAssertTrue(WorkspaceOrganization.delete(id: "one", folders: &folders, assignments: &assignments))
        XCTAssertTrue(folders.isEmpty)
    }

    func testSidebarProjectsEverySummaryExactlyOnceIncludingVirtualOverrides() {
        let virtual = VirtualFolder(id: "focus", name: "Focus")
        let sessions = [
            summary(id: "a", cwd: "/tmp/project-a"),
            summary(id: "b", cwd: "/tmp/project-a"),
            summary(id: "c", cwd: "/Users/test/Desktop"),
            summary(id: "d", cwd: "/tmp/project-b")
        ]
        let assignments = [sessions[1].fileURL.standardizedFileURL.path: virtual.id]
        let snapshot = SidebarSnapshot(
            sessions: sessions,
            query: "",
            virtualFolders: [virtual],
            assignments: assignments
        )
        let projected = snapshot.activeGroups.flatMap(\.sessions)
        XCTAssertEqual(projected.count, sessions.count)
        XCTAssertEqual(Set(projected.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertEqual(Dictionary(grouping: projected, by: \.id).values.map(\.count).max(), 1)
        XCTAssertEqual(snapshot.activeGroups.first(where: { $0.virtualFolderID == virtual.id })?.sessions.map(\.id), ["b"])
        XCTAssertEqual(snapshot.activeGroups.reduce(0) { $0 + $1.sessions.count }, 4, "Folder counts cover every thread")
    }

    func testEmptyVirtualFolderRemainsReachable() {
        let snapshot = SidebarSnapshot(
            sessions: [], query: "", virtualFolders: [VirtualFolder(id: "empty", name: "Empty")]
        )
        XCTAssertEqual(snapshot.activeGroups.count, 1)
        XCTAssertEqual(snapshot.activeGroups.first?.sessions.count, 0)
    }

    @MainActor
    func testExternalTerminalWriteBecomesUnreadThroughSharedMonitor() async throws {
        let base = temporaryDirectory("ExternalUnread")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("thread.jsonl")
        try Data("{\"type\":\"session\"}\n".utf8).write(to: file)
        let monitor = SessionActivityMonitor(isActiveOverride: true)
        let store = AppStore(persistence: AppPersistence(baseURL: base), activityMonitor: monitor)
        let session = summary(id: "external", cwd: "/tmp", modifiedAt: .distantPast, fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path) != nil }
        store.markRead(session)
        XCTAssertFalse(store.isUnread(session))

        try await Task.sleep(nanoseconds: 20_000_000)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\"}\n".utf8))
        try handle.close()
        monitor.tickNow()
        try await waitUntil { store.isUnread(session) }
        XCTAssertTrue(store.isUnread(session))
    }

    @MainActor
    func testUnreadStatePersistsAndNewerActivityBecomesUnread() throws {
        let base = temporaryDirectory("UnreadState")
        defer { try? FileManager.default.removeItem(at: base) }
        let persistence = AppPersistence(baseURL: base)
        let store = AppStore(persistence: persistence, activityMonitor: SessionActivityMonitor(isActiveOverride: false))
        let old = summary(id: "read", cwd: "/tmp", modifiedAt: Date(timeIntervalSince1970: 100))
        let newer = summary(id: "read", cwd: "/tmp", modifiedAt: Date(timeIntervalSince1970: 200), fileURL: old.fileURL)

        XCTAssertTrue(store.isUnread(old), "Never-viewed sessions are unread")
        store.markRead(old)
        XCTAssertFalse(store.isUnread(old))
        XCTAssertTrue(store.isUnread(newer), "External writes newer than last viewed become unread")
        store.markUnread(old)
        XCTAssertTrue(store.isUnread(old))

        let reloaded = AppPersistence(baseURL: base)
        XCTAssertTrue(reloaded.state.manuallyUnreadSessionPaths.contains(old.fileURL.standardizedFileURL.path))
        reloaded.markSessionRead(path: old.fileURL.path, at: newer.modifiedAt)
        XCTAssertFalse(AppPersistence(baseURL: base).state.manuallyUnreadSessionPaths.contains(old.fileURL.standardizedFileURL.path))
    }

    @MainActor
    func testNowhereIsDesktop() {
        XCTAssertEqual(AppStore.nowhereFolderURL.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path)
    }

    private func summary(
        id: String,
        cwd: String,
        modifiedAt: Date = Date(),
        fileURL: URL? = nil
    ) -> SessionSummary {
        var result = SessionSummary(
            id: id,
            fileURL: fileURL ?? URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            name: id,
            preview: "",
            messageCount: 0,
            metrics: TokenMetrics()
        )
        result.prepareSearchKey()
        return result
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}

final class SidebarAutoCollapseTests: XCTestCase {
    func testAutoCollapseAndRestoreOnlyPolicyOwnedVisibility() {
        var state = SidebarAutoCollapseState()
        XCTAssertEqual(state.action(width: 700, sidebarVisible: true, threshold: 860), .collapse)
        XCTAssertNil(state.action(width: 700, sidebarVisible: false, threshold: 860))
        XCTAssertEqual(state.action(width: 1_000, sidebarVisible: false, threshold: 860), .expand)
        XCTAssertFalse(state.autoCollapsed)
    }

    func testManualHiddenSidebarIsNotRestored() {
        var state = SidebarAutoCollapseState()
        XCTAssertNil(state.action(width: 700, sidebarVisible: false, threshold: 860))
        XCTAssertNil(state.action(width: 1_000, sidebarVisible: false, threshold: 860))
    }

    func testNarrowUserOverrideIsNotFoughtUntilWindowWidens() {
        var state = SidebarAutoCollapseState()
        XCTAssertEqual(state.action(width: 700, sidebarVisible: true, threshold: 860), .collapse)
        state.userChangedVisibility(width: 700, threshold: 860)
        XCTAssertNil(state.action(width: 720, sidebarVisible: true, threshold: 860))
        XCTAssertNil(state.action(width: 1_000, sidebarVisible: true, threshold: 860))
        XCTAssertEqual(state.action(width: 700, sidebarVisible: true, threshold: 860), .collapse)
    }
}
