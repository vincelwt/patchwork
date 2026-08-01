import PatchworkKit
import XCTest
@testable import Patchwork

/// Switching an agent off has to stop it being *read*, not just hidden: its transcripts are the
/// expensive part, and on a machine with a large Codex history that is most of the scan.
final class AgentEnablementTests: XCTestCase {
    private final class RecordingRepository: SessionRepositoryProtocol {
        let rootURL = URL(fileURLWithPath: "/tmp/pi-sessions")
        /// Boxed so a test can tell "asked for everything" (nil) apart from "asked for nothing".
        private(set) var requestedAgents: [Set<AgentKind>?] = []
        var lastRequest: Set<AgentKind>?? { requestedAgents.last }

        func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }

        func discoverSessions(archivedIDs: Set<String>, agents: Set<AgentKind>?) async throws -> [SessionSummary] {
            requestedAgents.append(agents)
            return []
        }

        func loadConversation(from fileURL: URL) async throws -> SessionConversation {
            SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
        }

        func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    /// The default filter narrows nothing, so an untouched install pays no extra cost.
    func testNothingIsFilteredWhenEveryAgentIsEnabled() async throws {
        let repository = RecordingRepository()
        let store = await AppStore(repository: repository, gitService: StubGitService())
        await store.refreshSessions()
        let recorded = try XCTUnwrap(repository.lastRequest, "discovery should have been called")
        XCTAssertNil(recorded, "no narrowing when nothing is switched off")
    }

    func testDisablingAnAgentNarrowsDiscoveryAndSurvivesRelaunch() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("enablement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = RecordingRepository()
        let store = await AppStore(
            repository: repository, gitService: StubGitService(), persistence: AppPersistence(baseURL: base)
        )
        await MainActor.run { store.setAgent(.codex, enabled: false) }
        // `setAgent` kicks off its own rescan; wait for the store to settle before asking again,
        // so this asserts on a completed pass rather than racing one.
        await settle(store)
        await store.refreshSessions()

        let requested = try XCTUnwrap(try XCTUnwrap(repository.lastRequest))
        XCTAssertFalse(requested.contains(.codex))
        XCTAssertTrue(requested.contains(.pi))
        await MainActor.run {
            XCTAssertTrue(store.disabledAgents.contains(.codex))
            XCTAssertFalse(store.installedAgents.contains(.codex))
        }

        // A relaunch reads the same preferences file.
        let reopened = await AppStore(
            repository: RecordingRepository(), gitService: StubGitService(),
            persistence: AppPersistence(baseURL: base)
        )
        await MainActor.run { XCTAssertTrue(reopened.disabledAgents.contains(.codex)) }
    }

    /// Disabling the agent a pending new chat was going to use must not leave it selected.
    func testDisablingTheSelectedNewChatAgentMovesTheSelection() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("enablement-sel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = await AppStore(
            repository: RecordingRepository(), gitService: StubGitService(),
            persistence: AppPersistence(baseURL: base)
        )
        await MainActor.run {
            let chosen = store.newChatAgent
            store.setAgent(chosen, enabled: false)
            XCTAssertNotEqual(store.newChatAgent, chosen)
            XCTAssertFalse(store.disabledAgents.contains(store.newChatAgent))
        }
    }

    func testTogglingIsIdempotent() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("enablement-idem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = await AppStore(
            repository: RecordingRepository(), gitService: StubGitService(),
            persistence: AppPersistence(baseURL: base)
        )
        await MainActor.run {
            store.setAgent(.claude, enabled: false)
            store.setAgent(.claude, enabled: false)
            XCTAssertEqual(store.disabledAgents.filter { $0 == .claude }.count, 1)
            store.setAgent(.claude, enabled: true)
            XCTAssertFalse(store.disabledAgents.contains(.claude))
        }
    }
}

private extension AgentEnablementTests {
    /// Waits out any scan already in flight, bounded so a hang fails the test rather than the run.
    func settle(_ store: AppStore) async {
        for _ in 0..<100 {
            if await MainActor.run(body: { !store.isScanning }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct StubGitService: GitStatusProviding {
    func snapshot(for url: URL) async -> GitSnapshot { .none }
    func worktree(for url: URL) async -> GitWorktreeInfo? { nil }
}

/// `PersistedAppState` decodes explicitly, field by field, so a property added without a line in
/// `init(from:)` is written to disk and silently read back as its default. That had already
/// happened to three fields before this test existed.
final class PersistedAppStateRoundTripTests: XCTestCase {
    func testEveryAgentFieldSurvivesARoundTrip() throws {
        var state = PersistedAppState()
        state.lastAgent = "claude"
        state.agentModes = ["pi": "ultra", "codex": "workspace-write"]
        state.disabledAgents = ["codex"]
        state.lastFolder = "/tmp/project"

        let decoded = try JSONDecoder().decode(
            PersistedAppState.self, from: try JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded.lastAgent, "claude")
        XCTAssertEqual(decoded.agentModes, ["pi": "ultra", "codex": "workspace-write"])
        XCTAssertEqual(decoded.disabledAgents, ["codex"])
        XCTAssertEqual(decoded.lastFolder, "/tmp/project")
    }

    /// A preferences file written before these fields existed still decodes.
    func testAPreMultiAgentStateFileStillDecodes() throws {
        let legacy = Data(#"{"archivedSessionIDs":[],"recentFolders":["/tmp/x"]}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedAppState.self, from: legacy)
        XCTAssertEqual(decoded.recentFolders, ["/tmp/x"])
        XCTAssertNil(decoded.lastAgent)
        XCTAssertTrue(decoded.agentModes.isEmpty)
        XCTAssertTrue(decoded.disabledAgents.isEmpty)
    }
}
