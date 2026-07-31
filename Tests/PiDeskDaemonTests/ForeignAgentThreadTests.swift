import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// The daemon reads every agent's threads but can only *drive* Pi. The dangerous half of that is
/// the driving half: `pi --mode rpc --session <path>` pointed at a Codex rollout or a Claude
/// transcript would have Pi append its own records to another agent's file. Every route that can
/// reach a runtime therefore has to refuse before it attaches, not after.
final class ForeignAgentThreadTests: XCTestCase {
    private var directory: URL!
    private var codexRoot: URL!
    private var core: DaemonCore!
    private var server: HTTPServer!
    private var client: PiDeskClient!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestSupport.tempDirectory()
        codexRoot = directory.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        TestSupport.writeCodexRollout(in: codexRoot, id: "codex-thread", cwd: "/tmp/project")
        TestSupport.writeSessionFile(in: directory, id: "pi-thread", cwd: "/tmp/project")

        core = TestSupport.makeCore(in: directory, extraSessionRoots: [(.codex, codexRoot)])
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

    // MARK: - Reading works

    func testBothAgentsThreadsAreListedAndTagged() async throws {
        let threads = try await client.listThreads().threads
        XCTAssertEqual(Set(threads.map(\.id)), ["pi-thread", "codex-thread"])
        XCTAssertEqual(threads.first { $0.id == "codex-thread" }?.agent, .codex)
        XCTAssertEqual(threads.first { $0.id == "pi-thread" }?.agent, .pi)
    }

    func testAForeignThreadsTranscriptIsReadable() async throws {
        let detail = try await client.getThread(id: "codex-thread")
        XCTAssertEqual(detail.thread.agent, .codex)
        XCTAssertTrue(
            detail.messages.contains { $0.text.contains("a codex question") },
            "reading another agent's transcript must work"
        )
    }

    func testTheAgentFilterSelectsOneAgent() async throws {
        let codex = try await client.listThreads(agent: .codex).threads
        XCTAssertEqual(codex.map(\.id), ["codex-thread"])
        let pi = try await client.listThreads(agent: .pi).threads
        XCTAssertEqual(pi.map(\.id), ["pi-thread"])
    }

    // MARK: - Driving refuses

    /// The regression this file exists for: all three runtime routes funnel into one helper, and
    /// its idle path attaches Pi to `thread.path`.
    func testEveryRuntimeRouteRefusesAForeignThreadBeforeAttaching() async throws {
        await assertAgentUnsupported { try await self.client.threadRuntime(id: "codex-thread") }
        await assertAgentUnsupported {
            try await self.client.setThreadModel(id: "codex-thread", SetThreadModelRequest(provider: "openai", modelId: "gpt-5"))
        }
        await assertAgentUnsupported {
            try await self.client.setThreadThinking(id: "codex-thread", SetThreadThinkingRequest(level: "high"))
        }
    }

    func testRenamingAForeignThreadIsRefused() async throws {
        await assertAgentUnsupported { try await self.client.renameThread(id: "codex-thread", name: "new") }
    }

    func testCreatingAForeignThreadIsRefused() async throws {
        await assertAgentUnsupported {
            try await self.client.createThread(
                CreateThreadRequest(cwd: "/tmp/project", agent: AgentKind.codex)
            )
        }
    }

    /// The guard is about the agent, not about having broken the endpoints: a Pi thread gets
    /// past it and fails only for its own reasons. Asserted as "not agent_unsupported" rather
    /// than as success, because succeeding would mean launching a real `pi` — which these tests
    /// never do.
    func testPiThreadsGetPastTheAgentGuard() async throws {
        for operation in [
            { try await self.client.renameThread(id: "pi-thread", name: "renamed") as Any },
            { try await self.client.threadRuntime(id: "pi-thread") as Any }
        ] {
            do {
                _ = try await operation()
            } catch let error as PiDeskClientError {
                switch error {
                case let .badRequest(code, _), let .server(_, code, _):
                    XCTAssertNotEqual(code, "agent_unsupported", "a Pi thread must reach its runtime")
                default:
                    break
                }
            }
        }
    }

    private func assertAgentUnsupported(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected agent_unsupported", file: file, line: line)
        } catch let error as PiDeskClientError {
            switch error {
            case let .badRequest(code, _), let .server(_, code, _):
                XCTAssertEqual(code, "agent_unsupported", file: file, line: line)
            default:
                XCTFail("expected agent_unsupported, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected an API error, got \(error)", file: file, line: line)
        }
    }
}
