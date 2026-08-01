import PatchworkKit
import Foundation
import XCTest
@testable import Patchwork

// MARK: - Pure resolution rule

final class NewChatFolderResolutionTests: XCTestCase {
    private func session(cwd: String, createdAt: Date, file: String = "fresh.jsonl") -> SessionSummary {
        var value = SessionSummary(
            id: "fresh", fileURL: URL(fileURLWithPath: "/tmp/\(file)"), cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            createdAt: createdAt, modifiedAt: createdAt, name: "n", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }

    func testMatchesASessionInTheSameCwdCreatedAtOrAfterArming() {
        let armedAt = Date(timeIntervalSince1970: 1_000)
        let intent = NewChatFolderResolution.Intent(folderID: "focus", cwd: URL(fileURLWithPath: "/tmp/project"), armedAt: armedAt)
        let exact = session(cwd: "/tmp/project", createdAt: armedAt)
        let later = session(cwd: "/tmp/project", createdAt: armedAt.addingTimeInterval(5))
        XCTAssertTrue(NewChatFolderResolution.matches(exact, intent: intent, existingAssignment: nil), "createdAt == armedAt is a match, not just strictly after")
        XCTAssertTrue(NewChatFolderResolution.matches(later, intent: intent, existingAssignment: nil))
    }

    func testRejectsADifferentCwd() {
        let armedAt = Date(timeIntervalSince1970: 1_000)
        let intent = NewChatFolderResolution.Intent(folderID: "focus", cwd: URL(fileURLWithPath: "/tmp/project-a"), armedAt: armedAt)
        let elsewhere = session(cwd: "/tmp/project-b", createdAt: armedAt.addingTimeInterval(5))
        XCTAssertFalse(NewChatFolderResolution.matches(elsewhere, intent: intent, existingAssignment: nil))
    }

    func testMatchesAWorktreeSessionThroughItsProjectFolder() {
        let armedAt = Date(timeIntervalSince1970: 1_000)
        let project = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let intent = NewChatFolderResolution.Intent(folderID: "focus", cwd: project, armedAt: armedAt)
        let worktree = session(cwd: "/tmp/worktree", createdAt: armedAt.addingTimeInterval(5))

        XCTAssertTrue(
            NewChatFolderResolution.matches(
                worktree,
                intent: intent,
                existingAssignment: nil,
                projectFolder: project
            )
        )
    }

    func testRejectsAPreExistingSessionCreatedBeforeTheIntentWasArmed() {
        let armedAt = Date(timeIntervalSince1970: 1_000)
        let intent = NewChatFolderResolution.Intent(folderID: "focus", cwd: URL(fileURLWithPath: "/tmp/project"), armedAt: armedAt)
        let preExisting = session(cwd: "/tmp/project", createdAt: armedAt.addingTimeInterval(-5))
        XCTAssertFalse(
            NewChatFolderResolution.matches(preExisting, intent: intent, existingAssignment: nil),
            "An older conversation in the same folder must never be hijacked by a later intent"
        )
    }

    func testRejectsASessionThatIsAlreadyOrganized() {
        let armedAt = Date(timeIntervalSince1970: 1_000)
        let intent = NewChatFolderResolution.Intent(folderID: "focus", cwd: URL(fileURLWithPath: "/tmp/project"), armedAt: armedAt)
        let alreadyPlaced = session(cwd: "/tmp/project", createdAt: armedAt.addingTimeInterval(5))
        XCTAssertFalse(
            NewChatFolderResolution.matches(alreadyPlaced, intent: intent, existingAssignment: "other-folder"),
            "An explicit existing assignment always wins over this best-effort guess"
        )
    }
}

// MARK: - AppStore integration: the pending assignment survives to a real session

private final class FakeRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionFile = ""
    var sessionID = ""
    private var promptCompletion: ((Result<JSONValue, Error>) -> Void)?

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        if type == "prompt" {
            promptCompletion = completion
            return
        }
        guard type == "get_state" else { return }
        completion?(.success(.object([
            "success": .bool(true),
            "data": .object([
                "isStreaming": .bool(false),
                "sessionFile": .string(sessionFile),
                "sessionId": .string(sessionID)
            ])
        ])))
    }

    func sendUncorrelated(_ value: JSONValue) {}

    func succeedPrompt() {
        promptCompletion?(.success(.object(["success": .bool(true), "data": .object([:])])))
        promptCompletion = nil
    }

    func rejectPrompt() {
        promptCompletion?(.success(.object([
            "success": .bool(false), "error": .string("prompt rejected")
        ])))
        promptCompletion = nil
    }
}

private struct FakeRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/patchwork-new-chat-folder-tests")
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw CancellationError()
    }
}

private struct FakeGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

@MainActor
final class NewChatFolderIntentIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiNewChatFolderIntent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> (AppStore, FakeRuntime) {
        let runtime = FakeRuntime()
        let store = AppStore(
            repository: FakeRepository(), gitService: FakeGitService(), runtime: runtime,
            persistence: AppPersistence(baseURL: directory)
        )
        return (store, runtime)
    }

    private func existingSession(cwd: URL) -> SessionSummary {
        var value = SessionSummary(
            id: "existing", fileURL: directory.appendingPathComponent("existing.jsonl"), cwd: cwd,
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1),
            name: "existing", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }

    /// The full path this task is actually about: arming a virtual-folder intent, then letting
    /// `AppStore`'s own new-chat machinery (unmodified) create the session, and observing the
    /// assignment land \u2014 with no real Pi process and no provider prompt.
    func testPendingAssignmentAppliesToTheSessionPiCreatesForTheArmedFolder() throws {
        let (store, runtime) = makeStore()
        let folder = try XCTUnwrap(store.createVirtualFolder(named: "Focus"))
        let cwd: URL = directory

        store.openNewChat()
        store.chooseFolder(cwd)
        let intent = NewChatFolderIntent()
        intent.arm(folderID: folder.id, cwd: cwd, store: store)
        XCTAssertEqual(intent.pending?.folderID, folder.id)

        runtime.sessionFile = cwd.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"
        store.draft = "hello from a folder-scoped new chat"
        store.submitDraft()

        let path = cwd.appendingPathComponent("fresh.jsonl").standardizedFileURL.path
        XCTAssertEqual(store.route, .session(path), "AppStore's own promotion logic is untouched")
        XCTAssertEqual(store.virtualFolderAssignments[path], folder.id)
        XCTAssertNil(
            store.persistence.state.virtualFolderAssignments[path],
            "the provisional path must not be persisted before prompt materialization"
        )
        XCTAssertNil(intent.pending, "Resolved exactly once")
    }

    func testPromptSuccessCommitsTheStagedFolderAssignment() throws {
        let (store, runtime) = makeStore()
        let folder = try XCTUnwrap(store.createVirtualFolder(named: "Focus"))
        store.openNewChat()
        store.chooseFolder(directory)
        let intent = NewChatFolderIntent()
        intent.arm(folderID: folder.id, cwd: directory, store: store)
        runtime.sessionFile = directory.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"
        store.draft = "hello"

        store.submitDraft()
        runtime.succeedPrompt()

        let path = URL(fileURLWithPath: runtime.sessionFile).standardizedFileURL.path
        XCTAssertEqual(store.persistence.state.virtualFolderAssignments[path], folder.id)
    }

    func testRejectedPromptKeepsFolderForRetryWithoutPersistingAnOrphan() throws {
        let (store, runtime) = makeStore()
        let folder = try XCTUnwrap(store.createVirtualFolder(named: "Focus"))
        store.openNewChat()
        store.chooseFolder(directory)
        let intent = NewChatFolderIntent()
        intent.arm(folderID: folder.id, cwd: directory, store: store)
        runtime.sessionFile = directory.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"
        store.draft = "first attempt"

        store.submitDraft()
        runtime.rejectPrompt()

        let path = URL(fileURLWithPath: runtime.sessionFile).standardizedFileURL.path
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.persistence.state.virtualFolderAssignments[path])
        XCTAssertEqual(store.virtualFolderAssignments[path], folder.id, "the in-memory retry keeps its intended folder")

        store.submitDraft()
        runtime.succeedPrompt()
        XCTAssertEqual(store.persistence.state.virtualFolderAssignments[path], folder.id)
    }

    func testAbandoningARejectedPromptDiscardsTheStagedFolderAssignment() throws {
        let (store, runtime) = makeStore()
        let folder = try XCTUnwrap(store.createVirtualFolder(named: "Focus"))
        store.openNewChat()
        store.chooseFolder(directory)
        let intent = NewChatFolderIntent()
        intent.arm(folderID: folder.id, cwd: directory, store: store)
        runtime.sessionFile = directory.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"
        store.draft = "first attempt"
        store.submitDraft()
        runtime.rejectPrompt()

        let path = URL(fileURLWithPath: runtime.sessionFile).standardizedFileURL.path
        store.openNewChat()

        XCTAssertNil(store.virtualFolderAssignments[path])
        XCTAssertNil(store.persistence.state.virtualFolderAssignments[path])
    }

    func testAbandoningTheIntentForAnExistingConversationNeverAppliesTheAssignment() throws {
        let (store, _) = makeStore()
        let folder = try XCTUnwrap(store.createVirtualFolder(named: "Focus"))
        let otherCwd = directory.appendingPathComponent("elsewhere", isDirectory: true)
        let elsewhere = existingSession(cwd: otherCwd)
        store.sessions = [elsewhere]

        store.openNewChat()
        store.chooseFolder(directory)
        let intent = NewChatFolderIntent()
        intent.arm(folderID: folder.id, cwd: directory, store: store)

        // The user changes their mind and opens a different, pre-existing conversation instead
        // of sending a message in the folder-scoped new chat.
        store.selectSession(elsewhere)

        XCTAssertNil(store.virtualFolderAssignments[elsewhere.fileURL.standardizedFileURL.path], "An unrelated existing conversation must never be hijacked")
        XCTAssertNil(intent.pending, "The stale intent expires instead of lingering to misfire later")
    }

    func testRearmingBeforeResolutionReplacesThePreviousFolderEntirely() throws {
        let (store, runtime) = makeStore()
        let folderA = try XCTUnwrap(store.createVirtualFolder(named: "A"))
        let folderB = try XCTUnwrap(store.createVirtualFolder(named: "B"))
        let cwd: URL = directory

        store.openNewChat()
        store.chooseFolder(cwd)
        let intent = NewChatFolderIntent()
        intent.arm(folderID: folderA.id, cwd: cwd, store: store)
        // Clicking "+" on a second folder before sending anything re-arms in place.
        intent.arm(folderID: folderB.id, cwd: cwd, store: store)
        XCTAssertEqual(intent.pending?.folderID, folderB.id)

        runtime.sessionFile = cwd.appendingPathComponent("fresh.jsonl").path
        runtime.sessionID = "fresh-session"
        store.draft = "hello"
        store.submitDraft()

        let path = cwd.appendingPathComponent("fresh.jsonl").standardizedFileURL.path
        XCTAssertEqual(store.virtualFolderAssignments[path], folderB.id, "Only the most recent intent ever applies")
    }
}
