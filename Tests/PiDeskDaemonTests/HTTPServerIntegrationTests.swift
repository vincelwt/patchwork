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
        XCTAssertEqual(health.api, PiDeskKit.apiVersion)
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

    func testGetUnknownThreadReturns404() async throws {
        do {
            _ = try await client.getThread(id: "no-such-thread")
            XCTFail("expected notFound")
        } catch PiDeskClientError.notFound {
            // expected
        }
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

        let list = try await client.listSchedules()
        XCTAssertEqual(list.schedules.map(\.id), [id])

        let updated = try await client.updateSchedule(id: id, ScheduleUpdateRequest(name: "Renamed"))
        XCTAssertEqual(updated.schedule.name, "Renamed")

        let paused = try await client.pauseSchedule(id: id, paused: true)
        XCTAssertFalse(paused.schedule.enabled)

        let detail = try await client.getSchedule(id: id)
        XCTAssertEqual(detail.schedule.id, id)
        XCTAssertEqual(detail.runs, [])

        let deleted = try await client.deleteSchedule(id: id)
        XCTAssertTrue(deleted.deleted)
        let afterDelete = try await client.listSchedules()
        XCTAssertTrue(afterDelete.schedules.isEmpty)
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
