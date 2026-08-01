import XCTest
import PatchworkKit
@testable import PatchworkDaemon

final class ScheduleStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func sampleSchedule(id: String = "sch_1") -> Schedule {
        Schedule(
            id: id, name: "Nightly", enabled: true,
            target: .existingThread(threadId: "thread-1"), prompt: "check CI", mode: nil,
            trigger: .cron(expression: "0 9 * * 1-5", timeZone: "UTC"), policy: SchedulePolicy(),
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testUpsertPersistsAcrossReinitialization() async throws {
        let file = directory.appendingPathComponent("schedules.json")
        let logger = TestSupport.logger(in: directory)
        let store = ScheduleStore(fileURL: file, logger: logger)
        _ = try await store.upsert(sampleSchedule())

        let reopened = ScheduleStore(fileURL: file, logger: logger)
        let all = await reopened.all()
        XCTAssertEqual(all.map(\.id), ["sch_1"])
        XCTAssertEqual(all.first?.name, "Nightly")
    }

    func testRemoveDeletesAndPersists() async throws {
        let file = directory.appendingPathComponent("schedules.json")
        let logger = TestSupport.logger(in: directory)
        let store = ScheduleStore(fileURL: file, logger: logger)
        _ = try await store.upsert(sampleSchedule())
        let removed = try await store.remove(id: "sch_1")
        XCTAssertTrue(removed)

        let reopened = ScheduleStore(fileURL: file, logger: logger)
        let all = await reopened.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testRemovingUnknownIDReturnsFalse() async throws {
        let store = ScheduleStore(fileURL: directory.appendingPathComponent("schedules.json"), logger: TestSupport.logger(in: directory))
        let removed = try await store.remove(id: "does-not-exist")
        XCTAssertFalse(removed)
    }

    func testOneMalformedEntryIsQuarantinedWithoutLosingTheOthers() async throws {
        // Two valid schedules and one entry missing its required `trigger` field, written
        // directly as raw JSON \u2014 this is what a hand-edited or partially-written file looks
        // like, not something `ScheduleStore` itself would ever produce.
        let file = directory.appendingPathComponent("schedules.json")
        let raw = """
        [
          {"id":"sch_a","name":"A","enabled":true,"target":{"kind":"existingThread","threadId":"t1"},"prompt":"p","trigger":{"kind":"once","at":"2026-01-01T00:00:00.000Z"},"policy":{},"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"},
          {"id":"sch_bad","name":"Bad","enabled":true,"target":{"kind":"existingThread","threadId":"t2"},"prompt":"p","policy":{},"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"},
          {"id":"sch_c","name":"C","enabled":true,"target":{"kind":"existingThread","threadId":"t3"},"prompt":"p","trigger":{"kind":"heartbeat","everySeconds":900},"policy":{},"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}
        ]
        """
        try raw.write(to: file, atomically: true, encoding: .utf8)

        let logger = TestSupport.logger(in: directory)
        let store = ScheduleStore(fileURL: file, logger: logger)
        let all = await store.all()
        XCTAssertEqual(Set(all.map(\.id)), ["sch_a", "sch_c"], "the malformed entry must be skipped, not crash startup")
        let issues = await store.quarantineIssues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.code, "schedule_quarantined")
    }

    func testWholeFileCorruptionStartsEmptyWithOneIssueInsteadOfCrashing() async {
        let file = directory.appendingPathComponent("schedules.json")
        try? "{ this is not json at all".write(to: file, atomically: true, encoding: .utf8)

        let logger = TestSupport.logger(in: directory)
        let store = ScheduleStore(fileURL: file, logger: logger)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
        let issues = await store.quarantineIssues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.code, "schedules_file_corrupt")
    }

    func testMissingFileStartsEmptyWithNoIssues() async {
        let store = ScheduleStore(fileURL: directory.appendingPathComponent("does-not-exist.json"), logger: TestSupport.logger(in: directory))
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
        let issues = await store.quarantineIssues
        XCTAssertTrue(issues.isEmpty)
    }

    func testWrittenFilePermissionsAreOwnerOnly() async throws {
        let file = directory.appendingPathComponent("schedules.json")
        let store = ScheduleStore(fileURL: file, logger: TestSupport.logger(in: directory))
        _ = try await store.upsert(sampleSchedule())
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

final class WebAssetServingTests: XCTestCase {
    private func request(_ path: String, method: String = "GET", headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: headers, body: Data(), origin: .tcp)
    }

    func testTheShellIsServedAndTheAPIIsLeftToTheRouter() throws {
        let index = try XCTUnwrap(HTTPServer.webAssetResponse(for: request("/")))
        XCTAssertEqual(index.status, 200)
        XCTAssertTrue(index.headers["Content-Type"]?.contains("text/html") == true)
        XCTAssertFalse(index.body.isEmpty)

        // Client-side routes fall back to the shell, API paths never do.
        XCTAssertEqual(HTTPServer.webAssetResponse(for: request("/threads/abc"))?.status, 200)
        XCTAssertNil(HTTPServer.webAssetResponse(for: request("/v1/threads")))
        XCTAssertNil(HTTPServer.webAssetResponse(for: request("/v1/events")))
        XCTAssertNil(HTTPServer.webAssetResponse(for: request("/", method: "POST")))
    }

    func testAMatchingETagAnswers304WithoutABody() throws {
        let first = try XCTUnwrap(HTTPServer.webAssetResponse(for: request("/")))
        let etag = try XCTUnwrap(first.headers["ETag"])
        let second = try XCTUnwrap(HTTPServer.webAssetResponse(for: request("/", headers: ["if-none-match": etag])))
        XCTAssertEqual(second.status, 304)
        XCTAssertTrue(second.body.isEmpty)
    }
}
