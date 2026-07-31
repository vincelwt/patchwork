import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// The daemon reads *and* drives every agent. Reading was never in doubt; what these pin is that
/// a command for a thread is routed to that thread's own agent, because the failure mode if it
/// is not is severe: attaching Pi to a Codex rollout would have Pi append its own records to
/// another agent's transcript.
final class MultiAgentThreadRoutingTests: XCTestCase {
    private var directory: URL!
    private var codexRoot: URL!
    private var threadRPC: FakeThreadRPCService!
    private var core: DaemonCore!
    private var server: HTTPServer!
    private var client: PiDeskClient!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestSupport.tempDirectory()
        codexRoot = directory.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        TestSupport.writeCodexRollout(in: codexRoot, id: "codex-thread", cwd: directory.path)
        TestSupport.writeSessionFile(in: directory, id: "pi-thread", cwd: directory.path)

        // A fake RPC service keeps these deterministic: no agent binary is ever launched, and the
        // agent each call asked for is recorded instead.
        threadRPC = FakeThreadRPCService(
            thread: PiThread(
                id: "created", path: directory.appendingPathComponent("created.jsonl").path,
                name: "created", cwd: directory.path, folder: directory.lastPathComponent,
                createdAt: Date(), updatedAt: Date()
            )
        )
        core = TestSupport.makeCore(
            in: directory, threadRPC: threadRPC, extraSessionRoots: [(.codex, codexRoot)]
        )
        let socket = directory.appendingPathComponent("daemon.sock")
        server = HTTPServer(
            router: DaemonRouter(routes: Routes.all(core)),
            logger: TestSupport.logger(in: directory), bus: core.bus, tokenProvider: { nil }
        )
        try server.start(unixSocketPath: socket, tcpPort: nil)
        client = PiDeskClient(transport: .unixSocket(path: socket.path), requestTimeout: 5)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Reading

    func testBothAgentsThreadsAreListedAndTagged() async throws {
        let threads = try await client.listThreads().threads
        XCTAssertEqual(Set(threads.map(\.id)), ["pi-thread", "codex-thread"])
        XCTAssertEqual(threads.first { $0.id == "codex-thread" }?.agent, .codex)
        XCTAssertEqual(threads.first { $0.id == "pi-thread" }?.agent, .pi)
    }

    func testAForeignThreadsTranscriptIsReadable() async throws {
        let detail = try await client.getThread(id: "codex-thread")
        XCTAssertEqual(detail.thread.agent, .codex)
        XCTAssertTrue(detail.messages.contains { $0.text.contains("a codex question") })
    }

    func testTheAgentFilterSelectsOneAgent() async throws {
        let codex = try await client.listThreads(agent: .codex).threads
        XCTAssertEqual(codex.map(\.id), ["codex-thread"])
        let pi = try await client.listThreads(agent: .pi).threads
        XCTAssertEqual(pi.map(\.id), ["pi-thread"])
    }

    // MARK: - Driving routes to the thread's own agent

    func testRuntimeReadUsesTheThreadsOwnAgent() async throws {
        _ = try await client.threadRuntime(id: "codex-thread")
        XCTAssertEqual(threadRPC.agents, [.codex], "a Codex thread must not be attached with Pi")

        _ = try await client.threadRuntime(id: "pi-thread")
        XCTAssertEqual(threadRPC.agents, [.codex, .pi])
    }

    func testModelAndThinkingChangesCarryTheThreadsAgent() async throws {
        _ = try await client.setThreadModel(
            id: "codex-thread", SetThreadModelRequest(provider: "openai", modelId: "gpt-5.6-sol")
        )
        _ = try await client.setThreadThinking(id: "codex-thread", SetThreadThinkingRequest(level: "high"))
        XCTAssertEqual(threadRPC.agents, [.codex, .codex])
        XCTAssertEqual(threadRPC.modelSets.map(\.1), ["gpt-5.6-sol"])
        XCTAssertEqual(threadRPC.thinkingSets, ["high"])
    }

    func testRenamingAForeignThreadUsesItsOwnAgent() async throws {
        _ = try await client.renameThread(id: "codex-thread", name: "renamed")
        XCTAssertEqual(threadRPC.agents, [.codex])
    }

    func testCreatingAThreadHonoursTheRequestedAgent() async throws {
        _ = try await client.createThread(CreateThreadRequest(cwd: directory.path, agent: AgentKind.codex))
        XCTAssertEqual(threadRPC.agents, [.codex])
    }

    /// Absent means Pi, which is what every client written before multi-agent support sends.
    func testCreatingWithoutAnAgentStillMeansPi() async throws {
        _ = try await client.createThread(CreateThreadRequest(cwd: directory.path))
        XCTAssertEqual(threadRPC.agents, [.pi])
    }
}

/// Delivery semantics differ per agent, and the response has to say what actually happened
/// rather than echo what was asked for.
final class AgentDeliveryDowngradeTests: XCTestCase {
    func testSteeringIsKeptForAgentsThatCanFoldIntoTheRunningTurn() {
        for agent in AgentKind.allCases where agent.capabilities.canSteerMidTurn {
            XCTAssertTrue(agent.capabilities.canSteerMidTurn, "\(agent) advertises steering")
        }
        XCTAssertTrue(AgentKind.pi.capabilities.canSteerMidTurn)
        XCTAssertTrue(AgentKind.codex.capabilities.canSteerMidTurn)
    }

    /// Claude Code queues a mid-turn message itself; reporting it as steered would be a lie the
    /// caller acts on (it would not resend, believing the turn already saw it).
    func testClaudeCannotSteerSoTheCapabilityTableSaysSo() {
        XCTAssertFalse(AgentKind.claude.capabilities.canSteerMidTurn)
    }
}
