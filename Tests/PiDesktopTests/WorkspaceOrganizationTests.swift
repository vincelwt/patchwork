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

    // MARK: - Nested folders

    func testVirtualFolderDecodesWithoutParentIDField() throws {
        let legacyJSON = Data("""
        {"id":"legacy","name":"Legacy","createdAt":0}
        """.utf8)
        let decoded = try JSONDecoder().decode(VirtualFolder.self, from: legacyJSON)
        XCTAssertEqual(decoded.id, "legacy")
        XCTAssertNil(decoded.parentID, "A pre-nesting state.json has no parentID key at all")
    }

    func testCreateRejectsDanglingVirtualParent() {
        var folders: [VirtualFolder] = []
        let orphan = WorkspaceOrganization.create(
            named: "Orphan", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: "missing"), in: &folders
        )
        XCTAssertNil(orphan)
        XCTAssertTrue(folders.isEmpty)
    }

    func testNestingUnderAnotherFolderAndUnderAProjectPath() throws {
        var folders: [VirtualFolder] = []
        let top = try XCTUnwrap(WorkspaceOrganization.create(named: "Top", in: &folders))
        let nested = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Nested", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: top.id), in: &folders
        ))
        let inProject = try XCTUnwrap(WorkspaceOrganization.create(named: "InProject", parentID: "/tmp/project-a", in: &folders))

        XCTAssertEqual(
            WorkspaceOrganization.effectiveParentID(of: nested, in: folders),
            WorkspaceOrganization.groupID(forVirtualFolderID: top.id)
        )
        XCTAssertEqual(WorkspaceOrganization.effectiveParentID(of: inProject, in: folders), "/tmp/project-a")
    }

    func testReparentRejectsSelfAndDescendantCycles() throws {
        var folders: [VirtualFolder] = []
        let a = try XCTUnwrap(WorkspaceOrganization.create(named: "A", in: &folders))
        let b = try XCTUnwrap(WorkspaceOrganization.create(
            named: "B", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: a.id), in: &folders
        ))

        XCTAssertFalse(WorkspaceOrganization.reparent(id: a.id, to: WorkspaceOrganization.groupID(forVirtualFolderID: a.id), in: &folders))
        XCTAssertFalse(WorkspaceOrganization.reparent(id: a.id, to: WorkspaceOrganization.groupID(forVirtualFolderID: b.id), in: &folders))
        XCTAssertFalse(WorkspaceOrganization.reparent(id: a.id, to: WorkspaceOrganization.groupID(forVirtualFolderID: "missing"), in: &folders))
        XCTAssertNil(folders.first(where: { $0.id == a.id })?.parentID, "Rejected moves leave the folder untouched")

        XCTAssertTrue(WorkspaceOrganization.reparent(id: b.id, to: "/tmp/project-a", in: &folders), "Moving into a filesystem project is always allowed")
        XCTAssertEqual(folders.first(where: { $0.id == b.id })?.parentID, "/tmp/project-a")
    }

    func testEffectiveParentIDBreaksHandEditedCycles() {
        let a = VirtualFolder(id: "a", name: "A", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: "b"))
        let b = VirtualFolder(id: "b", name: "B", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: "a"))
        let folders = [a, b]
        XCTAssertNil(WorkspaceOrganization.effectiveParentID(of: a, in: folders))
        XCTAssertNil(WorkspaceOrganization.effectiveParentID(of: b, in: folders))
    }

    func testDeleteTopLevelFolderPromotesChildToTopLevel() throws {
        var folders: [VirtualFolder] = []
        var assignments: [String: String] = [:]
        let parent = try XCTUnwrap(WorkspaceOrganization.create(named: "Parent", in: &folders))
        let child = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Child", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: parent.id), in: &folders
        ))

        XCTAssertTrue(WorkspaceOrganization.delete(id: parent.id, folders: &folders, assignments: &assignments))
        XCTAssertNil(folders.first(where: { $0.id == child.id })?.parentID)
    }

    func testDeleteNestedFolderPromotesGrandchildToItsParent() throws {
        var folders: [VirtualFolder] = []
        var assignments: [String: String] = [:]
        let top = try XCTUnwrap(WorkspaceOrganization.create(named: "Top", in: &folders))
        let mid = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Mid", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: top.id), in: &folders
        ))
        let leaf = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Leaf", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: mid.id), in: &folders
        ))
        assignments["/tmp/leaf-session.jsonl"] = leaf.id

        XCTAssertTrue(WorkspaceOrganization.delete(id: mid.id, folders: &folders, assignments: &assignments))

        XCTAssertEqual(folders.first(where: { $0.id == leaf.id })?.parentID, WorkspaceOrganization.groupID(forVirtualFolderID: top.id))
        XCTAssertNil(folders.first(where: { $0.id == mid.id }))
        XCTAssertEqual(assignments["/tmp/leaf-session.jsonl"], leaf.id, "A session's assignment survives its folder's parent being deleted")
    }

    func testDeleteFolderInsideProjectPromotesChildToProject() throws {
        var folders: [VirtualFolder] = []
        var assignments: [String: String] = [:]
        let projectPath = "/tmp/project-a"
        let mid = try XCTUnwrap(WorkspaceOrganization.create(named: "Mid", parentID: projectPath, in: &folders))
        let leaf = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Leaf", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: mid.id), in: &folders
        ))

        XCTAssertTrue(WorkspaceOrganization.delete(id: mid.id, folders: &folders, assignments: &assignments))
        XCTAssertEqual(folders.first(where: { $0.id == leaf.id })?.parentID, projectPath)
    }

    func testMoveSessionIntoAndOutOfADeeplyNestedFolder() throws {
        var folders: [VirtualFolder] = []
        let top = try XCTUnwrap(WorkspaceOrganization.create(named: "Top", in: &folders))
        let nested = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Nested", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: top.id), in: &folders
        ))
        var assignments: [String: String] = [:]

        WorkspaceOrganization.move(sessionPath: "/tmp/s.jsonl", to: nested.id, folders: folders, assignments: &assignments)
        XCTAssertEqual(assignments["/tmp/s.jsonl"], nested.id)

        WorkspaceOrganization.move(sessionPath: "/tmp/s.jsonl", to: nil, folders: folders, assignments: &assignments)
        XCTAssertTrue(assignments.isEmpty, "Clearing an assignment works the same regardless of nesting depth")
    }

    func testOrderedChildrenIndentsByDepth() throws {
        var folders: [VirtualFolder] = []
        let root = try XCTUnwrap(WorkspaceOrganization.create(named: "Root", in: &folders))
        let child = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Child", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: root.id), in: &folders
        ))
        _ = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Grandchild", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: child.id), in: &folders
        ))

        let entries = WorkspaceOrganization.orderedChildren(of: nil, in: folders)
        XCTAssertEqual(entries.map(\.folder.name), ["Root", "Child", "Grandchild"])
        XCTAssertEqual(entries.map(\.depth), [0, 1, 2])
    }

    func testAllFolderEntriesCoversTopLevelAndProjectNestedFolders() throws {
        var folders: [VirtualFolder] = []
        let inProject = try XCTUnwrap(WorkspaceOrganization.create(named: "InProject", parentID: "/tmp/project-a", in: &folders))
        let top = try XCTUnwrap(WorkspaceOrganization.create(named: "TopLevel", in: &folders))

        let entries = WorkspaceOrganization.allFolderEntries(folders)
        XCTAssertEqual(Set(entries.map(\.folder.id)), Set([inProject.id, top.id]))
    }

    // MARK: - Default working directory for a folder-scoped new chat

    func testDefaultWorkingDirectoryPrefersTheFolderSSharedCwd() {
        let folder = VirtualFolder(id: "focus", name: "Focus")
        let a = summary(id: "a", cwd: "/tmp/project-a")
        let b = summary(id: "b", cwd: "/tmp/project-a")
        let assignments = [
            a.fileURL.standardizedFileURL.path: folder.id,
            b.fileURL.standardizedFileURL.path: folder.id
        ]
        let cwd = WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: folder.id, sessions: [a, b], assignments: assignments,
            folders: [folder], fallback: URL(fileURLWithPath: "/tmp/fallback")
        )
        XCTAssertEqual(cwd.standardizedFileURL.path, "/tmp/project-a")
    }

    func testDefaultWorkingDirectoryIgnoresSessionsAssignedToADifferentFolder() {
        let focus = VirtualFolder(id: "focus", name: "Focus")
        let other = VirtualFolder(id: "other", name: "Other")
        let inFocus = summary(id: "a", cwd: "/tmp/project-a")
        let inOther = summary(id: "b", cwd: "/tmp/project-b")
        let assignments = [
            inFocus.fileURL.standardizedFileURL.path: focus.id,
            inOther.fileURL.standardizedFileURL.path: other.id
        ]
        let cwd = WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: focus.id, sessions: [inFocus, inOther], assignments: assignments,
            folders: [focus, other], fallback: URL(fileURLWithPath: "/tmp/fallback")
        )
        XCTAssertEqual(cwd.standardizedFileURL.path, "/tmp/project-a", "A sibling folder's sessions must never leak into this one's cwd guess")
    }

    func testDefaultWorkingDirectoryBreaksATieOnTheMostRecentlyModifiedSession() {
        let folder = VirtualFolder(id: "mixed", name: "Mixed")
        let older = summary(id: "older", cwd: "/tmp/project-a", modifiedAt: Date(timeIntervalSince1970: 100))
        let newer = summary(id: "newer", cwd: "/tmp/project-b", modifiedAt: Date(timeIntervalSince1970: 200))
        let assignments = [
            older.fileURL.standardizedFileURL.path: folder.id,
            newer.fileURL.standardizedFileURL.path: folder.id
        ]
        let cwd = WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: folder.id, sessions: [older, newer], assignments: assignments,
            folders: [folder], fallback: URL(fileURLWithPath: "/tmp/fallback")
        )
        XCTAssertEqual(cwd.standardizedFileURL.path, "/tmp/project-b", "A 1-1 tie breaks toward the most recently modified session")
    }

    func testDefaultWorkingDirectoryFallsBackToTheEnclosingProjectWhenTheFolderIsEmpty() throws {
        var folders: [VirtualFolder] = []
        let empty = try XCTUnwrap(WorkspaceOrganization.create(named: "Empty", parentID: "/tmp/project-a", in: &folders))
        let cwd = WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: empty.id, sessions: [], assignments: [:],
            folders: folders, fallback: URL(fileURLWithPath: "/tmp/fallback")
        )
        XCTAssertEqual(cwd.standardizedFileURL.path, "/tmp/project-a")
    }

    func testDefaultWorkingDirectoryWalksUpThroughEmptyParentFoldersToFindTheProject() throws {
        var folders: [VirtualFolder] = []
        let mid = try XCTUnwrap(WorkspaceOrganization.create(named: "Mid", parentID: "/tmp/project-a", in: &folders))
        let leaf = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Leaf", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: mid.id), in: &folders
        ))
        let cwd = WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: leaf.id, sessions: [], assignments: [:],
            folders: folders, fallback: URL(fileURLWithPath: "/tmp/fallback")
        )
        XCTAssertEqual(
            cwd.standardizedFileURL.path, "/tmp/project-a",
            "An empty folder nested inside another empty folder still finds the enclosing project"
        )
    }

    func testDefaultWorkingDirectoryFallsBackToTheCallerSDefaultWhenNothingElseApplies() throws {
        var folders: [VirtualFolder] = []
        let topLevel = try XCTUnwrap(WorkspaceOrganization.create(named: "TopLevel", in: &folders))
        let fallback = URL(fileURLWithPath: "/tmp/fallback", isDirectory: true)
        let cwd = WorkspaceOrganization.defaultWorkingDirectory(
            forVirtualFolder: topLevel.id, sessions: [], assignments: [:],
            folders: folders, fallback: fallback
        )
        XCTAssertEqual(cwd.standardizedFileURL.path, fallback.standardizedFileURL.path, "A top-level, empty folder has no project to fall back to")
    }

    func testSidebarSnapshotRendersNestedFoldersAndProjectsEverySessionOnce() throws {
        var folders: [VirtualFolder] = []
        let projectPath = "/tmp/project-a"
        let inProject = try XCTUnwrap(WorkspaceOrganization.create(named: "In Project", parentID: projectPath, in: &folders))
        let nested = try XCTUnwrap(WorkspaceOrganization.create(
            named: "Nested", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: inProject.id), in: &folders
        ))
        let topLevel = try XCTUnwrap(WorkspaceOrganization.create(named: "Top", in: &folders))

        let sessions = [
            summary(id: "loose", cwd: projectPath),
            summary(id: "inProject", cwd: projectPath),
            summary(id: "nested", cwd: projectPath),
            summary(id: "top", cwd: "/tmp/other")
        ]
        let assignments = [
            sessions[1].fileURL.standardizedFileURL.path: inProject.id,
            sessions[2].fileURL.standardizedFileURL.path: nested.id,
            sessions[3].fileURL.standardizedFileURL.path: topLevel.id
        ]
        let snapshot = SidebarSnapshot(sessions: sessions, query: "", virtualFolders: folders, assignments: assignments)

        func flatten(_ groups: [SessionFolderGroup]) -> [SessionSummary] {
            groups.flatMap { $0.sessions + flatten($0.children) }
        }
        let projected = flatten(snapshot.activeGroups)
        XCTAssertEqual(projected.count, sessions.count, "Every session appears exactly once across the tree")
        XCTAssertEqual(Set(projected.map(\.id)), Set(sessions.map(\.id)))

        let project = try XCTUnwrap(snapshot.activeGroups.first { $0.path == projectPath })
        XCTAssertEqual(project.sessions.map(\.id), ["loose"])
        let inProjectGroup = try XCTUnwrap(project.children.first { $0.virtualFolderID == inProject.id })
        XCTAssertEqual(inProjectGroup.sessions.map(\.id), ["inProject"])
        let nestedGroup = try XCTUnwrap(inProjectGroup.children.first { $0.virtualFolderID == nested.id })
        XCTAssertEqual(nestedGroup.sessions.map(\.id), ["nested"])

        let topGroup = try XCTUnwrap(snapshot.activeGroups.first { $0.virtualFolderID == topLevel.id })
        XCTAssertEqual(topGroup.sessions.map(\.id), ["top"])
    }

    @MainActor
    func testNestedFolderParentPersistsAcrossReloadAndReparentUpdatesIt() throws {
        let base = temporaryDirectory("NestedFolderPersistence")
        defer { try? FileManager.default.removeItem(at: base) }
        let persistence = AppPersistence(baseURL: base)
        let parent = try XCTUnwrap(persistence.createVirtualFolder(named: "Parent"))
        let child = try XCTUnwrap(persistence.createVirtualFolder(
            named: "Child", parentID: WorkspaceOrganization.groupID(forVirtualFolderID: parent.id)
        ))

        let reloaded = AppPersistence(baseURL: base)
        XCTAssertEqual(
            reloaded.state.virtualFolders.first(where: { $0.id == child.id })?.parentID,
            WorkspaceOrganization.groupID(forVirtualFolderID: parent.id)
        )

        XCTAssertTrue(reloaded.reparentVirtualFolder(id: child.id, to: nil))
        XCTAssertNil(AppPersistence(baseURL: base).state.virtualFolders.first(where: { $0.id == child.id })?.parentID)
    }

    @MainActor
    func testExternalTerminalWriteBecomesUnreadOnlyAfterTurnFinishes() async throws {
        let base = temporaryDirectory("ExternalUnread")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("thread.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"initial\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: base.appendingPathComponent("heartbeats")
        )
        let store = AppStore(persistence: AppPersistence(baseURL: base), activityMonitor: monitor)
        let session = summary(id: "external", cwd: "/tmp", modifiedAt: .distantPast, fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "initial" }
        store.markRead(session)

        try Data("{\"type\":\"message\",\"id\":\"question\",\"message\":{\"role\":\"user\"}}\n".utf8).write(to: file)
        monitor.tickNow()
        try await waitUntil { store.isRunning(session) }
        XCTAssertFalse(store.isUnread(session), "A nonterminal turn does not create unread state")

        try Data("{\"type\":\"message\",\"id\":\"answer\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
        monitor.tickNow()
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "answer" }
        XCTAssertTrue(store.isUnread(session), "The completed turn becomes unread")
    }

    @MainActor
    func testNeverViewedSessionWithoutACompletionHasNoPhantomUnreadAndManualUnreadPersists() throws {
        let base = temporaryDirectory("UnreadState")
        defer { try? FileManager.default.removeItem(at: base) }
        let persistence = AppPersistence(baseURL: base)
        let store = AppStore(persistence: persistence, activityMonitor: SessionActivityMonitor(isActiveOverride: false))
        let session = summary(id: "read", cwd: "/tmp", modifiedAt: Date(timeIntervalSince1970: 200))

        XCTAssertFalse(store.isUnread(session), "Mtime alone never invents a completed answer")
        store.markUnread(session)
        XCTAssertTrue(store.isUnread(session))
        XCTAssertTrue(
            AppPersistence(baseURL: base).state.manuallyUnreadSessionPaths.contains(session.fileURL.standardizedFileURL.path),
            "Explicit unread survives relaunch"
        )
        store.markRead(session)
        XCTAssertFalse(store.isUnread(session))
    }

    @MainActor
    func testSameMtimeNewCompletionBecomesUnreadByEntryID() async throws {
        let base = temporaryDirectory("SameMtimeUnread")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("thread.jsonl")
        let fixedMtime = Date().addingTimeInterval(-600)
        try Data("{\"type\":\"message\",\"id\":\"first\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: file.path)

        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: base.appendingPathComponent("heartbeats"))
        let persistence = AppPersistence(baseURL: base)
        let store = AppStore(persistence: persistence, activityMonitor: monitor)
        let session = summary(id: "same-mtime", cwd: "/tmp", modifiedAt: fixedMtime, fileURL: file)
        store.sessions = [session]
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "first" }
        store.markRead(session)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"second\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"length\"}}\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: file.path)
        monitor.tickNow()

        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "second" }
        XCTAssertTrue(store.isUnread(session), "A changed completion ID wins even when mtime is identical")
    }

    @MainActor
    func testLegacyLastReadAtMigratesOnceThenCompletionIDsOwnUnreadState() throws {
        let base = temporaryDirectory("UnreadMigration")
        defer { try? FileManager.default.removeItem(at: base) }
        let readPath = base.appendingPathComponent("read.jsonl").standardizedFileURL.path
        let unreadPath = base.appendingPathComponent("unread.jsonl").standardizedFileURL.path
        var legacy = PersistedAppState()
        legacy.lastReadAt = [
            readPath: Date(timeIntervalSince1970: 200),
            unreadPath: Date(timeIntervalSince1970: 200)
        ]
        try JSONEncoder().encode(legacy).write(to: base.appendingPathComponent("state.json"), options: .atomic)

        let persistence = AppPersistence(baseURL: base)
        persistence.observeCompletedEntry(
            path: readPath, completionID: "already-read", modifiedAt: Date(timeIntervalSince1970: 100), markSeen: false
        )
        persistence.observeCompletedEntry(
            path: unreadPath, completionID: "newer", modifiedAt: Date(timeIntervalSince1970: 300), markSeen: false
        )

        XCTAssertEqual(persistence.state.lastSeenCompletedEntryIDBySessionPath[readPath], "already-read")
        XCTAssertNil(persistence.state.lastSeenCompletedEntryIDBySessionPath[unreadPath])
        XCTAssertTrue(persistence.state.lastReadAt.isEmpty, "Legacy timestamps are discarded after their one migration decision")
    }

    func testCompletionPersistenceIsBoundedAndPrunedToDiscoveredPaths() {
        var state = PersistedAppState()
        for index in 0...PersistedAppState.maxRetainedCompletionSessions {
            state.latestCompletedEntryIDBySessionPath["/tmp/\(index).jsonl"] = "answer-\(index)"
        }
        state.pruneCompletionState(preferredPath: "/tmp/preferred.jsonl")
        XCTAssertLessThanOrEqual(
            state.latestCompletedEntryIDBySessionPath.count,
            PersistedAppState.maxRetainedCompletionSessions
        )

        state.latestCompletedEntryIDBySessionPath["/tmp/preferred.jsonl"] = "answer"
        state.lastSeenCompletedEntryIDBySessionPath["/tmp/preferred.jsonl"] = "answer"
        state.pruneCompletionState(retaining: ["/tmp/preferred.jsonl"])
        XCTAssertEqual(state.latestCompletedEntryIDBySessionPath, ["/tmp/preferred.jsonl": "answer"])
        XCTAssertEqual(state.lastSeenCompletedEntryIDBySessionPath, ["/tmp/preferred.jsonl": "answer"])
    }

    func testGlobalWorkingDirectoryIsDesktop() {
        XCTAssertEqual(
            WorkspaceOrganization.globalWorkingDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        )
        XCTAssertTrue(WorkspaceOrganization.isGlobalWorkingDirectory(WorkspaceOrganization.globalWorkingDirectory))
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
