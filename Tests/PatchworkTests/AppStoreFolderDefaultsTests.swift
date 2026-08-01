import PatchworkKit
import Foundation
import XCTest
@testable import Patchwork

// MARK: - Fakes

private final class FakeRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    private(set) var startedCwd: URL?
    func start(cwd: URL, sessionPath: URL?) throws {
        startedCwd = cwd
        isRunning = true
    }
    func stop() { isRunning = false }
    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {}
    func sendUncorrelated(_ value: JSONValue) {}
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/patchwork-folder-default-tests")
    var sessions: [SessionSummary] = []
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { sessions }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary { throw CancellationError() }
}

/// Tracks whether a git snapshot was ever actually requested, independent of what it returns \u2014
/// the point of these tests is that an unopted default folder must never reach this at all.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct FakeGitService: GitStatusProviding {
    let counter: CallCounter
    func snapshot(for directory: URL) async -> GitSnapshot {
        await counter.increment()
        return GitSnapshot(isRepository: true, branch: "should-only-appear-once-opted-in")
    }
}

@MainActor
final class AppStoreFolderDefaultsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiFolderDefaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var desktopPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
    }

    private func makeStore(counter: CallCounter = CallCounter(), runtime: FakeRuntime = FakeRuntime()) -> AppStore {
        AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(counter: counter),
            runtime: runtime,
            persistence: AppPersistence(baseURL: directory)
        )
    }

    // MARK: - Global default

    func testFreshLaunchDefaultsToTheGlobalDesktopWorkingDirectory() {
        let store = makeStore()
        XCTAssertEqual(store.selectedFolder?.standardizedFileURL.path, desktopPath)
    }

    func testALastUsedProjectDoesNotReplaceTheGlobalDefault() throws {
        let persistence = AppPersistence(baseURL: directory)
        let previouslyUsed = directory.appendingPathComponent("previous-project", isDirectory: true)
        try FileManager.default.createDirectory(at: previouslyUsed, withIntermediateDirectories: true)
        persistence.rememberFolder(previouslyUsed)

        let store = AppStore(
            repository: FakeRepository(), gitService: FakeGitService(counter: CallCounter()),
            runtime: FakeRuntime(), persistence: persistence
        )
        XCTAssertEqual(store.selectedFolder?.standardizedFileURL.path, desktopPath)
    }

    func testOpeningNewChatAfterASessionResetsToGlobal() {
        let store = makeStore()
        var session = SessionSummary(
            id: "s", fileURL: directory.appendingPathComponent("s.jsonl"), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: "s", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]
        store.selectSession(session)

        store.openNewChat()
        XCTAssertEqual(store.selectedFolder?.standardizedFileURL.path, desktopPath)
    }

    func testGlobalSubmissionStartsPiFromDesktop() {
        let runtime = FakeRuntime()
        let store = makeStore(runtime: runtime)
        store.draft = "hello"

        store.submitDraft()

        XCTAssertEqual(runtime.startedCwd?.standardizedFileURL.path, desktopPath)
    }

    func testArchivingTheSelectedConversationOpensTheNextActiveConversation() async {
        let store = makeStore()
        store.cachedScheduleService = InMemoryScheduleService()
        func session(_ id: String, archived: Bool = false) -> SessionSummary {
            var value = SessionSummary(
                id: id, fileURL: directory.appendingPathComponent("\(id).jsonl"), cwd: directory,
                createdAt: Date(), modifiedAt: Date(), name: id, preview: "",
                messageCount: 0, metrics: TokenMetrics(), isArchived: archived
            )
            value.prepareSearchKey()
            return value
        }
        let current = session("current")
        store.sessions = [current, session("archived", archived: true), session("next")]
        store.selectSession(current)

        await store.requestArchive(current)

        XCTAssertTrue(store.sessions[0].isArchived)
        XCTAssertEqual(store.selectedSession?.id, "next")
    }

    func testFolderChoicesContainKnownProjectsOnceButNeverGlobalDesktop() throws {
        let store = makeStore()
        func session(_ id: String, cwd: URL) -> SessionSummary {
            var value = SessionSummary(
                id: id, fileURL: directory.appendingPathComponent("\(id).jsonl"), cwd: cwd,
                createdAt: Date(), modifiedAt: Date(), name: id, preview: "",
                messageCount: 0, metrics: TokenMetrics()
            )
            value.prepareSearchKey()
            return value
        }
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let imported = directory.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        store.importProjectFolder(imported)
        let filedProjectSession = session("project-a", cwd: project)
        store.sessions = [
            session("global", cwd: WorkspaceOrganization.globalWorkingDirectory),
            filedProjectSession,
            session("project-b", cwd: project)
        ]
        let virtualFolder = try XCTUnwrap(store.createVirtualFolder(named: "Filed"))
        store.moveSession(filedProjectSession, toVirtualFolder: virtualFolder.id)

        XCTAssertEqual(
            store.sidebarFolders.map(\.standardizedFileURL.path),
            [imported.standardizedFileURL.path, project.standardizedFileURL.path]
        )

        let restored = makeStore()
        XCTAssertEqual(restored.sidebarFolders.map(\.path), [imported.standardizedFileURL.path])
    }

    func testDaemonWorktreeMappingKeepsCLIThreadUnderItsSourceProject() async throws {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let worktree = directory.appendingPathComponent("worktrees/task", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cli.jsonl")
        var session = SessionSummary(
            id: "cli", fileURL: file, cwd: worktree,
            createdAt: Date(), modifiedAt: Date(), name: "CLI", preview: "",
            messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        let overlay = directory.appendingPathComponent("daemon-overlay.json")
        let payload: [String: Any] = [
            "managedWorktreeProjects": [worktree.path: project.path],
            "managedThreadPaths": [file.path]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: overlay)
        let store = AppStore(
            repository: FakeRepository(sessions: [session]),
            gitService: FakeGitService(counter: CallCounter()), runtime: FakeRuntime(),
            persistence: AppPersistence(baseURL: directory),
            daemonThreadOverlayURL: overlay
        )
        await store.refreshSessions()

        XCTAssertEqual(store.sessions.map(\.id), ["cli"], "control-plane threads are native-owned even after an offline create")
        XCTAssertEqual(store.managedWorktreeProjects[worktree.path], project.path)
        XCTAssertEqual(store.sidebarFolders.map(\.path), [project.path])
    }

    func testDaemonThreadEventsInsertOnceAndApplyArchiveByPath() {
        let path = directory.appendingPathComponent("external.jsonl").path
        let overlay = directory.appendingPathComponent("daemon-overlay.json")
        func writeOverlay(archived: Bool) throws {
            let payload: [String: Any] = [
                "managedThreadPaths": [path],
                "archivedThreadPaths": archived ? [path] : []
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: overlay)
        }
        XCTAssertNoThrow(try writeOverlay(archived: false))
        let store = AppStore(
            repository: FakeRepository(), gitService: FakeGitService(counter: CallCounter()),
            runtime: FakeRuntime(), persistence: AppPersistence(baseURL: directory),
            daemonWorktreeProjectsURL: overlay
        )
        var thread = PatchworkThread(
            id: "external", path: path, name: "From CLI", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date(), agent: .claude
        )

        store.applyDaemonThreadUpdate(
            thread, daemonOverlay: DaemonWorktreeProjects.loadSnapshot(from: overlay)
        )
        store.applyDaemonThreadUpdate(
            thread, daemonOverlay: DaemonWorktreeProjects.loadSnapshot(from: overlay)
        )
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.agent, .claude)
        XCTAssertEqual(store.sessions.first?.name, "From CLI")

        thread.archived = true
        XCTAssertNoThrow(try writeOverlay(archived: true))
        store.applyDaemonThreadUpdate(
            thread, daemonOverlay: DaemonWorktreeProjects.loadSnapshot(from: overlay)
        )
        XCTAssertEqual(store.sessions.first?.isArchived, true)
        thread.archived = false
        XCTAssertNoThrow(try writeOverlay(archived: false))
        store.applyDaemonThreadUpdate(
            thread, daemonOverlay: DaemonWorktreeProjects.loadSnapshot(from: overlay)
        )
        XCTAssertEqual(store.sessions.first?.isArchived, false)
    }

    func testWorktreeKeepsTheProjectSelectedButStartsPiInsideTheWorktree() async throws {
        let project = directory.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertEqual(GitService.run(["-C", project.path, "init", "-q"]).status, 0)
        XCTAssertEqual(GitService.run(["-C", project.path, "config", "user.email", "patchwork@example.invalid"]).status, 0)
        XCTAssertEqual(GitService.run(["-C", project.path, "config", "user.name", "Patchwork Tests"]).status, 0)
        try Data("one\n".utf8).write(to: project.appendingPathComponent("sample.txt"))
        XCTAssertEqual(GitService.run(["-C", project.path, "add", "sample.txt"]).status, 0)
        XCTAssertEqual(GitService.run(["-C", project.path, "commit", "-q", "-m", "initial"]).status, 0)

        var worktree: URL?
        defer {
            if let worktree {
                _ = GitService.run(["-C", project.path, "worktree", "remove", "--force", worktree.path])
            }
        }
        let runtime = FakeRuntime()
        let store = makeStore(runtime: runtime)
        store.chooseFolder(project)

        store.setNewChatWorktree(true)
        try await waitUntil { store.newChatWorktree != nil }
        let createdWorktree = try XCTUnwrap(store.newChatWorktree)
        worktree = createdWorktree

        XCTAssertEqual(store.selectedFolder?.standardizedFileURL.path, project.standardizedFileURL.path)
        XCTAssertEqual(store.managedWorktreeProjects[createdWorktree.standardizedFileURL.path], project.standardizedFileURL.path)

        store.draft = "hello"
        store.submitDraft()

        XCTAssertEqual(runtime.startedCwd?.standardizedFileURL.path, createdWorktree.standardizedFileURL.path)
    }

    // MARK: - Git refresh stays lazy until the folder is opted into

    func testTheGlobalDesktopFolderNeverTriggersAGitSubprocessOnItsOwn() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter)

        store.refreshSelectedGit()
        // A bounded wait for a negative assertion: long enough that a wrongly-eager refresh
        // would have shown up, short enough to keep the suite fast.
        try await Task.sleep(nanoseconds: 300_000_000)
        let count = await counter.count
        XCTAssertEqual(count, 0, "Global mode must not inspect Desktop just to draw New Chat")
    }

    func testChoosingAFolderFromThePickerOptsItIntoGitRefresh() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter)
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        store.chooseFolder(chosen)
        try await waitUntil { await counter.count > 0 }
        XCTAssertEqual(store.selectedGit.branch, "should-only-appear-once-opted-in")
    }

    func testAnExistingGlobalConversationStillSkipsDesktopGitInspection() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter)
        var session = SessionSummary(
            id: "global", fileURL: directory.appendingPathComponent("global.jsonl"),
            cwd: WorkspaceOrganization.globalWorkingDirectory,
            createdAt: Date(), modifiedAt: Date(), name: "global", preview: "",
            messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]

        store.selectSession(session)
        try await Task.sleep(nanoseconds: 300_000_000)
        let count = await counter.count

        XCTAssertEqual(count, 0)
        XCTAssertFalse(store.selectedGit.isRepository)
    }

    func testASessionsOwnCwdAlwaysRefreshesEvenWithoutBeingInRecentFolders() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter)
        var session = SessionSummary(
            id: "s", fileURL: directory.appendingPathComponent("s.jsonl"), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: "s", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]

        store.selectSession(session)
        try await waitUntil { await counter.count > 0 }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}
