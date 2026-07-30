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

    override func setUp() async throws {
        try await super.setUp()
        directory = TestSupport.tempDirectory()
        core = TestSupport.makeCore(in: directory)
        socketPath = directory.appendingPathComponent("daemon.sock")
        let router = DaemonRouter(routes: Routes.all(core))
        server = HTTPServer(router: router, logger: TestSupport.logger(in: directory), bus: core.bus, tokenProvider: { nil })
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
        XCTAssertEqual(health.runningRuns, 0)
        XCTAssertEqual(health.queuedRuns, 0)
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

    func testShowReusesTheListedThreadInsteadOfRefreshingEverySession() async throws {
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

        let detail = try await client.getThread(id: "sess-fast")
        XCTAssertEqual(detail.thread.name, "Before", "detail lookup reuses the list snapshot")
        XCTAssertEqual(detail.messages.map(\.text), ["older", "newer"], "messages still read the current tail")
        let markedRead = try await client.markThreadRead(id: "sess-fast", unread: false)
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

    // MARK: - Activity

    func testActivityReportsNoRunningThreadsByDefault() async throws {
        let activity = try await client.activity()
        XCTAssertEqual(activity.running, [])
        XCTAssertEqual(activity.unreadCount, 0)
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

    func testScheduleCreationIsIdempotentAcrossAnUnconfirmedRetry() async throws {
        let key = "0123456789abcdef0123456789abcdef"
        let request = ScheduleCreateRequest(
            idempotencyKey: key,
            name: "Retry-safe",
            target: .existingThread(threadId: "thread-x"),
            prompt: "Run once",
            trigger: .interval(everySeconds: 900, startAt: nil)
        )
        let first = try await client.createSchedule(request)
        let retried = try await client.createSchedule(request)
        XCTAssertEqual(retried.schedule.id, first.schedule.id)
        let schedules = try await client.listSchedules()
        XCTAssertEqual(schedules.schedules.count, 1)

        do {
            _ = try await client.createSchedule(ScheduleCreateRequest(
                idempotencyKey: key,
                name: "Different request",
                target: .existingThread(threadId: "thread-x"),
                prompt: "Run once",
                trigger: .interval(everySeconds: 900, startAt: nil)
            ))
            XCTFail("expected an idempotency conflict")
        } catch let PiDeskClientError.badRequest(code, _) {
            XCTAssertEqual(code, "idempotency_conflict")
        }
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

    func testEventsStreamDeliversAScheduleEvent() async throws {
        let stream = client.events()
        var iterator = stream.makeAsyncIterator()

        let received = Task<PiDeskEvent?, Never> { try? await iterator.next() }
        // Give the SSE connection a moment to establish before publishing.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await client.createSchedule(ScheduleCreateRequest(
            name: "Event test", target: .existingThread(threadId: "t1"), prompt: "p", trigger: .heartbeat(everySeconds: 900)
        ))

        let event = await received.value
        guard case let .schedule(schedule) = event else {
            return XCTFail("expected a .schedule event, got \(String(describing: event))")
        }
        XCTAssertEqual(schedule.name, "Event test")
    }

    func testThreadMutationPublishesAThreadEvent() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "live-archive", cwd: "/tmp/project")
        let stream = client.events()
        var iterator = stream.makeAsyncIterator()
        let received = Task<PiDeskEvent?, Never> { try? await iterator.next() }
        try await Task.sleep(nanoseconds: 200_000_000)

        _ = try await client.archiveThread(id: "live-archive", archived: true)

        let event = await received.value
        guard case let .thread(thread) = event else {
            return XCTFail("expected a .thread event, got \(String(describing: event))")
        }
        XCTAssertEqual(thread.id, "live-archive")
        XCTAssertTrue(thread.archived)
    }

    // MARK: - Resilience

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
