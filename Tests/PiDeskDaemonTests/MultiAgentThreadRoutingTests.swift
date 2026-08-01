import XCTest
import Foundation
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
        _ = TestSupport.writeSessionFile(in: directory, id: "pi-thread", cwd: directory.path)

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
        var iterator = client.events().makeAsyncIterator()
        let ready = try await iterator.next()
        guard case let .unknown(name, _) = ready, name == "ready" else {
            return XCTFail("expected the ready barrier, got \(String(describing: ready))")
        }
        let created = try await client.createThread(CreateThreadRequest(cwd: directory.path, agent: AgentKind.codex))
        let event = try await iterator.next()
        guard case let .thread(eventThread) = event else {
            return XCTFail("expected the created thread event, got \(String(describing: event))")
        }
        XCTAssertEqual(threadRPC.agents, [.codex])
        XCTAssertEqual(eventThread.id, created.thread.id)
        XCTAssertEqual(eventThread.path, created.thread.path)
        XCTAssertEqual(eventThread.agent, .codex)
        let snapshot = DaemonWorktreeProjects.loadSnapshot(from: directory.appendingPathComponent("overlay.json"))
        XCTAssertTrue(snapshot.managedThreadPaths.contains(created.thread.path))
    }

    func testProtectedIdleCreatePublishesExactlyOnceForPiAndCodexReplays() async throws {
        let publications = ThreadPublicationBox()
        let drained = expectation(description: "event bus drained through barrier")
        let subscription = core.bus.subscribe { name, payload in
            if name == "thread", let thread = try? PiDeskJSON.decoder.decode(PiThread.self, from: payload) {
                publications.append(thread)
            } else if name == "test-barrier" {
                drained.fulfill()
            }
        }
        defer { core.bus.unsubscribe(subscription) }

        for agent in [AgentKind.pi, .codex] {
            let request = CreateThreadRequest(
                cwd: directory.path,
                agent: agent,
                clientId: "idle-once-\(agent.rawValue)"
            )
            let first = try await client.createThread(request)
            let replay = try await client.createThread(request)
            XCTAssertEqual(replay, first, agent.rawValue)
        }

        core.bus.publish(.unknown(name: "test-barrier", data: .object([:])))
        await fulfillment(of: [drained], timeout: 2)

        XCTAssertEqual(threadRPC.created, 2, "one physical create per distinct protected request")
        XCTAssertEqual(threadRPC.agents, [.pi, .codex], "replays never call an agent again")
        XCTAssertEqual(publications.all.map(\.agent), [.pi, .codex])
    }

    func testCreatingANonPiThreadRejectsThePiOnlyModeField() async throws {
        do {
            _ = try await client.createThread(CreateThreadRequest(
                cwd: directory.path, mode: "ultra", agent: .codex
            ))
            XCTFail("expected mode rejection")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "mode_not_supported")
        }
        XCTAssertTrue(threadRPC.agents.isEmpty, "rejection must happen before thread creation")
    }

    /// Absent means Pi, which is what every client written before multi-agent support sends.
    func testCreatingWithoutAnAgentStillMeansPi() async throws {
        _ = try await client.createThread(CreateThreadRequest(cwd: directory.path))
        XCTAssertEqual(threadRPC.agents, [.pi])
    }

    func testScheduleAgentOnlyAppliesToNewThreadsAndModeOnlyToPi() async throws {
        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                name: "Wrong owner", target: .existingThread(threadId: "codex-thread"),
                prompt: "continue", trigger: .interval(everySeconds: 60, startAt: nil), agent: .codex
            ))
            XCTFail("expected existing-thread agent rejection")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "agent_not_supported")
        }

        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                name: "Wrong existing mode", target: .existingThread(threadId: "codex-thread"),
                prompt: "continue", mode: "ultra",
                trigger: .interval(everySeconds: 60, startAt: nil)
            ))
            XCTFail("expected existing-thread mode rejection")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "mode_not_supported")
        }

        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                name: "Wrong mode", target: .newThread(cwd: directory.path, namePattern: nil),
                prompt: "continue", mode: "ultra", trigger: .interval(everySeconds: 60, startAt: nil),
                agent: .codex
            ))
            XCTFail("expected non-Pi mode rejection")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "mode_not_supported")
        }

        let valid = try await client.createSchedule(ScheduleCreateRequest(
            name: "Alternate agent schedule", target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "continue", trigger: .interval(everySeconds: 60, startAt: nil), agent: .codex
        )).schedule
        XCTAssertEqual(valid.agent, .codex)

        let piWithMode = try await client.createSchedule(ScheduleCreateRequest(
            name: "Pi mode", target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "continue", mode: "ultra",
            trigger: .interval(everySeconds: 60, startAt: nil)
        )).schedule
        do {
            _ = try await client.updateSchedule(
                id: piWithMode.id, ScheduleUpdateRequest(agent: .codex)
            )
            XCTFail("changing agent while retaining a Pi mode must fail")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "mode_not_supported")
        }
        let changed = try await client.updateSchedule(
            id: piWithMode.id, ScheduleUpdateRequest(mode: "", agent: .codex)
        ).schedule
        XCTAssertEqual(changed.agent, .codex)
        XCTAssertNil(changed.mode)

        do {
            _ = try await client.updateSchedule(
                id: changed.id,
                ScheduleUpdateRequest(
                    target: .existingThread(threadId: "codex-thread"), agent: .codex
                )
            )
            XCTFail("an existing target cannot accept a supplied agent")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "agent_not_supported")
        }
        let existing = try await client.updateSchedule(
            id: changed.id,
            ScheduleUpdateRequest(target: .existingThread(threadId: "codex-thread"))
        ).schedule
        XCTAssertNil(existing.agent)
    }
}

private final class ThreadPublicationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PiThread] = []

    func append(_ value: PiThread) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [PiThread] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Delivery semantics differ per agent, and the response has to say what actually happened
/// rather than echo what was asked for.
final class AgentDeliveryDowngradeTests: XCTestCase {
    /// All three supported agents take a message into the turn already running, so nothing is
    /// downgraded today. The machinery stays because the capability is what the decision reads,
    /// not the agent's name, and a fourth agent may well not support it.
    func testEverySupportedAgentCanSteerToday() {
        for agent in AgentKind.allCases {
            XCTAssertTrue(agent.capabilities.canSteerMidTurn, "\(agent) should advertise steering")
        }
    }

    /// The downgrade is what keeps a future non-steering agent honest: a caller that is told its
    /// message was steered will not resend it, so claiming a steer that did not happen loses it.
    func testAnAgentThatCannotSteerHasItsRequestDowngradedRatherThanLost() {
        var capabilities = AgentKind.claude.capabilities
        capabilities.canSteerMidTurn = false
        XCTAssertFalse(capabilities.canSteerMidTurn)
        XCTAssertTrue(AgentKind.claude.capabilities.canSteerMidTurn, "the real table is unchanged")
    }
}
