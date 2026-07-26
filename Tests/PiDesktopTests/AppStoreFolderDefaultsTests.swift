import Foundation
import XCTest
@testable import PiDesktop

// MARK: - Fakes

private final class FakeRuntime: PiRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }
    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {}
    func sendUncorrelated(_ value: JSONValue) {}
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/pi-desktop-folder-default-tests")
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
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

    private func makeStore(counter: CallCounter = CallCounter()) -> AppStore {
        AppStore(
            repository: FakeRepository(),
            gitService: FakeGitService(counter: counter),
            runtime: FakeRuntime(),
            persistence: AppPersistence(baseURL: directory)
        )
    }

    // MARK: - Default folder never touches a protected location

    func testFreshLaunchWithNoRecentFoldersDefaultsToHomeDirectoryNeverDesktop() {
        let store = makeStore()
        XCTAssertNotEqual(store.selectedFolder?.standardizedFileURL.path, desktopPath, "Never defaults to a TCC-protected folder")
        XCTAssertEqual(
            store.selectedFolder?.standardizedFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
            "Falls back to the plain home directory, which carries no permission prompt"
        )
    }

    func testALastUsedFolderIsPreferredOverTheHomeDirectoryDefault() throws {
        let persistence = AppPersistence(baseURL: directory)
        let previouslyUsed = directory.appendingPathComponent("previous-project", isDirectory: true)
        try FileManager.default.createDirectory(at: previouslyUsed, withIntermediateDirectories: true)
        persistence.rememberFolder(previouslyUsed)

        let store = AppStore(
            repository: FakeRepository(), gitService: FakeGitService(counter: CallCounter()),
            runtime: FakeRuntime(), persistence: persistence
        )
        XCTAssertEqual(store.selectedFolder?.standardizedFileURL.path, previouslyUsed.standardizedFileURL.path)
    }

    func testOpeningNewChatAfterASessionKeepsTheSameSafeDefaultNeverDesktop() {
        let store = makeStore()
        var session = SessionSummary(
            id: "s", fileURL: directory.appendingPathComponent("s.jsonl"), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: "s", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]
        store.selectSession(session)

        store.openNewChat()
        XCTAssertNotEqual(store.selectedFolder?.standardizedFileURL.path, desktopPath)
    }

    // MARK: - Git refresh stays lazy until the folder is opted into

    func testTheDefaultFolderNeverTriggersAGitSubprocessOnItsOwn() async throws {
        let counter = CallCounter()
        let store = makeStore(counter: counter)

        store.refreshSelectedGit()
        // A bounded wait for a negative assertion: long enough that a wrongly-eager refresh
        // would have shown up, short enough to keep the suite fast.
        try await Task.sleep(nanoseconds: 300_000_000)
        let count = await counter.count
        XCTAssertEqual(count, 0, "The unopted default folder must never spawn a git subprocess (and risk a TCC prompt)")
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
