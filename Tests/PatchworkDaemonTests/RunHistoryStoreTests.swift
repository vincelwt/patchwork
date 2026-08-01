import XCTest
import PatchworkKit
@testable import PatchworkDaemon

final class RunHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func run(id: String, status: RunStatus, threadId: String? = "t1", scheduleId: String? = nil, startedAt: Date = Date()) -> Run {
        Run(id: id, scheduleId: scheduleId, threadId: threadId, trigger: .manual, startedAt: startedAt, finishedAt: status == .running ? nil : startedAt.addingTimeInterval(1), status: status)
    }

    func testRecordThenGetRoundTrips() async {
        let store = RunHistoryStore(fileURL: directory.appendingPathComponent("runs.jsonl"), logger: TestSupport.logger(in: directory))
        await store.record(run(id: "run_1", status: .ok))
        let fetched = await store.get(id: "run_1")
        XCTAssertEqual(fetched?.status, .ok)
    }

    func testQueryFiltersByScheduleAndThreadAndRespectsLimit() async {
        let store = RunHistoryStore(fileURL: directory.appendingPathComponent("runs.jsonl"), logger: TestSupport.logger(in: directory))
        for index in 0..<5 {
            await store.record(run(id: "run_\(index)", status: .ok, threadId: "t-a", scheduleId: "sch_a"))
        }
        await store.record(run(id: "run_other_thread", status: .ok, threadId: "t-b", scheduleId: "sch_a"))
        await store.record(run(id: "run_other_schedule", status: .ok, threadId: "t-a", scheduleId: "sch_b"))

        // 5 explicit t-a/sch_a runs, plus "run_other_schedule" which also targets t-a.
        let byThread = await store.query(scheduleId: nil, threadId: "t-a", limit: 50)
        XCTAssertEqual(byThread.count, 6)
        let bySchedule = await store.query(scheduleId: "sch_a", threadId: nil, limit: 50)
        XCTAssertEqual(bySchedule.count, 6)
        let limited = await store.query(scheduleId: nil, threadId: "t-a", limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    func testQueryReturnsMostRecentFirst() async {
        let store = RunHistoryStore(fileURL: directory.appendingPathComponent("runs.jsonl"), logger: TestSupport.logger(in: directory))
        await store.record(run(id: "first", status: .ok, startedAt: Date(timeIntervalSince1970: 1)))
        await store.record(run(id: "second", status: .ok, startedAt: Date(timeIntervalSince1970: 2)))
        await store.record(run(id: "third", status: .ok, startedAt: Date(timeIntervalSince1970: 3)))
        let runs = await store.query(scheduleId: nil, threadId: nil, limit: 50)
        XCTAssertEqual(runs.map(\.id), ["third", "second", "first"])
    }

    func testReloadDedupesToTheLastWrittenStatusForARun() async {
        // A run is recorded once as "running", then again as "ok" once it finishes \u2014 both are
        // appended to the file. After a restart, only the final status should be visible, never
        // a stale "running" ghost for a run that actually completed.
        let file = directory.appendingPathComponent("runs.jsonl")
        let logger = TestSupport.logger(in: directory)
        let store = RunHistoryStore(fileURL: file, logger: logger)
        await store.record(run(id: "run_1", status: .running))
        await store.record(run(id: "run_1", status: .ok))

        let reopened = RunHistoryStore(fileURL: file, logger: logger)
        let fetched = await reopened.get(id: "run_1")
        XCTAssertEqual(fetched?.status, .ok)
        let all = await reopened.query(scheduleId: nil, threadId: nil, limit: 50)
        XCTAssertEqual(all.count, 1, "must not resurrect the stale intermediate snapshot as a second entry")
    }

    func testMalformedLineIsSkippedOnReloadInsteadOfFailingEverything() async {
        let file = directory.appendingPathComponent("runs.jsonl")
        let logger = TestSupport.logger(in: directory)
        let store = RunHistoryStore(fileURL: file, logger: logger)
        await store.record(run(id: "good_1", status: .ok))
        var raw = try! Data(contentsOf: file)
        raw.append(Data("{not valid json at all\n".utf8))
        try! raw.write(to: file)

        let reopened = RunHistoryStore(fileURL: file, logger: logger)
        let fetched = await reopened.get(id: "good_1")
        XCTAssertEqual(fetched?.status, .ok)
    }

    func testRunningCountReflectsOnlyRunningStatus() async {
        let store = RunHistoryStore(fileURL: directory.appendingPathComponent("runs.jsonl"), logger: TestSupport.logger(in: directory))
        await store.record(run(id: "r1", status: .running))
        await store.record(run(id: "r2", status: .ok))
        await store.record(run(id: "r3", status: .running))
        let count = await store.runningCount()
        XCTAssertEqual(count, 2)
    }

    func testRestartInterruptsOnlyProcessLocalRuns() async {
        let store = RunHistoryStore(fileURL: directory.appendingPathComponent("runs.jsonl"), logger: TestSupport.logger(in: directory))
        let began = Date(timeIntervalSince1970: 10)
        await store.record(Run(
            id: "api", threadId: "t1", trigger: .api, startedAt: began,
            status: .running, promptStartedAt: began
        ))
        await store.record(Run(id: "manual", threadId: "t2", trigger: .manual, startedAt: began, status: .queued))
        await store.record(Run(
            id: "scheduled", scheduleId: "s1", threadId: "t3", trigger: .schedule,
            startedAt: began, status: .running
        ))

        await store.reconcileAfterHostRestart(now: Date(timeIntervalSince1970: 20))

        let api = await store.get(id: "api")
        let manual = await store.get(id: "manual")
        let scheduled = await store.get(id: "scheduled")
        XCTAssertEqual(api?.status, .interrupted)
        XCTAssertEqual(api?.error, "Patchwork closed after prompt delivery began; the run was not resent.")
        XCTAssertEqual(manual?.status, .interrupted)
        XCTAssertEqual(manual?.error, "Patchwork closed before this run started.")
        XCTAssertEqual(scheduled?.status, .running, "Scheduler owns durable occurrence recovery")
    }

    func testInMemoryViewIsBoundedByMaxInMemory() async {
        let store = RunHistoryStore(fileURL: directory.appendingPathComponent("runs.jsonl"), logger: TestSupport.logger(in: directory), maxInMemory: 3)
        for index in 0..<10 {
            await store.record(run(id: "run_\(index)", status: .ok, startedAt: Date(timeIntervalSince1970: Double(index))))
        }
        let all = await store.query(scheduleId: nil, threadId: nil, limit: 100)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.id), ["run_9", "run_8", "run_7"])
    }
}
