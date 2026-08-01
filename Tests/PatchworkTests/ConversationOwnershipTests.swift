import PatchworkKit
import XCTest
@testable import Patchwork

/// An agent's session directory also holds work started in a terminal, in another desktop app,
/// or by an automation. Driving one of those from here means two processes writing one
/// transcript, so the sidebar lists only what this app started unless asked otherwise.
final class ConversationOwnershipTests: XCTestCase {
    private final class StubRepository: SessionRepositoryProtocol {
        let rootURL = URL(fileURLWithPath: "/tmp/pi-sessions")
        var summaries: [SessionSummary] = []
        func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { summaries }
        func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary] {
            summaries
        }
        func loadConversation(from fileURL: URL) async throws -> SessionConversation {
            SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
        }
        func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private func summary(_ path: String, agent: AgentKind = .pi) -> SessionSummary {
        var value = SessionSummary(
            id: path, fileURL: URL(fileURLWithPath: path), cwd: URL(fileURLWithPath: "/tmp/p"),
            createdAt: Date(), modifiedAt: Date(), name: path, preview: "", messageCount: 1,
            model: nil, provider: nil, thinkingLevel: nil, metrics: TokenMetrics()
        )
        value.agent = agent
        return value
    }

    private func makeStore(_ repository: StubRepository, base: URL) async -> AppStore {
        await AppStore(
            repository: repository, gitService: StubGit(),
            persistence: AppPersistence(baseURL: base)
        )
    }

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("own-\(UUID().uuidString)", isDirectory: true)
    }

    func testOnlyAppStartedConversationsAreListed() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = StubRepository()
        repository.summaries = [summary("/tmp/ours.jsonl"), summary("/tmp/theirs.jsonl", agent: .codex)]

        let persistence = await MainActor.run { AppPersistence(baseURL: base) }
        await MainActor.run { persistence.recordAppStarted(sessionPath: "/tmp/ours.jsonl") }

        let store = await AppStore(repository: repository, gitService: StubGit(), persistence: persistence)
        await store.refreshSessions()
        await MainActor.run {
            XCTAssertEqual(store.sessions.map(\.id), ["/tmp/ours.jsonl"])
            XCTAssertEqual(store.hiddenForeignCount, 1, "the hidden ones must be counted, not forgotten")
        }
    }

    /// The count is what the sidebar offers to reveal, so it has to be right before the toggle
    /// is flipped and zero afterwards.
    func testShowingForeignConversationsListsEverythingAndClearsTheCount() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = StubRepository()
        repository.summaries = [summary("/tmp/a.jsonl"), summary("/tmp/b.jsonl"), summary("/tmp/c.jsonl")]
        let store = await makeStore(repository, base: base)

        await store.refreshSessions()
        await MainActor.run {
            XCTAssertTrue(store.sessions.isEmpty, "nothing was started by this app")
            XCTAssertEqual(store.hiddenForeignCount, 3)
            store.setShowsForeignConversations(true)
        }
        await settle(store)
        await store.refreshSessions()
        await MainActor.run {
            XCTAssertEqual(store.sessions.count, 3)
            XCTAssertEqual(store.hiddenForeignCount, 0)
        }
    }

    func testThePreferenceSurvivesARelaunch() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = await makeStore(StubRepository(), base: base)
        await MainActor.run { store.setShowsForeignConversations(true) }
        await settle(store)

        let reopened = await makeStore(StubRepository(), base: base)
        await MainActor.run { XCTAssertTrue(reopened.showsForeignConversations) }
    }

    /// Ownership is recorded by path and must survive a relaunch, or every conversation the app
    /// started would look foreign the next morning.
    func testRecordedOwnershipSurvivesARelaunch() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        await MainActor.run {
            let persistence = AppPersistence(baseURL: base)
            persistence.recordAppStarted(sessionPath: "/tmp/x/../x/ours.jsonl")
        }
        await MainActor.run {
            let reopened = AppPersistence(baseURL: base)
            XCTAssertTrue(
                reopened.state.appStartedSessionPaths.contains("/tmp/x/ours.jsonl"),
                "paths are standardized on the way in so a lookup cannot miss on spelling"
            )
        }
    }

    func testTheOwnershipRecordIsBounded() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        await MainActor.run {
            let persistence = AppPersistence(baseURL: base)
            for index in 0...(AppPersistence.maxAppStartedPaths + 50) {
                persistence.recordAppStarted(sessionPath: "/tmp/s\(index).jsonl")
            }
            XCTAssertLessThanOrEqual(
                persistence.state.appStartedSessionPaths.count, AppPersistence.maxAppStartedPaths
            )
        }
    }

    private func settle(_ store: AppStore) async {
        for _ in 0..<100 {
            if await MainActor.run(body: { !store.isScanning }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct StubGit: GitStatusProviding {
    func snapshot(for url: URL) async -> GitSnapshot { .none }
    func worktree(for url: URL) async -> GitWorktreeInfo? { nil }
}
