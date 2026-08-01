import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// The four parity endpoints, driven straight through `DaemonRouter` — the same code a socket,
/// the loopback listener, and the hosted relay all funnel into, minus the transport. Every run
/// here uses `FakeRunExecutor` and every steer uses `FakeLiveRuntime`: nothing spawns `pi`.
final class RemoteParityEndpointTests: XCTestCase {
    private var directory: URL!
    private var core: DaemonCore!
    private var router: DaemonRouter!
    private var executor: FakeRunExecutor!
    private var interactions: InteractionRegistry!
    private var liveSessions: LiveSessionRegistry!

    private var primaryThreadKey: ThreadInstanceKey {
        ThreadInstanceKey(path: directory.appendingPathComponent("sessions/sess-1.jsonl").path)
    }

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
        executor = FakeRunExecutor()
        interactions = InteractionRegistry()
        liveSessions = LiveSessionRegistry()
        core = TestSupport.makeCore(in: directory, executor: executor, interactions: interactions, liveSessions: liveSessions)
        router = DaemonRouter(routes: Routes.all(core))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func send(_ method: String, _ path: String, body: String? = nil, query: [String: String] = [:]) async -> HTTPResponse {
        await router.handle(HTTPRequest(
            method: method, path: path, query: query, headers: [:],
            body: body.map { Data($0.utf8) } ?? Data(), origin: .unixSocket
        ))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try PiDeskJSON.decoder.decode(type, from: response.body)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static let tinyPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    // MARK: - Delivery

    func testSteerGoesToTheLiveTurnAndIsNeverQueuedBehindIt() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"stop that","delivery":"steer"}"#)
        XCTAssertEqual(response.status, 200)

        let decoded = try decode(SendMessageResponse.self, response)
        XCTAssertEqual(decoded.runId, "run_live", "the answer names the run that was interrupted")
        XCTAssertEqual(decoded.queued, false)
        XCTAssertEqual(decoded.delivery, .steer)
        XCTAssertEqual(runtime.delivered.map(\.command), ["steer"])
        XCTAssertEqual(runtime.delivered.map(\.message), ["stop that"])

        let queued = await core.runQueue.queuedCount()
        let active = await core.runQueue.activeCount()
        XCTAssertEqual(queued + active, 0, "an explicit steer must never become a queued prompt")
    }

    func testFollowUpUsesPisOwnFollowUpCommandWhenALiveTurnExists() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"and also","delivery":"followUp"}"#)
        XCTAssertEqual(try decode(SendMessageResponse.self, response).delivery, .followUp)
        XCTAssertEqual(runtime.delivered.map(\.command), ["follow_up"])
    }

    func testOversizedLiveSteerIsRejectedBeforeWritingToTheRuntime() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)
        let text = String(repeating: "x", count: RunQueue.defaultMaxPromptBytes + 1)
        let body = try String(decoding: PiDeskJSON.encoder.encode(
            SendMessageRequest(text: text, delivery: .steer, clientId: "oversized-live")
        ), as: UTF8.self)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: body)

        XCTAssertEqual(response.status, 413)
        XCTAssertTrue(runtime.delivered.isEmpty)
    }

    func testSteerWithNoLiveTurnIsReportedAsAnOrdinaryPromptNotAsSteering() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello","delivery":"steer"}"#)
        let decoded = try decode(SendMessageResponse.self, response)
        XCTAssertEqual(decoded.delivery, .auto, "there was nothing to interrupt, and the answer says so")
        XCTAssertNotEqual(decoded.runId, "run_live")
        XCTAssertNotNil(decoded.runId, "the text still runs, as a normal prompt")
    }

    func testARejectedSteerIsAConflictAndIsNotSilentlyQueuedInstead() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.result = .rejected("Nothing to steer.")
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","delivery":"steer"}"#)
        XCTAssertEqual(response.status, 409)
        let queued = await core.runQueue.queuedCount()
        XCTAssertEqual(queued, 0)
    }

    func testAnUnacknowledgedSteerIsReportedDeliveredRatherThanResent() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.result = .unacknowledged
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","delivery":"steer"}"#)
        XCTAssertEqual(response.status, 200)
        let queued = await core.runQueue.queuedCount()
        let active = await core.runQueue.activeCount()
        XCTAssertEqual(queued + active, 0, "resending is the one thing that could prompt Pi twice")
    }

    func testAWriteFailureFallsBackToTheQueueBecauseNothingReachedPi() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.throwsWriteFailure = true
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","delivery":"steer"}"#)
        XCTAssertEqual(try decode(SendMessageResponse.self, response).delivery, .auto)
    }

    func testAMessageWithNoDeliveryNeverTouchesTheLiveSession() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        _ = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"plain"}"#)
        XCTAssertTrue(runtime.delivered.isEmpty, "an ordinary prompt still queues, exactly as before")
    }

    // MARK: - Thread creation and runtime controls

    func testCreateWithAFirstMessageReturnsARealThreadBeforeQueueingThePrompt() async throws {
        let file = TestSupport.writeSessionFile(in: directory, id: "created-1", cwd: directory.path)
        let created = PiThread(
            id: "created-1", path: file.path, name: "Web thread", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let threadRPC = FakeThreadRPCService(thread: created)
        executor = FakeRunExecutor()
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","name":"Web thread","message":"hello","mode":"smart","clientId":"create-pi"}"#
        )
        XCTAssertEqual(response.status, 202)
        let decoded = try decode(CreateThreadResponse.self, response)
        XCTAssertEqual(decoded.thread.id, "created-1")
        XCTAssertFalse(decoded.thread.id.hasPrefix("pending:"))
        XCTAssertEqual(threadRPC.created, 1)

        try await settle()
        let job = try XCTUnwrap(executor.executedJobs.first)
        guard case let .existingThread(threadId, path, cwd, _) = job.target else {
            return XCTFail("the first prompt must target the resolved session")
        }
        XCTAssertEqual(threadId, "created-1")
        XCTAssertEqual(path, file.path)
        XCTAssertEqual(cwd, directory.path)
        XCTAssertEqual(job.prompt, "hello")
        XCTAssertEqual(job.mode, "smart")
    }

    func testCreateReportsUnknownAndNeverDuplicatesWhenOwnershipCannotPersist() async throws {
        let file = TestSupport.writeSessionFile(
            in: directory, id: "ownership-unknown", cwd: directory.path
        )
        let created = PiThread(
            id: "ownership-unknown", path: file.path, name: "Ownership unknown",
            cwd: directory.path, folder: directory.lastPathComponent,
            createdAt: Date(), updatedAt: Date()
        )
        let overlayURL = directory.appendingPathComponent("overlay.json")
        try Data("{}".utf8).write(to: overlayURL)
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: overlayURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: overlayURL.path
            )
        }
        let threadRPC = FakeThreadRPCService(thread: created)
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))
        let body = #"{"cwd":"\#(directory.path)","name":"Ownership unknown","clientId":"ownership-failure"}"#

        let first = await send("POST", "/v1/threads", body: body)
        let replay = await send("POST", "/v1/threads", body: body)

        XCTAssertEqual(first.status, 409)
        XCTAssertTrue(
            String(decoding: first.body, as: UTF8.self).contains("creation_outcome_unknown")
        )
        XCTAssertEqual(replay.status, 409)
        XCTAssertEqual(threadRPC.created, 1)
        XCTAssertTrue(executor.executedJobs.isEmpty)
    }

    func testEveryMessageBackedCreateRequiresAClientIDBeforeSideEffects() async throws {
        let file = TestSupport.writeSessionFile(in: directory, id: "unused-create", cwd: directory.path)
        let thread = PiThread(
            id: "unused-create", path: file.path, name: "Unused", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let threadRPC = FakeThreadRPCService(thread: thread)
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        for agent in ["pi", "codex", "claude"] {
            let response = await send(
                "POST", "/v1/threads",
                body: #"{"cwd":"\#(directory.path)","agent":"\#(agent)","message":"hello","worktree":true}"#
            )
            XCTAssertEqual(response.status, 400, agent)
            XCTAssertTrue(
                String(decoding: response.body, as: UTF8.self).contains("client_id_required"),
                agent
            )
        }

        XCTAssertEqual(threadRPC.created, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: core.worktreeRootURL.path))
        let queued = await core.runQueue.queuedCount()
        let active = await core.runQueue.activeCount()
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(active, 0)
    }

    func testAgentThatDoesNotPersistIdleRejectsBeforeAnyCreationSideEffect() async throws {
        let fakeThread = PiThread(
            id: "unused", path: directory.appendingPathComponent("unused.jsonl").path,
            name: "unused", cwd: directory.path, folder: directory.lastPathComponent,
            createdAt: Date(), updatedAt: Date(), agent: .claude
        )
        let threadRPC = FakeThreadRPCService(thread: fakeThread)
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","agent":"claude","message":"   ","worktree":true,"clientId":"idle-claude"}"#
        )

        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("first_message_required"))
        XCTAssertEqual(threadRPC.created, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: core.worktreeRootURL.path))
    }

    func testPromptBackedCreatePublishesOnlyARealImmediatelyOpenableThread() async throws {
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let transcript = claudeRoot.appendingPathComponent("project/claude-created.jsonl")
        let cwd = directory.path
        let readyObservation = ReadyCallbackObservation()
        let fakeThread = PiThread(
            id: "unused", path: directory.appendingPathComponent("unused.jsonl").path,
            name: "unused", cwd: directory.path, folder: directory.lastPathComponent,
            createdAt: Date(), updatedAt: Date(), agent: .claude
        )
        let threadRPC = FakeThreadRPCService(thread: fakeThread)
        executor = FakeRunExecutor()
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC,
            extraSessionRoots: [(.claude, claudeRoot)]
        )
        let threadStore = core.threadStore
        executor.behavior = { job in
            let writer = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                _ = TestSupport.writeClaudeTranscript(
                    in: claudeRoot, id: "claude-created", cwd: cwd,
                    message: "hello", name: "Claude thread"
                )
            }
            await job.onThreadReady?("claude-created", transcript.path)
            await readyObservation.record(
                await threadStore.thread(idOrPath: transcript.path) != nil
            )
            await writer.value
            return RunOutcome(
                status: .ok, error: nil, summary: "done",
                resolvedThreadId: "claude-created", resolvedThreadPath: transcript.path,
                promptStartedAt: Date(), promptAcceptedAt: Date()
            )
        }
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","agent":"claude","name":"Claude thread","message":"hello","clientId":"create-claude","desktopManaged":true}"#
        )
        XCTAssertEqual(response.status, 202)
        let created = try decode(CreateThreadResponse.self, response)
        XCTAssertEqual(created.thread.id, "claude-created")
        XCTAssertEqual(created.thread.path, transcript.path)
        XCTAssertEqual(created.thread.agent, .claude)
        XCTAssertEqual(created.runId, executor.executedJobs.first?.id)
        XCTAssertEqual(threadRPC.created, 0)
        let visibleWhenReadyReturned = await readyObservation.waitForValue()
        XCTAssertEqual(visibleWhenReadyReturned, true)

        let detail = await send("GET", "/v1/threads/\(created.thread.id)")
        XCTAssertEqual(detail.status, 200, "the response must never point at a not-yet-visible transcript")
        XCTAssertEqual(try decode(ThreadDetailResponse.self, detail).thread.path, transcript.path)
        guard case let .newThread(cwd, name, agent) = executor.executedJobs.first?.target else {
            return XCTFail("the first message must own the fresh runtime")
        }
        XCTAssertEqual(cwd, directory.path)
        XCTAssertEqual(name, "Claude thread")
        XCTAssertEqual(agent, .claude)
        let snapshot = DaemonWorktreeProjects.loadSnapshot(
            from: directory.appendingPathComponent("overlay.json")
        )
        XCTAssertTrue(snapshot.managedThreadPaths.contains(transcript.path))
        XCTAssertTrue(snapshot.desktopStartedThreadPaths.contains(transcript.path))
    }

    func testPromptBackedCompletionRecoveryPublishesAnIdleThread() async throws {
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        let transcript = TestSupport.writeClaudeTranscript(
            in: claudeRoot, id: "claude-complete", cwd: directory.path, message: "hello"
        )
        executor = FakeRunExecutor { _ in
            RunOutcome(
                status: .ok, error: nil, summary: "done",
                resolvedThreadId: "claude-complete", resolvedThreadPath: transcript.path,
                promptStartedAt: Date(), promptAcceptedAt: Date()
            )
        }
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, extraSessionRoots: [(.claude, claudeRoot)]
        )
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","agent":"claude","message":"hello","clientId":"complete-claude"}"#
        )

        XCTAssertEqual(response.status, 202)
        let created = try decode(CreateThreadResponse.self, response)
        XCTAssertEqual(created.thread.id, "claude-complete")
        XCTAssertFalse(created.thread.running)
        let detail = try decode(
            ThreadDetailResponse.self, await send("GET", "/v1/threads/claude-complete")
        )
        XCTAssertFalse(detail.thread.running)
    }

    func testPromptBackedCreateFailureBeforeDispatchCanRetryTheSameClientID() async throws {
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let transcript = TestSupport.writeClaudeTranscript(
            in: claudeRoot, id: "claude-retry", cwd: directory.path
        )
        executor = FakeRunExecutor { _ in
            RunOutcome.failed("agent unavailable", retryable: true)
        }
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, extraSessionRoots: [(.claude, claudeRoot)]
        )
        router = DaemonRouter(routes: Routes.all(core))
        let body = #"{"cwd":"\#(directory.path)","agent":"claude","message":"hello","clientId":"retry-claude"}"#

        let failed = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(failed.status, 503)
        executor.behavior = { job in
            await job.onThreadReady?("claude-retry", transcript.path)
            return RunOutcome(
                status: .ok, error: nil, summary: nil,
                resolvedThreadId: "claude-retry", resolvedThreadPath: transcript.path,
                promptStartedAt: Date(), promptAcceptedAt: Date()
            )
        }

        let retried = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(retried.status, 202)
        XCTAssertEqual(try decode(CreateThreadResponse.self, retried).thread.id, "claude-retry")
        XCTAssertEqual(executor.executedJobs.count, 2)
    }

    func testPromptBackedAmbiguityRequiresReviewAndNeverRunsAgain() async throws {
        executor = FakeRunExecutor { _ in
            RunOutcome(
                status: .interrupted, error: "ack lost", summary: nil,
                promptStartedAt: Date()
            )
        }
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions
        )
        router = DaemonRouter(routes: Routes.all(core))
        let body = #"{"cwd":"\#(directory.path)","agent":"claude","message":"hello","clientId":"unknown-claude"}"#

        let first = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(first.status, 409)
        XCTAssertTrue(String(decoding: first.body, as: UTF8.self).contains("creation_outcome_unknown"))
        let replay = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(replay.status, 409)
        XCTAssertTrue(String(decoding: replay.body, as: UTF8.self).contains("creation_outcome_unknown"))
        XCTAssertEqual(executor.executedJobs.count, 1)
    }

    func testIdleCreationAmbiguityRetainsReplayProtectionAndItsWorktree() async throws {
        let project = directory.appendingPathComponent("ambiguous-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertEqual(git(["-C", project.path, "init", "-q"]), 0)
        XCTAssertEqual(git(["-C", project.path, "config", "user.email", "test@example.invalid"]), 0)
        XCTAssertEqual(git(["-C", project.path, "config", "user.name", "Test"]), 0)
        try Data("one\n".utf8).write(to: project.appendingPathComponent("sample.txt"))
        XCTAssertEqual(git(["-C", project.path, "add", "sample.txt"]), 0)
        XCTAssertEqual(git(["-C", project.path, "commit", "-q", "-m", "initial"]), 0)

        let threadRPC = AmbiguousThreadRPCService()
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))
        let body = #"{"cwd":"\#(project.path)","agent":"codex","message":"hello","worktree":true,"clientId":"unknown-name-ack"}"#

        let first = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(first.status, 409)
        XCTAssertTrue(String(decoding: first.body, as: UTF8.self).contains("creation_outcome_unknown"))
        let createdCwds = await threadRPC.createdCwds()
        let worktree = try XCTUnwrap(createdCwds.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertEqual(
            DaemonWorktreeProjects.load(
                from: directory.appendingPathComponent("overlay.json")
            )[worktree.standardizedFileURL.path],
            project.standardizedFileURL.path
        )

        let replay = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(replay.status, 409)
        XCTAssertTrue(String(decoding: replay.body, as: UTF8.self).contains("creation_outcome_unknown"))
        let createCount = await threadRPC.createCount()
        let queued = await core.runQueue.queuedCount()
        XCTAssertEqual(createCount, 1)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        XCTAssertEqual(queued, 0)
    }

    func testCreateReturnsTheRealThreadWhenShutdownRejectsItsFirstMessage() async throws {
        let file = TestSupport.writeSessionFile(in: directory, id: "created-during-shutdown", cwd: directory.path)
        let created = PiThread(
            id: "created-during-shutdown", path: file.path, name: "Kept thread",
            cwd: directory.path, folder: directory.lastPathComponent,
            createdAt: Date(), updatedAt: Date()
        )
        let barrier = CreateBarrier()
        let threadRPC = FakeThreadRPCService(thread: created) {
            await barrier.enterAndWait()
        }
        executor = FakeRunExecutor()
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let request = Task {
            await self.send(
                "POST", "/v1/threads",
                body: #"{"cwd":"\#(directory.path)","message":"keep this message","clientId":"shutdown-create"}"#
            )
        }
        await barrier.waitUntilEntered()
        await core.runQueue.shutdown(graceSeconds: 0)
        await barrier.release()
        let response = await request.value
        let decoded = try decode(CreateThreadResponse.self, response)

        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(decoded.thread.id, "created-during-shutdown")
        XCTAssertNil(decoded.runId)
        XCTAssertNotNil(decoded.firstMessageError)
        XCTAssertEqual(threadRPC.created, 1)
        XCTAssertTrue(executor.executedJobs.isEmpty)
    }

    func testRepeatingCreateAfterRestartReplaysWithoutCreatingOrPromptingAgain() async throws {
        let file = TestSupport.writeSessionFile(
            in: directory, id: "created-replay", cwd: directory.path
        )
        let created = PiThread(
            id: "created-replay", path: file.path, name: "Replay", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let firstRPC = FakeThreadRPCService(thread: created)
        executor = FakeRunExecutor()
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: firstRPC
        )
        router = DaemonRouter(routes: Routes.all(core))
        let body = #"{"cwd":"\#(directory.path)","name":"Replay","message":"hello","clientId":"create-restart"}"#

        let firstResponse = await send("POST", "/v1/threads", body: body)
        let first = try decode(CreateThreadResponse.self, firstResponse)
        XCTAssertEqual(firstResponse.status, 202)
        try await settle()
        XCTAssertEqual(firstRPC.created, 1)
        XCTAssertEqual(executor.executedJobs.count, 1)

        let restartedRPC = FakeThreadRPCService(thread: created)
        let restartedExecutor = FakeRunExecutor()
        executor = restartedExecutor
        core = TestSupport.makeCore(
            in: directory, executor: restartedExecutor,
            interactions: InteractionRegistry(), liveSessions: LiveSessionRegistry(),
            threadRPC: restartedRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let replayResponse = await send("POST", "/v1/threads", body: body)
        let replay = try decode(CreateThreadResponse.self, replayResponse)
        XCTAssertEqual(replayResponse.status, firstResponse.status)
        XCTAssertEqual(replay, first)
        try await settle()
        XCTAssertEqual(restartedRPC.created, 0)
        XCTAssertTrue(restartedExecutor.executedJobs.isEmpty)
    }

    func testCompletedCreateReplaysAfterItsWorkingDirectoryDisappears() async throws {
        let project = directory.appendingPathComponent("temporary-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = TestSupport.writeSessionFile(
            in: directory, id: "created-gone-cwd", cwd: project.path
        )
        let created = PiThread(
            id: "created-gone-cwd", path: file.path, name: "Replay", cwd: project.path,
            folder: project.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let firstRPC = FakeThreadRPCService(thread: created)
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: firstRPC
        )
        router = DaemonRouter(routes: Routes.all(core))
        let body = #"{"cwd":"\#(project.path)","name":"Replay","clientId":"create-gone-cwd"}"#

        let firstResponse = await send("POST", "/v1/threads", body: body)
        let first = try decode(CreateThreadResponse.self, firstResponse)
        XCTAssertEqual(firstResponse.status, 201)
        XCTAssertEqual(firstRPC.created, 1)

        try FileManager.default.removeItem(at: project)
        let restartedRPC = FakeThreadRPCService(thread: created)
        core = TestSupport.makeCore(
            in: directory, executor: FakeRunExecutor(),
            interactions: InteractionRegistry(), liveSessions: LiveSessionRegistry(),
            threadRPC: restartedRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let replayResponse = await send("POST", "/v1/threads", body: body)
        XCTAssertEqual(replayResponse.status, firstResponse.status)
        XCTAssertEqual(try decode(CreateThreadResponse.self, replayResponse), first)
        XCTAssertEqual(restartedRPC.created, 0)
    }

    func testCreateClientIDCannotBeReusedForDifferentInput() async throws {
        let file = TestSupport.writeSessionFile(
            in: directory, id: "created-conflict", cwd: directory.path
        )
        let created = PiThread(
            id: "created-conflict", path: file.path, name: "One", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let threadRPC = FakeThreadRPCService(thread: created)
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let first = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","name":"One","clientId":"create-conflict"}"#
        )
        XCTAssertEqual(first.status, 201)
        let conflict = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","name":"One","clientId":"create-conflict","desktopManaged":true}"#
        )
        XCTAssertEqual(conflict.status, 409)
        XCTAssertTrue(String(decoding: conflict.body, as: UTF8.self).contains("creation_id_conflict"))
        XCTAssertEqual(threadRPC.created, 1)
    }

    func testCreateWithWorktreeUsesDesktopFlowAndPersistsTheSourceProject() async throws {
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let source = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertEqual(git(["-C", project.path, "init", "-q"]), 0)
        XCTAssertEqual(git(["-C", project.path, "config", "user.email", "test@example.invalid"]), 0)
        XCTAssertEqual(git(["-C", project.path, "config", "user.name", "Test"]), 0)
        try Data("one\n".utf8).write(to: project.appendingPathComponent("sample.txt"))
        XCTAssertEqual(git(["-C", project.path, "add", "sample.txt"]), 0)
        XCTAssertEqual(git(["-C", project.path, "commit", "-q", "-m", "initial"]), 0)

        let file = TestSupport.writeSessionFile(in: directory, id: "created-worktree", cwd: source.path)
        let created = PiThread(
            id: "created-worktree", path: file.path, name: "Worktree", cwd: source.path,
            folder: source.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let threadRPC = FakeThreadRPCService(thread: created)
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(source.path)","name":"Worktree","worktree":true}"#
        )
        XCTAssertEqual(response.status, 201)
        let decoded = try decode(CreateThreadResponse.self, response)
        let worktree = try XCTUnwrap(threadRPC.createdCwds.first)
        XCTAssertTrue(WorktreeService.isManaged(worktree, root: core.worktreeRootURL))
        XCTAssertEqual(decoded.thread.cwd, worktree.path)
        XCTAssertEqual(decoded.thread.project, source.standardizedFileURL.path)
        XCTAssertEqual(decoded.thread.worktree, worktree.standardizedFileURL.path)
        XCTAssertEqual(
            DaemonWorktreeProjects.load(
                from: directory.appendingPathComponent("overlay.json")
            )[worktree.standardizedFileURL.path],
            source.standardizedFileURL.path
        )
    }

    func testRuntimeControlsUseTheAlreadyLivePiSession() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)

        let loaded = try decode(
            ThreadRuntimeResponse.self,
            await send("GET", "/v1/threads/sess-1/runtime")
        ).runtime
        XCTAssertEqual(loaded.modelId, "gpt-5")
        XCTAssertEqual(loaded.thinkingLevel, "high")
        XCTAssertEqual(loaded.availableModels.map(\.name), ["GPT-5", "Sonnet"])
        XCTAssertTrue(loaded.running)

        let changed = await send(
            "POST", "/v1/threads/sess-1/runtime/model",
            body: #"{"provider":"anthropic","modelId":"sonnet"}"#
        )
        XCTAssertEqual(changed.status, 200)
        let set = try XCTUnwrap(runtime.requests.first { $0.type == "set_model" })
        XCTAssertEqual(set.payload["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(set.payload["modelId"]?.stringValue, "sonnet")
    }

    func testIdleRuntimeControlsUseOneReservedThreadSession() async throws {
        let file = TestSupport.writeSessionFile(in: directory, id: "sess-idle", cwd: directory.path)
        let thread = PiThread(
            id: "sess-idle", path: file.path, name: "Idle", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        let threadRPC = FakeThreadRPCService(
            thread: thread,
            runtime: ThreadRuntimeState(
                provider: "openai", modelId: "gpt-5", modelName: "GPT-5", thinkingLevel: "off",
                availableModels: [ThreadRuntimeModel(provider: "openai", modelId: "gpt-5", name: "GPT-5")],
                availableThinkingLevels: ["off", "high"]
            )
        )
        core = TestSupport.makeCore(
            in: directory, executor: executor, interactions: interactions,
            liveSessions: liveSessions, threadRPC: threadRPC
        )
        router = DaemonRouter(routes: Routes.all(core))

        let loaded = await send("GET", "/v1/threads/sess-idle/runtime")
        XCTAssertEqual(loaded.status, 200)
        let changed = await send(
            "POST", "/v1/threads/sess-idle/runtime/thinking", body: #"{"level":"high"}"#
        )
        XCTAssertEqual(changed.status, 200)
        XCTAssertEqual(threadRPC.thinkingSets, ["high"])
        let stillBusy = await core.runQueue.isThreadBusy(ThreadInstanceKey(path: file.path))
        XCTAssertFalse(stillBusy, "the short-lived reservation is always released")
    }

    func testRuntimeControlsRespectTheNativeAppsLease() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        _ = await core.leaseStore.acquire(thread: primaryThreadKey, owner: "app", ttlSeconds: 60)
        let response = await send("GET", "/v1/threads/sess-1/runtime")
        XCTAssertEqual(response.status, 409)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("thread_leased"))
    }

    func testNativeLeaseCannotStealAWebRuntimeLease() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        _ = await core.leaseStore.acquire(
            thread: primaryThreadKey, owner: "web-runtime", ttlSeconds: 60
        )

        let response = await send(
            "POST", "/v1/threads/sess-1/lease",
            body: #"{"owner":"app","ttlSeconds":60}"#
        )
        XCTAssertEqual(response.status, 409)
        let current = await core.leaseStore.current(thread: primaryThreadKey)
        XCTAssertEqual(current?.owner, "web-runtime")
    }

    // MARK: - Replay protection

    func testRepeatingASubmissionReplaysTheAnswerInsteadOfPromptingPiTwice() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"hello","clientId":"web-abc123"}"#

        let first = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))
        let second = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))

        XCTAssertEqual(first.runId, second.runId, "the retry gets the original answer")
        XCTAssertEqual(first, second)
    }

    func testRepeatingASubmissionAfterRestartNeverReachesASecondRunner() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"hello","clientId":"web-restart"}"#

        let first = try decode(
            SendMessageResponse.self,
            await send("POST", "/v1/threads/sess-1/messages", body: body)
        )
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1)

        let restartedExecutor = FakeRunExecutor()
        executor = restartedExecutor
        core = TestSupport.makeCore(
            in: directory, executor: restartedExecutor,
            interactions: InteractionRegistry(), liveSessions: LiveSessionRegistry()
        )
        router = DaemonRouter(routes: Routes.all(core))

        let replay = try decode(
            SendMessageResponse.self,
            await send("POST", "/v1/threads/sess-1/messages", body: body)
        )
        XCTAssertEqual(replay, first)
        try await settle()
        XCTAssertTrue(restartedExecutor.executedJobs.isEmpty, "the restarted service replays the durable answer")
    }

    func testCompletedSubmissionReplaysAfterTranscriptRemovalAndRestart() async throws {
        let transcript = TestSupport.writeSessionFile(
            in: directory, id: "sess-1", cwd: directory.path
        )
        let body = #"{"text":"hello","clientId":"removed-replay"}"#
        let first = try decode(
            SendMessageResponse.self,
            await send("POST", "/v1/threads/sess-1/messages", body: body)
        )
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1)
        try FileManager.default.removeItem(at: transcript)

        let restartedExecutor = FakeRunExecutor()
        executor = restartedExecutor
        core = TestSupport.makeCore(
            in: directory, executor: restartedExecutor,
            interactions: InteractionRegistry(), liveSessions: LiveSessionRegistry()
        )
        router = DaemonRouter(routes: Routes.all(core))

        let replay = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(replay.status, 200)
        XCTAssertEqual(try decode(SendMessageResponse.self, replay), first)
        let changed = await send(
            "POST", "/v1/threads/sess-1/messages",
            body: #"{"text":"different","clientId":"removed-replay"}"#
        )
        XCTAssertEqual(changed.status, 409)
        XCTAssertTrue(String(decoding: changed.body, as: UTF8.self).contains("submission_id_conflict"))
        try await settle()
        XCTAssertTrue(restartedExecutor.executedJobs.isEmpty)
    }

    func testCompletedSubmissionReplaysWhenItsIDLaterBecomesAmbiguous() async throws {
        let transcript = TestSupport.writeSessionFile(
            in: directory, id: "sess-1", cwd: directory.path
        )
        let body = #"{"text":"hello","clientId":"ambiguous-replay"}"#
        let first = try decode(
            SendMessageResponse.self,
            await send("POST", "/v1/threads/sess-1/messages", body: body)
        )
        try await settle()
        let copy = transcript.deletingLastPathComponent()
            .appendingPathComponent("sess-1-history.jsonl")
        try FileManager.default.copyItem(at: transcript, to: copy)

        let restartedExecutor = FakeRunExecutor()
        executor = restartedExecutor
        core = TestSupport.makeCore(
            in: directory, executor: restartedExecutor,
            interactions: InteractionRegistry(), liveSessions: LiveSessionRegistry()
        )
        router = DaemonRouter(routes: Routes.all(core))

        let replay = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(replay.status, 200)
        XCTAssertEqual(try decode(SendMessageResponse.self, replay), first)
        try await settle()
        XCTAssertTrue(restartedExecutor.executedJobs.isEmpty)
    }

    func testSubmissionClientIDCannotBeReusedForDifferentTextOrDelivery() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let first = await send(
            "POST", "/v1/threads/sess-1/messages",
            body: #"{"text":"hello","clientId":"message-conflict"}"#
        )
        XCTAssertEqual(first.status, 200)

        for body in [
            #"{"text":"different","clientId":"message-conflict"}"#,
            #"{"text":"hello","delivery":"followUp","clientId":"message-conflict"}"#
        ] {
            let conflict = await send(
                "POST", "/v1/threads/sess-1/messages", body: body
            )
            XCTAssertEqual(conflict.status, 409)
            XCTAssertTrue(String(decoding: conflict.body, as: UTF8.self).contains("submission_id_conflict"))
        }
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1)
    }

    func testCompletedSubmissionReplaysEvenWhenTheThreadIsNowLeased() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"hello","clientId":"replay-under-lease"}"#
        let first = try decode(
            SendMessageResponse.self,
            await send("POST", "/v1/threads/sess-1/messages", body: body)
        )
        _ = await core.leaseStore.acquire(thread: primaryThreadKey, owner: "app", ttlSeconds: 60)

        let replayResponse = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(replayResponse.status, 200)
        XCTAssertEqual(try decode(SendMessageResponse.self, replayResponse), first)
    }

    func testRestartRefusesAnAmbiguousSubmissionWithoutReachingTheRunner() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let fingerprint = SubmissionRegistry.fingerprint(parts: ["message", "hello", "auto"])
        let claim = await core.submissions.claim(
            thread: primaryThreadKey, clientID: "web-ambiguous",
            requestFingerprint: fingerprint
        )
        XCTAssertNotNil(claim.ownership)

        let restartedExecutor = FakeRunExecutor()
        executor = restartedExecutor
        core = TestSupport.makeCore(
            in: directory, executor: restartedExecutor,
            interactions: InteractionRegistry(), liveSessions: LiveSessionRegistry()
        )
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads/sess-1/messages",
            body: #"{"text":"hello","clientId":"web-ambiguous"}"#
        )
        XCTAssertEqual(response.status, 409)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("submission_outcome_unknown"))
        XCTAssertTrue(restartedExecutor.executedJobs.isEmpty)
    }

    func testAnInFlightRetryWaitsForAndReplaysTheOriginalAnswer() async throws {
        let registry = SubmissionRegistry()
        let claim = await registry.claim(threadID: "thread", clientID: "same")
        let ownership = try XCTUnwrap(claim.ownership)
        let waiter = Task {
            await registry.waitForCompletion(threadID: "thread", clientID: "same")
        }
        await Task.yield()
        let response = SendMessageResponse(
            runId: "run_original", queued: false, delivery: .auto
        )
        await registry.complete(
            threadID: "thread", clientID: "same", ownership: ownership, response: response
        )

        let replay = await waiter.value
        XCTAssertEqual(replay, response)
    }

    /// The property that actually matters: a repeat never reaches the runner. Asserted against the
    /// executor rather than the queue's counters, which drain as soon as a fake run finishes.
    func testARepeatedSubmissionNeverReachesTheRunner() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"hello","clientId":"web-once"}"#

        _ = await send("POST", "/v1/threads/sess-1/messages", body: body)
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1)

        _ = await send("POST", "/v1/threads/sess-1/messages", body: body)
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1, "Pi was prompted once, however many times the phone asked")
    }

    func testASendIsRefusedRatherThanForgettingASubmissionStillInFlight() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        // Every slot held by a send that has not finished. Making room by evicting one would let
        // its retry through as a second prompt, so the *new* submission is the one refused.
        var owners: [SubmissionRegistry.Ownership] = []
        for index in 0..<SubmissionRegistry.maxEntries {
            let claim = await core.submissions.claim(threadID: "sess-1", clientID: "c\(index)")
            owners.append(try XCTUnwrap(claim.ownership))
        }

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello","clientId":"one-too-many"}"#)
        XCTAssertEqual(response.status, 503)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("submissions_busy"))
        try await settle()
        XCTAssertTrue(executor.executedJobs.isEmpty, "a refused send never becomes a run")

        // Completion still protects a possibly lost response, so only a definitely failed claim
        // frees capacity before the replay TTL.
        await core.submissions.complete(
            threadID: "sess-1", clientID: "c0", ownership: owners[0],
            response: SendMessageResponse(runId: "run_0", queued: false, delivery: .auto)
        )
        let stillFull = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello","clientId":"one-too-many"}"#)
        XCTAssertEqual(stillFull.status, 503)
        await core.submissions.abandon(
            threadID: "sess-1", clientID: "c1", ownership: owners[1]
        )
        let retry = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello","clientId":"one-too-many"}"#)
        XCTAssertEqual(retry.status, 200)
    }

    /// Lets an enqueued fake run start and finish. The fake executor returns immediately, so a few
    /// short yields are enough; the assertions above it are what make a regression visible.
    private func settle() async throws {
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 5_000_000)
            if await core.runQueue.activeCount() == 0, await core.runQueue.queuedCount() == 0 { return }
        }
    }

    func testARepeatedSteerIsNotDeliveredIntoTheLiveTurnASecondTime() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)
        let body = #"{"text":"stop","delivery":"steer","clientId":"web-steer1"}"#

        let first = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))
        let second = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))

        XCTAssertEqual(first, second)
        XCTAssertEqual(runtime.delivered.count, 1, "Pi was steered once, however many times the phone asked")
    }

    func testADifferentClientIDIsADifferentMessage() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let one = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"one","clientId":"web-a"}"#))
        let two = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"two","clientId":"web-b"}"#))
        XCTAssertNotEqual(one.runId, two.runId)
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 2)
    }

    func testAMessageWithNoClientIDStillWorksButGetsNoReplayProtection() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let one = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello"}"#))
        let two = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello"}"#))
        XCTAssertNotEqual(one.runId, two.runId, "an older client behaves exactly as before")
    }

    func testAFailedSubmissionDoesNotLockOutAnHonestRetry() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.result = .rejected("Nothing to steer.")
        liveSessions.register(thread: primaryThreadKey, runID: "run_live", handle: runtime)
        let body = #"{"text":"x","delivery":"steer","clientId":"web-retry"}"#

        let rejected = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(rejected.status, 409)

        // Pi refused, so nothing happened and the same submission must be allowed to try again.
        liveSessions.unregister(thread: primaryThreadKey, runID: "run_live")
        let retry = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(retry.status, 200)
    }

    func testAMalformedClientIDIsRejected() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let bad = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","clientId":"has spaces"}"#)
        XCTAssertEqual(bad.status, 400)

        let long = String(repeating: "a", count: 129)
        let tooLong = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","clientId":"\#(long)"}"#)
        XCTAssertEqual(tooLong.status, 400)

        let empty = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","clientId":""}"#)
        XCTAssertEqual(empty.status, 400)
        try await settle()
        XCTAssertTrue(executor.executedJobs.isEmpty)
    }

    // MARK: - Attachments

    func testAttachmentsAreRejectedRatherThanAcceptedAndDropped() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"look","attachments":[{"type":"image","data":"\#(Self.tinyPNG)","mimeType":"image/png"}]}"#

        let response = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("attachments_unsupported"))

        try await settle()
        XCTAssertTrue(executor.executedJobs.isEmpty, "never reported as sent, and never silently sent without them")
    }

    func testAnEmptyAttachmentsArrayIsNotAnAttachment() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"plain","attachments":[]}"#)
        XCTAssertEqual(response.status, 200)
    }

    // MARK: - Images

    func testImageEndpointReturnsBoundedBase64ForAProjectedReference() async throws {
        _ = TestSupport.writeSessionFile(
            in: directory, id: "sess-1", cwd: directory.path,
            lines: [#"{"type":"message","id":"m1","message":{"role":"assistant","timestamp":1,"content":[{"type":"image","mimeType":"image/png","fileName":"shot.png","data":"\#(Self.tinyPNG)"}]}}"#]
        )

        let detail = try decode(ThreadDetailResponse.self, await send("GET", "/v1/threads/sess-1", query: ["messages": "10"]))
        let reference = try XCTUnwrap(detail.messages.first?.images.first)
        XCTAssertEqual(reference.status, .ok)

        let image = try decode(MessageImageResponse.self, await send("GET", "/v1/threads/sess-1/images/\(reference.id)"))
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.fileName, "shot.png")
        XCTAssertEqual(Data(base64Encoded: image.data), Data(base64Encoded: Self.tinyPNG))
    }

    func testUnknownImageIDIs404() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let unknownBlock = await send("GET", "/v1/threads/sess-1/images/0-c0")
        XCTAssertEqual(unknownBlock.status, 404)
        let unknownThread = await send("GET", "/v1/threads/nope/images/0-c0")
        XCTAssertEqual(unknownThread.status, 404)
    }

    // MARK: - Sidebar visibility

    func testSidebarThreadListUsesTheAppsOwnershipAndAgentSettings() async throws {
        let ours = TestSupport.writeSessionFile(in: directory, id: "ours", cwd: directory.path)
        _ = TestSupport.writeSessionFile(in: directory, id: "foreign", cwd: directory.path)
        TestSupport.writeAppState(in: directory, appStartedSessionPaths: [ours.path])

        let sidebar = try decode(
            ThreadListResponse.self,
            await send("GET", "/v1/threads", query: ["sidebar": "true", "limit": "200"])
        )
        XCTAssertEqual(sidebar.threads.map(\.id), ["ours"])

        let unfiltered = try decode(
            ThreadListResponse.self,
            await send("GET", "/v1/threads", query: ["limit": "200"])
        )
        XCTAssertEqual(Set(unfiltered.threads.map(\.id)), ["ours", "foreign"])

        TestSupport.writeAppState(
            in: directory,
            appStartedSessionPaths: [ours.path],
            showsForeignConversations: true
        )
        let showingForeign = try decode(
            ThreadListResponse.self,
            await send("GET", "/v1/threads", query: ["sidebar": "true", "limit": "200"])
        )
        XCTAssertEqual(Set(showingForeign.threads.map(\.id)), ["ours", "foreign"])

        TestSupport.writeAppState(
            in: directory,
            appStartedSessionPaths: [ours.path],
            showsForeignConversations: true,
            disabledAgents: ["pi"]
        )
        let disabled = try decode(
            ThreadListResponse.self,
            await send("GET", "/v1/threads", query: ["sidebar": "true", "limit": "200"])
        )
        XCTAssertTrue(disabled.threads.isEmpty)
    }

    func testDesktopManagedCreateStaysInBothSidebarProjections() async throws {
        let file = TestSupport.writeSessionFile(in: directory, id: "remote-created", cwd: directory.path)
        let created = PiThread(
            id: "remote-created", path: file.path, name: "Remote", cwd: directory.path,
            folder: directory.lastPathComponent, createdAt: Date(), updatedAt: Date()
        )
        core = TestSupport.makeCore(
            in: directory,
            executor: executor,
            interactions: interactions,
            liveSessions: liveSessions,
            threadRPC: FakeThreadRPCService(thread: created)
        )
        router = DaemonRouter(routes: Routes.all(core))

        let response = await send(
            "POST", "/v1/threads",
            body: #"{"cwd":"\#(directory.path)","desktopManaged":true}"#
        )
        XCTAssertEqual(response.status, 201)

        let sidebar = try decode(
            ThreadListResponse.self,
            await send("GET", "/v1/threads", query: ["sidebar": "true", "limit": "200"])
        )
        XCTAssertEqual(sidebar.threads.map(\.id), ["remote-created"])
        XCTAssertEqual(
            DaemonThreadOverlay.load(from: directory.appendingPathComponent("overlay.json"))
                .desktopStartedThreadPaths,
            Set([file.standardizedFileURL.path])
        )
    }

    // MARK: - Folders

    func testFoldersEndpointIsEmptyWhenTheAppHasNoStateFileAtAll() async throws {
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertTrue(tree.folders.isEmpty)
        XCTAssertTrue(tree.assignments.isEmpty)
    }

    func testFoldersEndpointProjectsLegacyStateWithNoParentKeys() async throws {
        TestSupport.writeAppState(
            in: directory,
            folders: #"[{"id":"f1","name":"Review","createdAt":0}]"#,
            assignments: ["/tmp/a.jsonl": "f1", "/tmp/b.jsonl": "missing"]
        )
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertEqual(tree.folders.map(\.name), ["Review"])
        XCTAssertNil(tree.folders[0].parentId)
        XCTAssertEqual(tree.assignments, ["/tmp/a.jsonl": "f1"], "an assignment to a folder that is gone is dropped")
    }

    func testFoldersEndpointIncludesRealProjectAssignments() async throws {
        TestSupport.writeAppState(
            in: directory,
            folders: #"[{"id":"clients","name":"Clients","createdAt":0}]"#,
            projectAssignments: ["/tmp/client-a": "clients"]
        )
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertEqual(tree.projectAssignments, ["/tmp/client-a": "clients"])
    }

    func testFoldersEndpointFlattensACycleInsteadOfHangingOrFailing() async throws {
        TestSupport.writeAppState(in: directory, folders: """
        [{"id":"a","name":"A","createdAt":0,"parentID":"virtual:b"},
         {"id":"b","name":"B","createdAt":1,"parentID":"virtual:a"}]
        """)
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertEqual(Set(tree.folders.map(\.id)), ["a", "b"])
        XCTAssertTrue(tree.folders.allSatisfy { $0.depth == 0 })
    }

    func testAnOversizedStateFileIsRefusedRatherThanRead() async throws {
        // A corrupted or hostile state.json must not be pulled into memory on every folder
        // request. The guard is on the file size, so the check never allocates the contents.
        let url = directory.appendingPathComponent("state.json")
        let padding = String(repeating: " ", count: AppStatePeek.maxStateBytes + 1_024)
        try (#"{"virtualFolders":[{"id":"f1","name":"Review","createdAt":0}]}"# + padding)
            .write(to: url, atomically: true, encoding: .utf8)

        let response = await send("GET", "/v1/folders")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try decode(FolderTreeResponse.self, response).folders.isEmpty)
    }

    func testDaemonStateReadLimitMatchesTheNativeWriterLimit() {
        XCTAssertEqual(AppStatePeek.maxStateBytes, ArchiveStateBounds.appStateByteLimit)
        XCTAssertEqual(AppStatePeek.maxStateBytes, 32 * 1_024 * 1_024)
    }

    func testAppStatePeekBoundsAndStandardizesOwnedCustomPaths() throws {
        let paths = Set((0...(ArchiveStateBounds.itemLimit + 25)).map {
            "/tmp/custom/../custom/thread-\($0).jsonl"
        })
        let url = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: [
            "appStartedSessionPaths": Array(paths)
        ]).write(to: url)

        let snapshot = AppStatePeek.load(from: url)

        XCTAssertEqual(snapshot.appStartedSessionPaths.count, ArchiveStateBounds.itemLimit)
        XCTAssertTrue(snapshot.appStartedSessionPaths.allSatisfy {
            !$0.contains("/../") && $0.hasPrefix("/tmp/custom/")
        })
    }

    func testFoldersEndpointSurvivesAMalformedStateFile() async throws {
        try "{ not json".write(to: directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let response = await send("GET", "/v1/folders")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try decode(FolderTreeResponse.self, response).folders.isEmpty)
    }

    // MARK: - Worktrees

    func testPorcelainParsingKeepsTheMainCheckoutFirstAndSkipsBareEntries() {
        let porcelain = """
        worktree /repo/main
        HEAD abc123
        branch refs/heads/main

        worktree /repo/bare
        bare

        worktree /repo/feature
        HEAD def456
        branch refs/heads/feat/thing

        worktree /repo/detached
        HEAD 99ff00
        detached

        """
        let entries = GitWorktrees.parse(porcelain, mainPath: "/repo/main")
        XCTAssertEqual(entries.map(\.path), ["/repo/main", "/repo/detached", "/repo/feature"])
        XCTAssertEqual(entries.map(\.isMain), [true, false, false])
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[0].name, "main")
        XCTAssertNil(entries[1].branch, "a detached checkout has no branch to show")
        XCTAssertEqual(entries[2].branch, "feat/thing")
    }

    func testPorcelainParsingIsBounded() {
        let porcelain = (0..<(GitWorktrees.maxEntries + 20))
            .map { "worktree /repo/w\($0)\nHEAD abc\n" }
            .joined(separator: "\n")
        XCTAssertEqual(GitWorktrees.parse(porcelain, mainPath: "/repo/w0").count, GitWorktrees.maxEntries)
    }

    func testGitOutputIsBoundedWhileTheChildIsStillWriting() throws {
        let pipe = Pipe()
        // Written from another queue so this stays a "still being written to" stream rather than
        // a file that is already complete. 32 KiB fits a pipe buffer, so the writer finishes even
        // though the reader deliberately stops early.
        let payload = Data(repeating: UInt8(ascii: "x"), count: 32 * 1_024)
        DispatchQueue.global(qos: .utility).async {
            try? pipe.fileHandleForWriting.write(contentsOf: payload)
            try? pipe.fileHandleForWriting.close()
        }

        let data = GitWorktrees.drain(pipe.fileHandleForReading, limit: 4_096)
        try? pipe.fileHandleForReading.close()
        XCTAssertEqual(data.count, 4_096, "the cap must bound what is read, not what is kept after reading it all")
    }

    func testWorktreesEndpointAnswersAnEmptyListForADirectoryThatIsNotARepository() async throws {
        let plain = directory.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let response = await send("GET", "/v1/worktrees", query: ["cwd": plain.path])
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try decode(WorktreeListResponse.self, response).worktrees.isEmpty)
    }

    func testWorktreesEndpointRejectsAMissingOrNonDirectoryCwd() async {
        let missing = await send("GET", "/v1/worktrees")
        XCTAssertEqual(missing.status, 400)
        let file = directory.appendingPathComponent("file.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        let notADirectory = await send("GET", "/v1/worktrees", query: ["cwd": file.path])
        XCTAssertEqual(notADirectory.status, 400)
    }

    // MARK: - Archive

    /// `Thread.archived` is the union of the daemon's overlay with the app's own `state.json`,
    /// which the daemon never writes. Restoring what the app archived therefore cannot work, and
    /// must not be reported as if it had.
    func testUnarchivingAThreadTheAppArchivedIsAConflictRatherThanAFakeSuccess() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-app-archived", cwd: directory.path)
        let daemonArchive = await send(
            "POST", "/v1/threads/sess-app-archived/archive", body: #"{"archived":true}"#
        )
        XCTAssertEqual(daemonArchive.status, 200)
        TestSupport.writeAppState(in: directory, archivedSessionIDs: ["sess-app-archived"])

        let restore = await send("POST", "/v1/threads/sess-app-archived/archive", body: #"{"archived":false}"#)
        XCTAssertEqual(restore.status, 409)
        XCTAssertTrue(String(decoding: restore.body, as: UTF8.self).contains("archived_in_app"))
        TestSupport.writeAppState(in: directory)
        let detail = try decode(
            ThreadDetailResponse.self,
            await send("GET", "/v1/threads/sess-app-archived")
        )
        XCTAssertTrue(detail.thread.archived, "a rejected restore must not clear the daemon archive")

        // A web-archived thread still restores here, so the conflict is specific rather than a
        // blanket refusal to unarchive anything.
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-web-archived", cwd: directory.path)
        let archived = await send("POST", "/v1/threads/sess-web-archived/archive", body: #"{"archived":true}"#)
        XCTAssertEqual(archived.status, 200)
        let restored = await send("POST", "/v1/threads/sess-web-archived/archive", body: #"{"archived":false}"#)
        XCTAssertEqual(restored.status, 200)
        XCTAssertFalse(try decode(ThreadResponse.self, restored).thread.archived)
    }

    // MARK: - Interactions

    private func registerDialog(id: String = "d1", method: InteractionMethod = .select, options: [String] = ["Alpha", "Beta"]) -> ResponseRecorder {
        let recorder = ResponseRecorder()
        _ = interactions.register(
            PendingInteraction(
                id: id, runId: "run_1", threadId: "sess-1", method: method, title: "Pick one",
                options: options, expiresAt: Date().addingTimeInterval(600),
                choices: options.enumerated().map { InteractionOption(id: $0.offset, value: $0.element, label: $0.element) }
            ),
            responder: { recorder.append($0) }
        )
        return recorder
    }

    func testPendingInteractionsAreListedAndFilterByThread() async throws {
        _ = registerDialog()
        let all = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(all.interactions.map(\.id), ["d1"])
        XCTAssertEqual(all.interactions[0].options, ["Alpha", "Beta"])

        let mine = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions", query: ["threadId": "sess-1"]))
        XCTAssertEqual(mine.interactions.count, 1)
        let other = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions", query: ["threadId": "sess-9"]))
        XCTAssertTrue(other.interactions.isEmpty)
    }

    func testRespondingWithAnExactOptionAnswersPiAndRetiresTheDialog() async throws {
        let recorder = registerDialog()
        let response = await send("POST", "/v1/interactions/d1/respond", body: #"{"value":"Beta"}"#)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(recorder.all.first?["value"]?.stringValue, "Beta")
        XCTAssertEqual(recorder.all.first?["type"]?.stringValue, "extension_ui_response")

        let remaining = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertTrue(remaining.interactions.isEmpty)
    }

    func testASelectValuePisNeverOfferedIsRejectedRatherThanGuessed() async throws {
        let recorder = registerDialog()
        let response = await send("POST", "/v1/interactions/d1/respond", body: #"{"value":"Gamma"}"#)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(recorder.all.isEmpty, "Pi is left waiting rather than answered with a guess")
        let still = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(still.interactions.count, 1, "the dialog stays answerable")
    }

    func testAResponseFieldMustSuitTheDialogsMethod() async throws {
        let recorder = registerDialog(id: "s1")
        let confirmedOnSelect = await send("POST", "/v1/interactions/s1/respond", body: #"{"confirmed":true}"#)
        XCTAssertEqual(confirmedOnSelect.status, 400, "a yes is not an option choice")

        let both = await send("POST", "/v1/interactions/s1/respond", body: #"{"value":"Alpha","confirmed":true}"#)
        XCTAssertEqual(both.status, 400, "two answers is no answer")

        let mixedCancel = await send("POST", "/v1/interactions/s1/respond", body: #"{"value":"Alpha","cancelled":true}"#)
        XCTAssertEqual(mixedCancel.status, 400)
        XCTAssertTrue(recorder.all.isEmpty, "Pi is left waiting rather than answered ambiguously")

        _ = registerDialog(id: "c1", method: .confirm, options: [])
        let valueOnConfirm = await send("POST", "/v1/interactions/c1/respond", body: #"{"value":"yes"}"#)
        XCTAssertEqual(valueOnConfirm.status, 400)
    }

    func testADialogMethodThisBuildCannotAnswerIsVisibleAndOnlyCancellable() async throws {
        let recorder = registerDialog(id: "x1", method: .other("holographicPicker"), options: [])

        let listed = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(listed.interactions.map(\.id), ["x1"], "an unknown blocking dialog must still be seen")

        let answered = await send("POST", "/v1/interactions/x1/respond", body: #"{"value":"guess"}"#)
        XCTAssertEqual(answered.status, 400)
        XCTAssertTrue(recorder.all.isEmpty)

        let cancelled = await send("POST", "/v1/interactions/x1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(cancelled.status, 200, "cancelling is always safe, and unblocks the run")
    }

    func testAResponseThatNeverReachedPiIsNotReportedAsAnswered() async throws {
        let recorder = ResponseRecorder()
        _ = interactions.register(
            PendingInteraction(
                id: "w1", runId: "run_1", threadId: "sess-1", method: .input, title: "Type",
                expiresAt: Date().addingTimeInterval(600)
            ),
            responder: { _ in throw RunnerError.ioFailure("stdin closed") }
        )

        let response = await send("POST", "/v1/interactions/w1/respond", body: #"{"value":"hello"}"#)
        XCTAssertEqual(response.status, 503, "the reader must not believe they answered it")
        XCTAssertTrue(recorder.all.isEmpty)

        let still = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(still.interactions.count, 1, "and it stays answerable, because Pi is still blocked")
    }

    func testAFreeTextAnswerIsNotOptionCheckedAndIsLengthBounded() async throws {
        let recorder = registerDialog(id: "i1", method: .input, options: [])
        let accepted = await send("POST", "/v1/interactions/i1/respond", body: #"{"value":"1,3"}"#)
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(recorder.all.first?["value"]?.stringValue, "1,3")

        _ = registerDialog(id: "i2", method: .input, options: [])
        let huge = String(repeating: "x", count: 20_001)
        let oversized = await send("POST", "/v1/interactions/i2/respond", body: #"{"value":"\#(huge)"}"#)
        XCTAssertEqual(oversized.status, 400)
    }

    func testAnEmptyBodyIsRejectedButAnExplicitCancellationIsAccepted() async throws {
        let recorder = registerDialog()
        let empty = await send("POST", "/v1/interactions/d1/respond", body: "{}")
        XCTAssertEqual(empty.status, 400)
        XCTAssertTrue(recorder.all.isEmpty)

        let cancelled = await send("POST", "/v1/interactions/d1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(cancelled.status, 200)
        XCTAssertEqual(recorder.all.first?["cancelled"]?.boolValue, true)
    }

    func testRespondingToAnUnknownOrAlreadyAnsweredDialogIs404() async throws {
        _ = registerDialog()
        let unknown = await send("POST", "/v1/interactions/nope/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(unknown.status, 404)
        let first = await send("POST", "/v1/interactions/d1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(first.status, 200)
        let second = await send("POST", "/v1/interactions/d1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(second.status, 404)
    }
}

private actor CreateBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ReadyCallbackObservation {
    private var visible: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func record(_ value: Bool) {
        visible = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }

    func waitForValue() async -> Bool {
        if let visible { return visible }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor AmbiguousThreadRPCService: ThreadRPCServing {
    private var cwds: [URL] = []

    func createIdle(agent: AgentKind, cwd: URL, name: String?) async throws -> PiThread {
        cwds.append(cwd.standardizedFileURL)
        throw ThreadCreationError.outcomeUnknown(
            agent: agent, sessionReference: "019f0000-0000-7000-8000-000000000099"
        )
    }

    func rename(agent: AgentKind, cwd: URL, sessionPath: URL, name: String) async throws {}

    func runtimeSnapshot(
        agent: AgentKind, cwd: URL, sessionPath: URL
    ) async throws -> ThreadRuntimeState {
        ThreadRuntimeState()
    }

    func setModel(
        agent: AgentKind, cwd: URL, sessionPath: URL, provider: String, modelId: String
    ) async throws -> ThreadRuntimeState {
        ThreadRuntimeState(provider: provider, modelId: modelId)
    }

    func setThinkingLevel(
        agent: AgentKind, cwd: URL, sessionPath: URL, level: String
    ) async throws -> ThreadRuntimeState {
        ThreadRuntimeState(thinkingLevel: level)
    }

    func createdCwds() -> [URL] { cwds }
    func createCount() -> Int { cwds.count }
}

/// Captures what the daemon would have written back to Pi.
final class ResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: PiJSONValue]] = []
    func append(_ value: [String: PiJSONValue]) { lock.lock(); storage.append(value); lock.unlock() }
    var all: [[String: PiJSONValue]] { lock.lock(); defer { lock.unlock() }; return storage }
}
