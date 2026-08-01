import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// End-to-end: a real `HTTPServer` on a temp Unix socket, driven only through `PiDeskClient` \u2014
/// the same path the CLI, the app, and the web remote all use. `FakeRunExecutor` still means no
/// run in these tests ever spawns `pi`.
final class HTTPServerIntegrationTests: XCTestCase {
    private var directory: URL!
    private var core: DaemonCore!
    private var server: HTTPServer!
    private var client: PiDeskClient!
    private var socketPath: URL!
    private var liveSessions: LiveSessionRegistry!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestSupport.tempDirectory()
        liveSessions = LiveSessionRegistry()
        core = TestSupport.makeCore(in: directory, liveSessions: liveSessions)
        socketPath = directory.appendingPathComponent("daemon.sock")
        let router = DaemonRouter(routes: Routes.all(core))
        server = HTTPServer(
            router: router,
            logger: TestSupport.logger(in: directory),
            bus: core.bus,
            maxSSEConnections: 1,
            tokenProvider: { nil }
        )
        try server.start(unixSocketPath: socketPath, tcpPort: nil)
        client = PiDeskClient(transport: .unixSocket(path: socketPath.path), requestTimeout: 5)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Health

    func testHealthReportsOkAndApiVersion() async throws {
        let health = try await client.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.api, PiDeskAPI.apiVersion)
        XCTAssertTrue(health.threadWorktrees)
        XCTAssertTrue(health.threadCreationIdempotency)
        XCTAssertTrue(health.messageSubmissionIdempotency)
        XCTAssertTrue(health.scheduleRunIdempotency)
        XCTAssertEqual(health.runningRuns, 0)
        XCTAssertEqual(health.queuedRuns, 0)
    }

    func testPostConnectResponseLimitSurfacesAsTransportFailure() async {
        let bounded = PiDeskClient(
            transport: .unixSocket(path: socketPath.path),
            requestTimeout: 5,
            maxResponseBytes: 1
        )
        do {
            _ = try await bounded.health()
            XCTFail("expected the response bound to reject the connected response")
        } catch PiDeskClientError.transportFailure {
            // A descriptor was connected, so this must not masquerade as daemonUnreachable.
        } catch {
            XCTFail("expected transportFailure, got \(error)")
        }
    }

    // MARK: - Threads

    func testListThreadsEmptyWhenNoSessionsExist() async throws {
        let response = try await client.listThreads()
        XCTAssertEqual(response.threads, [])
    }

    func testListThreadsDiscoversARealSessionFileAndShowFetchesItsMessages() async throws {
        _ = TestSupport.writeSessionFile(
            in: directory, id: "sess-1", cwd: "/tmp/project",
            lines: [#"{"type":"message","id":"m1","message":{"role":"user","content":"hello there","timestamp":1}}"#],
            name: "My thread"
        )
        let list = try await client.listThreads()
        XCTAssertEqual(list.threads.count, 1)
        XCTAssertEqual(list.threads.first?.name, "My thread")

        let detail = try await client.getThread(id: "sess-1")
        XCTAssertEqual(detail.thread.id, "sess-1")
        XCTAssertEqual(detail.messages.count, 1)
        XCTAssertEqual(detail.messages.first?.text, "hello there")
    }

    func testExactPathShowReusesTheListedThreadInsteadOfRefreshingEverySession() async throws {
        let file = TestSupport.writeSessionFile(
            in: directory, id: "sess-fast", cwd: "/tmp/project",
            lines: [#"{"type":"message","id":"m1","message":{"role":"user","content":"older","timestamp":1}}"#],
            name: "Before"
        )
        _ = try await client.listThreads()

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"session_info","id":"rename","name":"After"}
        {"type":"message","id":"m2","message":{"role":"assistant","content":"newer","timestamp":2}}

        """.utf8))
        try handle.close()

        let detail = try await client.getThread(id: file.path)
        XCTAssertEqual(detail.thread.name, "Before", "detail lookup reuses the list snapshot")
        XCTAssertEqual(detail.messages.map(\.text), ["older", "newer"], "messages still read the current tail")
        let markedRead = try await client.markThreadRead(id: file.path, unread: false)
        XCTAssertEqual(markedRead.thread.name, "Before", "marking the open thread read also stays on the point-lookup path")
        let refreshedList = try await client.listThreads()
        XCTAssertEqual(refreshedList.threads.first?.name, "After", "the next list refreshes metadata")
    }

    func testGetUnknownThreadReturns404() async throws {
        do {
            _ = try await client.getThread(id: "no-such-thread")
            XCTFail("expected notFound")
        } catch PiDeskClientError.notFound {
            // expected
        }
    }

    func testUnknownRequestAgentIsRejectedInsteadOfFallingBackToPi() async throws {
        func post(_ path: String, body: String) throws -> String {
            let fd = try RawSocket.connectUnix(path: socketPath.path, timeout: 2)
            let data = Data(body.utf8)
            let request = "POST \(path) HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            try RawSocket.writeAll(fd: fd, data: Data(request.utf8) + data)
            let response = try RawSocket.readAllUntilClosed(fd: fd, maxBytes: 16_384)
            RawSocket.shutdownAndClose(fd: fd)
            return String(decoding: response, as: UTF8.self)
        }

        let thread = try post(
            "/v1/threads",
            body: #"{"cwd":"/tmp","agent":"typo"}"#
        )
        XCTAssertTrue(thread.hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(thread.contains("invalid_agent"))

        let schedule = try post(
            "/v1/schedules",
            body: #"{"name":"bad","target":{"kind":"newThread","cwd":"/tmp"},"prompt":"p","trigger":{"kind":"interval","everySeconds":60},"agent":"typo"}"#
        )
        XCTAssertTrue(schedule.hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(schedule.contains("invalid_agent"))
    }

    func testCompactThreadSuffixResolvesAndAmbiguousPrefixIsRejected() async throws {
        let id = "019f9dea-1234-4567-89ab-a1b2c3d4e5f6"
        _ = TestSupport.writeSessionFile(in: directory, id: id, cwd: "/tmp/project")
        let resolved = try await client.getThread(id: "a1b2c3d4e5f6")
        XCTAssertEqual(resolved.thread.id, id)
        XCTAssertEqual(resolved.thread.shortId, "a1b2c3d4e5f6")
        let schedule = try await client.createSchedule(ScheduleCreateRequest(
            name: "Compact target", target: .existingThread(threadId: "a1b2c3d4e5f6"),
            prompt: "p", trigger: .heartbeat(everySeconds: 900)
        )).schedule
        XCTAssertEqual(schedule.target.existingThreadID, id)

        _ = TestSupport.writeSessionFile(in: directory, id: "shared-one", cwd: "/tmp/project")
        _ = TestSupport.writeSessionFile(in: directory, id: "shared-two", cwd: "/tmp/project")
        do {
            _ = try await client.getThread(id: "shared")
            XCTFail("expected an ambiguous id error")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "ambiguous_thread_id")
        }
    }

    func testCopiedThreadsWithTheSameIDStayPathScopedAndRequireAPathForMutation() async throws {
        let first = TestSupport.writeSessionFile(in: directory, id: "copied", cwd: "/tmp/project")
        let second = first.deletingLastPathComponent().appendingPathComponent("copied-history.jsonl")
        try FileManager.default.copyItem(at: first, to: second)
        TestSupport.writeAppState(in: directory, archivedSessionPaths: [first.path])

        let listed = try await client.listThreads(limit: 10)
        XCTAssertEqual(listed.threads.count, 2)
        XCTAssertEqual(listed.threads.first(where: { $0.path == first.path })?.archived, true)
        XCTAssertEqual(listed.threads.first(where: { $0.path == second.path })?.archived, false)

        do {
            _ = try await client.archiveThread(id: "copied", archived: true)
            XCTFail("expected the duplicate id to be ambiguous")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "ambiguous_thread_id")
        }

        let archived = try await client.archiveThread(id: second.path, archived: true)
        XCTAssertEqual(archived.thread.path, second.path)
        XCTAssertTrue(archived.thread.archived)

        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                name: "Ambiguous copy",
                target: .existingThread(threadId: second.path),
                prompt: "p",
                trigger: .heartbeat(everySeconds: 900)
            ))
            XCTFail("a schedule cannot discard the path needed to disambiguate copied histories")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "ambiguous_thread_id")
        }
    }

    func testMutationRefreshesIDAmbiguityAfterACopyAppears() async throws {
        let first = TestSupport.writeSessionFile(in: directory, id: "copied-late", cwd: "/tmp/project")
        _ = try await client.listThreads(limit: 10)
        let second = first.deletingLastPathComponent().appendingPathComponent("late-copy.jsonl")
        try FileManager.default.copyItem(at: first, to: second)

        do {
            _ = try await client.archiveThread(id: "copied-late", archived: true)
            XCTFail("expected the newly ambiguous id to be rejected")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "ambiguous_thread_id")
        }

        let firstDetail = try await client.getThread(id: first.path)
        let secondDetail = try await client.getThread(id: second.path)
        XCTAssertEqual(firstDetail.thread.path, first.path)
        XCTAssertEqual(secondDetail.thread.path, second.path)
    }

    func testCopiedThreadsIsolateLiveDeliveryAndSubmissionReplayByPath() async throws {
        let first = TestSupport.writeSessionFile(in: directory, id: "copied-send", cwd: "/tmp/first")
        let second = first.deletingLastPathComponent().appendingPathComponent("copied-send-history.jsonl")
        try FileManager.default.copyItem(at: first, to: second)
        let runtime = FakeLiveRuntime()
        liveSessions.register(
            thread: ThreadInstanceKey(path: first.path), runID: "run_live", handle: runtime
        )
        let clientID = "same-retry-id"

        let delivered = try await client.sendMessage(
            threadId: first.path,
            SendMessageRequest(text: "first copy", delivery: .steer, clientId: clientID)
        )
        let other = try await client.sendMessage(
            threadId: second.path,
            SendMessageRequest(text: "second copy", delivery: .steer, clientId: clientID)
        )

        XCTAssertEqual(delivered.runId, "run_live")
        XCTAssertEqual(delivered.delivery, .steer)
        XCTAssertEqual(other.delivery, .auto)
        XCTAssertNotEqual(other.runId, delivered.runId, "the second path must not replay the first path's response")
        XCTAssertEqual(runtime.delivered.map(\.message), ["first copy"])
    }

    func testCopiedThreadsLeaseIndependentlyByExactPath() async throws {
        let first = TestSupport.writeSessionFile(in: directory, id: "copied-lease", cwd: "/tmp/first")
        let second = first.deletingLastPathComponent().appendingPathComponent("copied-lease-history.jsonl")
        try FileManager.default.copyItem(at: first, to: second)

        let firstLease = try await client.leaseThread(
            id: first.path, LeaseRequest(owner: "first-window", ttlSeconds: 60)
        )
        let secondLease = try await client.leaseThread(
            id: second.path, LeaseRequest(owner: "second-window", ttlSeconds: 60)
        )

        XCTAssertTrue(firstLease.leased)
        XCTAssertTrue(secondLease.leased, "a copied transcript must not inherit its sibling's lease")
    }

    func testCopiedThreadAbortOnlyDropsJobsForTheExactPath() async throws {
        let first = TestSupport.writeSessionFile(in: directory, id: "copied-abort", cwd: "/tmp/first")
        let second = first.deletingLastPathComponent().appendingPathComponent("copied-abort-history.jsonl")
        try FileManager.default.copyItem(at: first, to: second)
        let firstKey = ThreadInstanceKey(path: first.path)
        let reserved = await core.runQueue.reserveRuntime(thread: firstKey)
        XCTAssertTrue(reserved)
        await core.runQueue.enqueue(RunJob(
            id: "queued-copy", scheduleId: nil, trigger: .api,
            target: .existingThread(
                threadId: "copied-abort", path: first.path, cwd: "/tmp/first"
            ),
            prompt: "queued only", mode: nil, timeoutSeconds: 30, queuedAt: Date()
        ))

        let otherAbort = try await client.abortThread(id: second.path)
        let queuedAfterOtherAbort = await core.runQueue.queuedCount()
        XCTAssertFalse(otherAbort.aborted)
        XCTAssertEqual(queuedAfterOtherAbort, 1)

        let exactAbort = try await client.abortThread(id: first.path)
        let queuedAfterExactAbort = await core.runQueue.queuedCount()
        XCTAssertTrue(exactAbort.aborted)
        XCTAssertEqual(queuedAfterExactAbort, 0)
        await core.runQueue.releaseRuntime(thread: firstKey)
    }

    func testPathDetailRefreshesWhenATranscriptIsAtomicallyReplaced() async throws {
        let original = TestSupport.writeSessionFile(in: directory, id: "original", cwd: "/tmp/old")
        _ = try await client.listThreads(limit: 10)
        let replacement = TestSupport.writeSessionFile(in: directory, id: "replacement", cwd: "/tmp/new")
        let replacementData = try Data(contentsOf: replacement)
        try replacementData.write(to: original, options: .atomic)

        let detail = try await client.getThread(id: original.path)

        XCTAssertEqual(detail.thread.id, "replacement")
        XCTAssertEqual(detail.thread.cwd, "/tmp/new")
    }

    func testDialoguePagingExcludesToolResultsAndFindsOlderMessages() async throws {
        _ = TestSupport.writeSessionFile(
            in: directory, id: "dialogue", cwd: "/tmp/project",
            lines: [
                #"{"type":"message","id":"u1","message":{"role":"user","content":"u1","timestamp":1}}"#,
                #"{"type":"message","id":"a1","message":{"role":"assistant","content":"a1","timestamp":2}}"#,
                #"{"type":"message","id":"t1","message":{"role":"toolResult","content":"tool","timestamp":3}}"#,
                #"{"type":"message","id":"u2","message":{"role":"user","content":"u2","timestamp":4}}"#,
                #"{"type":"message","id":"a2","message":{"role":"assistant","content":"a2","timestamp":5}}"#
            ]
        )
        let newest = try await client.getThread(
            id: "dialogue", messages: 2, offset: 0, includeTools: false
        )
        XCTAssertEqual(newest.messages.map(\.text), ["u2", "a2"])
        XCTAssertEqual(newest.nextOffset, 2)
        let older = try await client.getThread(
            id: "dialogue", messages: 2, offset: 2, includeTools: false
        )
        XCTAssertEqual(older.messages.map(\.text), ["u1", "a1"])
        XCTAssertNil(older.nextOffset)
    }

    func testThreadListProjectsDesktopManagedWorktreeMetadata() async throws {
        let worktree = "/tmp/pi-managed-worktree"
        let project = "/tmp/source-project"
        try JSONSerialization.data(withJSONObject: [
            "managedWorktreeProjects": [worktree: project]
        ]).write(to: directory.appendingPathComponent("state.json"))
        _ = TestSupport.writeSessionFile(in: directory, id: "desktop-worktree", cwd: worktree)

        let listed = try await client.listThreads()
        let thread = try XCTUnwrap(listed.threads.first)
        XCTAssertEqual(thread.cwd, worktree)
        XCTAssertEqual(thread.project, project)
        XCTAssertEqual(thread.worktree, worktree)
    }

    func testAutomatedFilterAndFlagIncludePausedSchedules() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "automated-thread", cwd: "/tmp/project")
        _ = try await client.createSchedule(ScheduleCreateRequest(
            name: "Paused automation", enabled: false,
            target: .existingThread(threadId: "automated-thread"), prompt: "p",
            trigger: .heartbeat(everySeconds: 900)
        ))
        let threads = try await client.listThreads(automated: true).threads
        XCTAssertEqual(threads.map(\.id), ["automated-thread"])
        XCTAssertEqual(try XCTUnwrap(threads.first).automated, true)
    }

    func testArchiveAndReadRoundTripThroughTheOverlay() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-2", cwd: "/tmp/project")
        let archived = try await client.archiveThread(id: "sess-2", archived: true)
        XCTAssertTrue(archived.thread.archived)

        let list = try await client.listThreads(archived: true)
        XCTAssertEqual(list.threads.map(\.id), ["sess-2"])

        let unarchived = try await client.archiveThread(id: "sess-2", archived: false)
        XCTAssertFalse(unarchived.thread.archived)

        let readResult = try await client.markThreadRead(id: "sess-2", unread: true)
        XCTAssertTrue(readResult.thread.unread)
    }

    func testSendingToAnArchivedThreadRestoresIt() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-archived", cwd: "/tmp/project")
        _ = try await client.archiveThread(id: "sess-archived", archived: true)

        _ = try await client.sendMessage(threadId: "sess-archived", SendMessageRequest(text: "resume this"))

        let restored = try await client.getThread(id: "sess-archived")
        XCTAssertFalse(restored.thread.archived)
    }

    func testRunningThreadBecomesUnreadOnlyAfterItFinishes() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-running", cwd: "/tmp/project")
        let heartbeatURL = directory.appendingPathComponent("activity/sess-running.json")
        let writeHeartbeat: (String) throws -> Void = { state in
            let completion = state == "idle" ? ",\"completionId\":\"answer-1\"" : ""
            try """
            {"sessionId":"sess-running","pid":\(getpid()),"state":"\(state)","updatedAt":"\(PiDeskDate.string(from: Date()))"\(completion)}
            """.write(to: heartbeatURL, atomically: true, encoding: .utf8)
        }

        try writeHeartbeat("running")
        let runningList = try await client.listThreads()
        let runningThread = try XCTUnwrap(runningList.threads.first)
        XCTAssertTrue(runningThread.running)
        XCTAssertFalse(runningThread.unread, "A running turn is not unread yet")

        try writeHeartbeat("idle")
        let idleDetail = try await client.getThread(id: "sess-running")
        XCTAssertFalse(idleDetail.thread.running, "point lookup refreshes heartbeat state without rescanning sessions")
        let idleList = try await client.listThreads()
        let idleThread = try XCTUnwrap(idleList.threads.first)
        XCTAssertFalse(idleThread.running)
        XCTAssertTrue(idleThread.unread, "The completed turn becomes unread")
    }

    func testPathlessHeartbeatDoesNotAttachToDuplicateSessionIDs() async throws {
        let source = TestSupport.writeSessionFile(in: directory, id: "duplicate", cwd: "/tmp/project")
        let copy = source.deletingLastPathComponent().appendingPathComponent("duplicate-copy.jsonl")
        try FileManager.default.copyItem(at: source, to: copy)
        try """
        {"sessionId":"duplicate","pid":\(getpid()),"state":"running","updatedAt":"\(PiDeskDate.string(from: Date()))","completionId":"answer"}
        """.write(
            to: directory.appendingPathComponent("activity/duplicate.json"),
            atomically: true,
            encoding: .utf8
        )

        let threads = try await client.listThreads().threads
        XCTAssertEqual(threads.count, 2)
        XCTAssertTrue(threads.allSatisfy { !$0.running })
    }

    func testSendMessageEnqueuesAFakeRunAndItCompletes() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-3", cwd: "/tmp/project")
        let sent = try await client.sendMessage(threadId: "sess-3", SendMessageRequest(text: "do the thing"))
        XCTAssertNotNil(sent.runId)
        XCTAssertFalse(sent.queued)

        var finalStatus: RunStatus?
        for _ in 0..<50 {
            let run = try await client.getRun(id: sent.runId!)
            if run.run.status != .running { finalStatus = run.run.status; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(finalStatus, .ok)
    }

    func testAbortOfAnIdleThreadReturnsFalse() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-4", cwd: "/tmp/project")
        let result = try await client.abortThread(id: "sess-4")
        XCTAssertFalse(result.aborted)
    }

    func testLeaseThenLeasedThreadRejectsAMessage() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-5", cwd: "/tmp/project")
        let lease = try await client.leaseThread(id: "sess-5", LeaseRequest(owner: "app-under-test", ttlSeconds: 60))
        XCTAssertTrue(lease.leased)

        do {
            _ = try await client.sendMessage(threadId: "sess-5", SendMessageRequest(text: "hi"))
            XCTFail("expected a conflict while the thread is leased")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "thread_leased")
        }
    }

    func testLeaseCannotAttachWhileTheRunQueueOwnsTheThread() async throws {
        let file = TestSupport.writeSessionFile(
            in: directory, id: "sess-lease-busy", cwd: "/tmp/project"
        )
        let key = ThreadInstanceKey(path: file.path)
        let reserved = await core.runQueue.reserveRuntime(thread: key)
        XCTAssertTrue(reserved)

        do {
            _ = try await client.leaseThread(
                id: file.path, LeaseRequest(owner: "native", ttlSeconds: 60)
            )
            XCTFail("expected a conflict while the queue owns the transcript")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "thread_busy")
        }

        await core.runQueue.releaseRuntime(thread: key)
        let lease = try await client.leaseThread(
            id: file.path, LeaseRequest(owner: "native", ttlSeconds: 60)
        )
        XCTAssertTrue(lease.leased)
    }

    // MARK: - Activity

    func testActivityReportsNoRunningThreadsByDefault() async throws {
        let activity = try await client.activity()
        XCTAssertEqual(activity.running, [])
        XCTAssertEqual(activity.unreadCount, 0)
    }

    func testActivityClassifiesCopiedHistoriesByHeartbeatPath() async throws {
        let first = TestSupport.writeSessionFile(
            in: directory, id: "copied-activity", cwd: "/tmp/first"
        )
        let second = first.deletingLastPathComponent()
            .appendingPathComponent("copied-activity-history.jsonl")
        try FileManager.default.copyItem(at: first, to: second)
        let firstKey = ThreadInstanceKey(path: first.path)
        let secondKey = ThreadInstanceKey(path: second.path)
        _ = await core.leaseStore.acquire(
            thread: secondKey, owner: "second-window", ttlSeconds: 60
        )

        let activityDirectory = directory.appendingPathComponent("activity", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory, withIntermediateDirectories: true
        )
        let timestamp = PiDeskDate.string(from: Date())
        for (name, path) in [("first", first.path), ("second", second.path)] {
            try """
            {"sessionId":"copied-activity","sessionFile":"\(path)","pid":\(getpid()),"state":"running","startedAt":"\(timestamp)","updatedAt":"\(timestamp)"}
            """.write(
                to: activityDirectory.appendingPathComponent("\(name).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        let service = ActivityService(
            logger: TestSupport.logger(in: directory),
            threadStore: core.threadStore,
            leaseStore: core.leaseStore,
            activityDirectoryURL: activityDirectory,
            daemonActiveThreadKeys: { Set([firstKey]) }
        )

        let activity = await service.snapshot()

        XCTAssertEqual(activity.running.count, 2)
        XCTAssertEqual(Set(activity.running.map(\.source)), Set([.daemon, .app]))
    }

    func testAmbiguousIDOnlyHeartbeatDoesNotHideOrAttachToACopiedHistory() async throws {
        let first = TestSupport.writeSessionFile(
            in: directory, id: "ambiguous-activity", cwd: "/tmp/first"
        )
        let second = first.deletingLastPathComponent()
            .appendingPathComponent("ambiguous-activity-history.jsonl")
        try FileManager.default.copyItem(at: first, to: second)
        let handle = try FileHandle(forWritingTo: second)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            #"{"type":"message","id":"work","message":{"role":"user","content":"continue"}}"#.utf8
        ))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let activityDirectory = directory.appendingPathComponent("activity", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory, withIntermediateDirectories: true
        )
        let now = Date()
        let timestamp = PiDeskDate.string(from: now)
        try """
        {"sessionId":"ambiguous-activity","sessionFile":"\(first.path)","pid":\(getpid()),"state":"running","startedAt":"\(timestamp)","updatedAt":"\(timestamp)"}
        """.write(
            to: activityDirectory.appendingPathComponent("path.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"sessionId":"ambiguous-activity","sessionFile":"","pid":\(getpid()),"state":"running","startedAt":"\(timestamp)","updatedAt":"\(timestamp)"}
        """.write(
            to: activityDirectory.appendingPathComponent("id-only.json"),
            atomically: true,
            encoding: .utf8
        )
        let service = ActivityService(
            logger: TestSupport.logger(in: directory),
            threadStore: core.threadStore,
            leaseStore: core.leaseStore,
            activityDirectoryURL: activityDirectory,
            daemonActiveThreadKeys: { [] }
        )

        let activity = await service.snapshot(now: now)

        XCTAssertEqual(activity.running.count, 3)
        XCTAssertEqual(
            Set(activity.running.compactMap(\.threadPath)), Set([first.path, second.path])
        )
        XCTAssertEqual(activity.running.filter { $0.threadPath == nil }.count, 1)
    }

    func testActivityCollapsesMultipleLiveHeartbeatWritersForOneTranscript() async throws {
        let file = TestSupport.writeSessionFile(
            in: directory, id: "shared-heartbeat", cwd: directory.path
        )
        let activityDirectory = directory.appendingPathComponent("activity", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory, withIntermediateDirectories: true
        )
        let now = Date()
        let timestamp = PiDeskDate.string(from: now)
        let earlier = PiDeskDate.string(from: now.addingTimeInterval(-5))
        for (name, startedAt) in [("first", earlier), ("second", timestamp)] {
            try """
            {"sessionId":"shared-heartbeat","sessionFile":"\(file.path)","pid":\(getpid()),"state":"running","startedAt":"\(startedAt)","updatedAt":"\(timestamp)"}
            """.write(
                to: activityDirectory.appendingPathComponent("\(name).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        let oldest = PiDeskDate.string(from: now.addingTimeInterval(-8))
        try """
        {"sessionId":"shared-heartbeat","pid":\(getpid()),"state":"running","startedAt":"\(oldest)","updatedAt":"\(timestamp)"}
        """.write(
            to: activityDirectory.appendingPathComponent("legacy-id-only.json"),
            atomically: true,
            encoding: .utf8
        )
        let service = ActivityService(
            logger: TestSupport.logger(in: directory),
            threadStore: core.threadStore,
            leaseStore: core.leaseStore,
            activityDirectoryURL: activityDirectory,
            daemonActiveThreadKeys: { [] }
        )

        let activity = await service.snapshot(now: now)

        XCTAssertEqual(activity.running.count, 1)
        XCTAssertEqual(activity.running.first?.threadPath, file.path)
        XCTAssertEqual(
            try XCTUnwrap(activity.running.first?.since).timeIntervalSince1970,
            now.addingTimeInterval(-8).timeIntervalSince1970,
            accuracy: 0.01
        )
    }

    func testDaemonOwnershipIsAuthoritativeForCodexAndClaudeActivity() async throws {
        let codexRoot = directory.appendingPathComponent("codex", isDirectory: true)
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        let codex = TestSupport.writeCodexRollout(
            in: codexRoot, id: "active-codex", cwd: directory.path
        )
        let claude = TestSupport.writeClaudeTranscript(
            in: claudeRoot, id: "active-claude", cwd: directory.path
        )
        for file in [codex, claude] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-600)],
                ofItemAtPath: file.path
            )
        }
        let store = ThreadStore(
            rootURL: directory.appendingPathComponent("unused"),
            roots: [(.codex, codexRoot), (.claude, claudeRoot)],
            activityDirectoryURL: directory.appendingPathComponent("no-heartbeats"),
            appStateURL: directory.appendingPathComponent("state.json"),
            logger: TestSupport.logger(in: directory),
            overlay: DaemonOverlayStore(fileURL: directory.appendingPathComponent("active-overlay.json"))
        )
        let activeKeys = Set([ThreadInstanceKey(path: codex.path), ThreadInstanceKey(path: claude.path)])
        let service = ActivityService(
            logger: TestSupport.logger(in: directory),
            threadStore: store,
            leaseStore: LeaseStore(),
            activityDirectoryURL: directory.appendingPathComponent("no-heartbeats"),
            daemonActiveThreadKeys: { activeKeys }
        )

        let activity = await service.snapshot()

        XCTAssertEqual(Set(activity.running.compactMap(\.threadPath)), Set([codex.path, claude.path]))
        XCTAssertEqual(Set(activity.running.map(\.source)), [.daemon])
    }

    // MARK: - Schedules

    func testScheduleCRUDLifecycle() async throws {
        let created = try await client.createSchedule(ScheduleCreateRequest(
            name: "Nightly triage",
            target: .existingThread(threadId: "thread-x"),
            prompt: "Summarise overnight CI failures",
            trigger: .cron(expression: "0 9 * * 1-5", timeZone: "UTC")
        ))
        XCTAssertEqual(created.schedule.name, "Nightly triage")
        XCTAssertNotNil(created.schedule.nextRunAt, "creation must compute an initial nextRunAt")
        let id = created.schedule.id
        var withPending = created.schedule
        withPending.pendingOccurrence = ScheduleOccurrence(
            id: "occ-preserved", scheduledAt: Date(), notBefore: Date()
        )
        try await core.scheduleStore.upsert(withPending)

        let list = try await client.listSchedules()
        XCTAssertEqual(list.schedules.map(\.id), [id])

        let updated = try await client.updateSchedule(id: id, ScheduleUpdateRequest(name: "Renamed"))
        XCTAssertEqual(updated.schedule.name, "Renamed")
        XCTAssertEqual(updated.schedule.pendingOccurrence?.id, "occ-preserved")

        let paused = try await client.pauseSchedule(id: id, paused: true)
        XCTAssertFalse(paused.schedule.enabled)
        XCTAssertEqual(paused.schedule.pendingOccurrence?.id, "occ-preserved")

        let detail = try await client.getSchedule(id: id)
        XCTAssertEqual(detail.schedule.id, id)
        XCTAssertEqual(detail.runs, [])

        let deleted = try await client.deleteSchedule(id: id)
        XCTAssertTrue(deleted.deleted)
        let afterDelete = try await client.listSchedules()
        XCTAssertTrue(afterDelete.schedules.isEmpty)
    }

    func testPendingScheduleFreezesTargetAndAgentButAllowsAFullFormRename() async throws {
        let now = Date()
        let originalTarget = ScheduleTarget.newThread(
            cwd: directory.path, namePattern: "Pending {date}"
        )
        var schedule = Schedule(
            id: "sch-pending-identity", name: "Pending", target: originalTarget,
            prompt: "work", trigger: .interval(everySeconds: 900, startAt: nil),
            policy: SchedulePolicy(), agent: nil,
            createdAt: now, updatedAt: now, nextRunAt: now.addingTimeInterval(900)
        )
        schedule.pendingOccurrence = ScheduleOccurrence(
            id: "occ-pending-identity", scheduledAt: now,
            phase: .starting, attemptCount: 1, notBefore: now,
            runId: "run-pending-identity", threadId: "reserved-id",
            threadPath: directory.appendingPathComponent("reserved.jsonl").path
        )
        try await core.scheduleStore.upsert(schedule)
        let alternate = directory.appendingPathComponent("alternate", isDirectory: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)

        do {
            _ = try await client.updateSchedule(
                id: schedule.id,
                ScheduleUpdateRequest(
                    target: .newThread(cwd: alternate.path, namePattern: nil)
                )
            )
            XCTFail("expected target changes to be rejected while an occurrence is owed")
        } catch let PiDeskClientError.badRequest(code, message) {
            XCTAssertEqual(code, "schedule_occurrence_in_flight")
            XCTAssertTrue(message.contains("pending automation run"))
        }
        let afterTargetRejection = await core.scheduleStore.get(id: schedule.id)
        XCTAssertEqual(afterTargetRejection, schedule)

        do {
            _ = try await client.updateSchedule(
                id: schedule.id, ScheduleUpdateRequest(agent: .codex)
            )
            XCTFail("expected agent changes to be rejected while an occurrence is owed")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "schedule_occurrence_in_flight")
        }
        let afterAgentRejection = await core.scheduleStore.get(id: schedule.id)
        XCTAssertEqual(afterAgentRejection, schedule)

        let renamed = try await client.updateSchedule(
            id: schedule.id,
            ScheduleUpdateRequest(
                name: "Renamed safely", target: originalTarget, agent: .pi
            )
        )
        XCTAssertEqual(renamed.schedule.name, "Renamed safely")
        XCTAssertEqual(renamed.schedule.target, originalTarget)
        XCTAssertEqual(renamed.schedule.agent, .pi)
        XCTAssertEqual(renamed.schedule.pendingOccurrence?.id, schedule.pendingOccurrence?.id)
        XCTAssertEqual(renamed.schedule.pendingOccurrence?.phase, .starting)
        XCTAssertEqual(renamed.schedule.pendingOccurrence?.runId, "run-pending-identity")
        XCTAssertEqual(renamed.schedule.pendingOccurrence?.threadId, "reserved-id")
        XCTAssertEqual(
            renamed.schedule.pendingOccurrence?.threadPath,
            directory.appendingPathComponent("reserved.jsonl").path
        )
    }

    func testScheduleCreationIsIdempotentAcrossAnUnconfirmedRetry() async throws {
        let key = "0123456789abcdef0123456789abcdef"
        let originalThread = TestSupport.writeSessionFile(
            in: directory, id: "schedule-replay-thread", cwd: directory.path
        )
        let request = ScheduleCreateRequest(
            idempotencyKey: key,
            name: "Retry-safe",
            target: .existingThread(threadId: originalThread.path),
            prompt: "Run once",
            trigger: .interval(everySeconds: 900, startAt: nil)
        )
        let first = try await client.createSchedule(request)
        XCTAssertEqual(
            first.schedule.target,
            .existingThread(threadId: "schedule-replay-thread")
        )
        let expectedTargetFingerprint = SubmissionRegistry.fingerprint(parts: [
            "schedule-create-target-v1", "existingThread", originalThread.path
        ])
        XCTAssertEqual(
            first.schedule.creationTargetFingerprint,
            "v1:\(expectedTargetFingerprint)"
        )
        let copiedThread = originalThread.deletingLastPathComponent()
            .appendingPathComponent("schedule-replay-copy.jsonl")
        try FileManager.default.copyItem(at: originalThread, to: copiedThread)
        let retried = try await client.createSchedule(request)
        XCTAssertEqual(retried.schedule.id, first.schedule.id)
        try FileManager.default.removeItem(at: originalThread)
        try FileManager.default.removeItem(at: copiedThread)
        let afterRemoval = try await client.createSchedule(request)
        XCTAssertEqual(afterRemoval.schedule.id, first.schedule.id)
        let schedules = try await client.listSchedules()
        XCTAssertEqual(schedules.schedules.count, 1)

        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                idempotencyKey: key,
                name: "Different request",
                target: .existingThread(threadId: "schedule-replay-thread"),
                prompt: "Run once",
                trigger: .interval(everySeconds: 900, startAt: nil)
            ))
            XCTFail("expected an idempotency conflict")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "idempotency_conflict")
        }
    }

    func testEditingAnIdempotentScheduleInvalidatesItsRawTargetReplayToken() async throws {
        let key = "fedcba9876543210fedcba9876543210"
        let transcript = TestSupport.writeSessionFile(
            in: directory, id: "schedule-edited-thread", cwd: directory.path
        )
        let original = ScheduleCreateRequest(
            idempotencyKey: key,
            name: "Before edit",
            target: .existingThread(threadId: transcript.path),
            prompt: "Run once",
            trigger: .interval(everySeconds: 900, startAt: nil)
        )
        let created = try await client.createSchedule(original)
        XCTAssertNotNil(created.schedule.creationTargetFingerprint)
        let updated = try await client.updateSchedule(
            id: created.schedule.id, ScheduleUpdateRequest(name: "After edit")
        )
        XCTAssertNil(updated.schedule.creationTargetFingerprint)
        try FileManager.default.removeItem(at: transcript)

        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                idempotencyKey: key,
                name: "After edit",
                target: .existingThread(threadId: transcript.path),
                prompt: "Run once",
                trigger: .interval(everySeconds: 900, startAt: nil)
            ))
            XCTFail("expected an idempotency conflict after the schedule was edited")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "idempotency_conflict")
        }

        let paused = try await client.pauseSchedule(id: created.schedule.id, paused: true)
        XCTAssertNil(paused.schedule.creationTargetFingerprint)
    }

    func testInvalidScheduleIdempotencyKeyIsRejected() async throws {
        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                idempotencyKey: "too-short",
                name: "Invalid key",
                target: .existingThread(threadId: "thread-x"),
                prompt: "Run once",
                trigger: .heartbeat(everySeconds: 900)
            ))
            XCTFail("expected an invalid key error")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "invalid_idempotency_key")
        }
    }

    func testScheduleTimeoutValidationRejectsUnsafeCreateAndUpdateValues() async throws {
        for timeout in [0, ScheduleEngine.maximumTimeoutSeconds + 1] {
            do {
                _ = try await client.createSchedule(ScheduleCreateRequest(
                    name: "Invalid timeout \(timeout)",
                    target: .newThread(cwd: directory.path, namePattern: nil),
                    prompt: "Never runs",
                    trigger: .interval(everySeconds: 900, startAt: nil),
                    policy: SchedulePolicy(timeoutSeconds: timeout)
                ))
                XCTFail("expected invalid_timeout")
            } catch let PiDeskClientError.badRequest(code, _) {
                XCTAssertEqual(code, "invalid_timeout")
            }
        }

        let created = try await client.createSchedule(ScheduleCreateRequest(
            name: "Valid timeout",
            target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "Safe",
            trigger: .interval(everySeconds: 900, startAt: nil),
            policy: SchedulePolicy(timeoutSeconds: ScheduleEngine.maximumTimeoutSeconds)
        ))
        do {
            _ = try await client.updateSchedule(
                id: created.schedule.id,
                ScheduleUpdateRequest(policy: SchedulePolicy(timeoutSeconds: -1))
            )
            XCTFail("expected invalid_timeout")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "invalid_timeout")
        }
    }

    func testCreatingAScheduleWithAnUnparseableCronIsRejected() async throws {
        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                name: "Bad", target: .existingThread(threadId: "t1"), prompt: "p",
                trigger: .cron(expression: "not a cron expression", timeZone: nil)
            ))
            XCTFail("expected a 400")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "invalid_cron")
        }
    }

    func testCreatingAScheduleWithAnEmptyNameIsRejected() async throws {
        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                name: "   ", target: .existingThread(threadId: "t1"), prompt: "p", trigger: .heartbeat(everySeconds: 900)
            ))
            XCTFail("expected a 400")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "invalid_name")
        }
    }

    func testScheduleRunNowEnqueuesAndRecordsARun() async throws {
        let created = try await client.createSchedule(ScheduleCreateRequest(
            name: "Manual", target: .newThread(cwd: "/tmp/project", namePattern: nil), prompt: "p", trigger: .heartbeat(everySeconds: 900)
        ))
        let response = try await client.runSchedule(id: created.schedule.id)
        XCTAssertFalse(response.runId.isEmpty)

        var found = false
        for _ in 0..<50 {
            let runs = try await client.listRuns(scheduleId: created.schedule.id, limit: 10)
            if !runs.runs.isEmpty { found = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(found)
    }

    func testGetUnknownScheduleReturns404() async throws {
        do {
            _ = try await client.getSchedule(id: "nope")
            XCTFail("expected notFound")
        } catch PiDeskClientError.notFound {}
    }

    // MARK: - Runs

    func testListRunsEmptyInitially() async throws {
        let runs = try await client.listRuns()
        XCTAssertEqual(runs.runs, [])
    }

    // MARK: - Limits

    func testLimitsStartsStaleAndEmpty() async throws {
        let snapshot = try await client.limits()
        XCTAssertTrue(snapshot.stale)
        XCTAssertTrue(snapshot.report.accounts.isEmpty)
    }

    // MARK: - Hosted remote

    func testHostedRemoteStatusIsAvailableLocallyWithoutStartingANetworkConnection() async throws {
        let status = try await client.remoteAccessStatus()
        XCTAssertEqual(status.connection, .offline)
        XCTAssertEqual(status.relayURL, "https://remote.ai.gloom.sh")
        XCTAssertTrue(status.devices.isEmpty)
    }

    func testPairingClearlyReportsAnOfflineRelay() async throws {
        do {
            _ = try await client.createRemotePairing()
            XCTFail("expected relay_offline")
        } catch let PiDeskClientError.server(status, code, _) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(code, "relay_offline")
        }
    }

    func testRelayCannotCallLocalPairingManagementRoutes() async throws {
        let router = DaemonRouter(routes: Routes.all(core))
        let response = await router.handle(HTTPRequest(
            method: "GET",
            path: "/v1/remote",
            query: [:],
            headers: [:],
            body: Data(),
            origin: .relay
        ))
        XCTAssertEqual(response.status, 401)
    }

    // MARK: - Events (SSE)

    func testEventsStreamDeliversScheduleMutationAndDeletionEvents() async throws {
        let stream = client.events()
        var iterator = stream.makeAsyncIterator()
        let ready = try await iterator.next()
        guard case let .unknown(name, _) = ready, name == "ready" else {
            return XCTFail("expected the ready barrier, got \(String(describing: ready))")
        }
        let created = try await client.createSchedule(ScheduleCreateRequest(
            name: "Event test", target: .existingThread(threadId: "t1"), prompt: "p", trigger: .heartbeat(everySeconds: 900)
        ))

        let createEvent = try await iterator.next()
        guard case let .schedule(createdSchedule) = createEvent else {
            return XCTFail("expected a create .schedule event, got \(String(describing: createEvent))")
        }
        XCTAssertEqual(createdSchedule.name, "Event test")

        _ = try await client.updateSchedule(
            id: created.schedule.id,
            ScheduleUpdateRequest(name: "Updated event test")
        )
        let updateEvent = try await iterator.next()
        guard case let .schedule(updatedSchedule) = updateEvent else {
            return XCTFail("expected an update .schedule event, got \(String(describing: updateEvent))")
        }
        XCTAssertEqual(updatedSchedule.name, "Updated event test")

        _ = try await client.pauseSchedule(id: created.schedule.id, paused: true)
        let pauseEvent = try await iterator.next()
        guard case let .schedule(pausedSchedule) = pauseEvent else {
            return XCTFail("expected a pause .schedule event, got \(String(describing: pauseEvent))")
        }
        XCTAssertFalse(pausedSchedule.enabled)

        _ = try await client.deleteSchedule(id: created.schedule.id)
        let deleteEvent = try await iterator.next()
        guard case let .unknown(name, payload) = deleteEvent, name == "schedule_deleted" else {
            return XCTFail("expected schedule_deleted, got \(String(describing: deleteEvent))")
        }
        XCTAssertEqual(payload["id"]?.stringValue, created.schedule.id)
    }

    func testEventsStreamDeliversTheAuthoritativeArchiveMutation() async throws {
        let file = TestSupport.writeSessionFile(in: directory, id: "event-thread", cwd: "/tmp/project")
        _ = try await client.listThreads()
        let stream = client.events()
        var iterator = stream.makeAsyncIterator()
        let ready = try await iterator.next()
        guard case let .unknown(name, _) = ready, name == "ready" else {
            return XCTFail("expected the ready barrier, got \(String(describing: ready))")
        }

        let archived = try await client.archiveThread(id: file.path, archived: true)

        let event = try await iterator.next()
        guard case let .thread(thread) = event else {
            return XCTFail("expected a .thread event, got \(String(describing: event))")
        }
        XCTAssertEqual(thread.path, file.standardizedFileURL.path)
        XCTAssertTrue(thread.archived)
        XCTAssertEqual(thread, archived.thread)

        let restored = try await client.archiveThread(id: file.path, archived: false)
        let restoreEvent = try await iterator.next()
        guard case let .thread(restoredThread) = restoreEvent else {
            return XCTFail("expected a restore .thread event, got \(String(describing: restoreEvent))")
        }
        XCTAssertEqual(restoredThread.path, file.standardizedFileURL.path)
        XCTAssertFalse(restoredThread.archived)
        XCTAssertEqual(restoredThread, restored.thread)
    }

    // MARK: - Resilience

    func testEventStreamAdmissionReturns503AndCapacityReturnsAfterDisconnect() async throws {
        func openStream() throws -> (Int32, String) {
            let fd = try RawSocket.connectUnix(path: socketPath.path, timeout: 2)
            try RawSocket.writeAll(
                fd: fd,
                data: Data("GET /v1/events HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)
            )
            let response = String(
                decoding: RawSocket.read(fd: fd, maxBytes: 8_192) ?? Data(),
                as: UTF8.self
            )
            return (fd, response)
        }

        let (first, firstResponse) = try openStream()
        XCTAssertTrue(firstResponse.hasPrefix("HTTP/1.1 200"))

        let (second, secondResponse) = try openStream()
        RawSocket.shutdownAndClose(fd: second)
        XCTAssertTrue(secondResponse.hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue(secondResponse.contains("event_streams_busy"))

        RawSocket.shutdownAndClose(fd: first)
        core.bus.publish(.unknown(name: "probe", data: .object([:])))

        var admittedAgain = false
        for _ in 0..<50 where !admittedAgain {
            try await Task.sleep(nanoseconds: 20_000_000)
            let (candidate, response) = try openStream()
            admittedAgain = response.hasPrefix("HTTP/1.1 200")
            RawSocket.shutdownAndClose(fd: candidate)
        }
        XCTAssertTrue(admittedAgain, "disconnecting an event stream must return its slot")
    }

    func testMalformedRequestGetsA400AndTheServerKeepsServingAfterward() async throws {
        let raw = try RawSocket.connectUnix(path: socketPath.path, timeout: 2)
        try RawSocket.writeAll(fd: raw, data: Data("NOT A REAL HTTP REQUEST\r\n\r\n".utf8))
        let response = try RawSocket.readAllUntilClosed(fd: raw, maxBytes: 8_192)
        RawSocket.shutdownAndClose(fd: raw)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400"))

        // The listener/accept loop must not have been affected by the malformed connection.
        let health = try await client.health()
        XCTAssertTrue(health.ok)
    }

    func testOversizedBodyIsRejectedWithoutCrashing() async throws {
        let raw = try RawSocket.connectUnix(path: socketPath.path, timeout: 2)
        let head = "POST /v1/schedules HTTP/1.1\r\nContent-Length: 999999999\r\nConnection: close\r\n\r\n"
        try RawSocket.writeAll(fd: raw, data: Data(head.utf8))
        let response = try RawSocket.readAllUntilClosed(fd: raw, maxBytes: 8_192)
        RawSocket.shutdownAndClose(fd: raw)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400"))

        let health = try await client.health()
        XCTAssertTrue(health.ok)
    }
}
