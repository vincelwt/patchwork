import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

final class ScheduleValidationTests: XCTestCase {
    private func entry(
        name: String = "Morning triage",
        prompt: String = "Summarise overnight CI",
        target: ScheduleEntry.Target = .existingThread(threadID: "t1"),
        trigger: ScheduleEntry.Trigger = .interval(everySeconds: 3_600)
    ) -> ScheduleEntry {
        ScheduleEntry(name: name, target: target, prompt: prompt, trigger: trigger)
    }

    func testAnAutomationThatCouldNeverFireCannotBeSaved() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ScheduleValidation.problem(with: entry(), now: now))
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(name: "  "), now: now))
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(prompt: ""), now: now))
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(target: .existingThread(threadID: "")), now: now))
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(target: .newThread(cwd: "", namePattern: nil)), now: now))
        // A "once" trigger in the past would never run.
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(trigger: .once(at: now.addingTimeInterval(-60))), now: now))
        XCTAssertNil(ScheduleValidation.problem(with: entry(trigger: .once(at: now.addingTimeInterval(60))), now: now))
        // Sub-minute repeats would hammer the provider.
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(trigger: .interval(everySeconds: 5)), now: now))
        XCTAssertNotNil(ScheduleValidation.problem(with: entry(trigger: .heartbeat(everySeconds: 5)), now: now))
    }

    func testCronShapeIsCheckedBeforeItReachesTheDaemon() {
        XCTAssertNil(CronExpressionCheck.problem(with: "0 9 * * 1-5"))
        XCTAssertNil(CronExpressionCheck.problem(with: "*/15 * * * *"))
        XCTAssertNotNil(CronExpressionCheck.problem(with: "0 9 * *"))
        XCTAssertNotNil(CronExpressionCheck.problem(with: "0 9 * * 1-5 extra"))
        XCTAssertNotNil(CronExpressionCheck.problem(with: "@daily"))
        XCTAssertNotNil(CronExpressionCheck.problem(with: ""))
    }

    func testTriggerSummariesReadLikeSentences() {
        XCTAssertEqual(ScheduleEntry.Trigger.interval(everySeconds: 3_600).summary, "Every 1h 0m")
        XCTAssertEqual(ScheduleEntry.Trigger.heartbeat(everySeconds: 900).summary, "Every 15m 0s when idle")
        XCTAssertEqual(ScheduleEntry.Trigger.cron(expression: "0 9 * * 1", timeZone: nil).summary, "Cron · 0 9 * * 1")
    }

    func testRoundTripsThroughJSONSoTheDaemonAndAppAgree() throws {
        let original = entry(trigger: .cron(expression: "0 9 * * 1-5", timeZone: "Europe/Paris"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScheduleEntry.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

@MainActor
final class SchedulesModelTests: XCTestCase {
    func testListLoadsSavesTogglesAndDeletes() async throws {
        let service = InMemoryScheduleService()
        let model = SchedulesModel(service: service)
        await model.reload()
        XCTAssertTrue(model.entries.isEmpty)

        let entry = ScheduleEntry(
            name: "Nightly",
            target: .existingThread(threadID: "t1"),
            prompt: "check CI",
            trigger: .interval(everySeconds: 3_600)
        )
        await model.save(entry)
        XCTAssertEqual(model.entries.map(\.name), ["Nightly"])

        await model.setPaused(entry, paused: true)
        XCTAssertEqual(model.entries.first?.enabled, false)

        await model.delete(entry)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.error)
    }

    func testAMissingBackgroundServiceIsReportedInsteadOfSilentlyEmpty() async {
        let service = InMemoryScheduleService()
        service.failure = ScheduleServiceError.daemonUnavailable
        let model = SchedulesModel(service: service)
        await model.reload()
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.entries.isEmpty)
    }
}

@MainActor
final class RunHistoryModelTests: XCTestCase {
    private func run(
        _ id: String,
        schedule: String? = "a",
        started: TimeInterval,
        finished: TimeInterval? = nil,
        status: RunStatus = .ok,
        error: String? = nil,
        summary: String? = nil
    ) -> Run {
        Run(
            id: id,
            scheduleId: schedule,
            trigger: .schedule,
            startedAt: Date(timeIntervalSince1970: started),
            finishedAt: finished.map { Date(timeIntervalSince1970: $0) },
            status: status,
            error: error,
            summary: summary
        )
    }

    func testHistoryIsNewestFirstAndOnlyForTheAutomationThatWasOpened() async {
        let service = InMemoryScheduleService(runs: [
            run("a-old", started: 100),
            run("b-new", schedule: "b", started: 900),
            run("a-new", started: 500),
            run("orphan", schedule: nil, started: 800)
        ])
        let model = RunHistoryModel(service: service, scheduleID: "a")
        await model.reload()
        XCTAssertEqual(model.runs.map(\.id), ["a-new", "a-old"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testHistoryStaysBoundedToWhatTheAPIRetains() async {
        let service = InMemoryScheduleService(
            runs: (0..<80).map { run("r\($0)", started: TimeInterval($0)) }
        )
        let model = RunHistoryModel(service: service, scheduleID: "a")
        await model.reload()
        XCTAssertEqual(model.runs.count, PiTheme.runHistoryLimit)
        XCTAssertEqual(model.runs.first?.id, "r79", "The bound keeps the newest runs, not the oldest")
    }

    func testAFailedLoadIsReportedInsteadOfAnEmptyHistory() async {
        let service = InMemoryScheduleService(runs: [run("a1", started: 1)])
        service.failure = ScheduleServiceError.daemonUnavailable
        let model = RunHistoryModel(service: service, scheduleID: "a")
        await model.reload()
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.runs.isEmpty)
    }

    func testARunRowSaysWhatHappenedIncludingStatusesThisBuildHasNeverHeardOf() {
        XCTAssertEqual(run("1", started: 0, status: .ok).statusLabel, "Succeeded")
        XCTAssertEqual(run("1", started: 0, status: .timeout).statusLabel, "Timed out")
        // A newer daemon's status is shown, not swallowed.
        XCTAssertEqual(run("1", started: 0, status: .other("quarantined")).statusLabel, "Quarantined")
        XCTAssertEqual(run("1", started: 0, status: .other("")).statusLabel, "Unknown")

        // Duration only once a run has actually finished.
        XCTAssertNil(run("1", started: 0).durationLabel)
        XCTAssertEqual(run("1", started: 0, finished: 75).durationLabel, "1m 15s")

        // The error is the headline when there is one; otherwise the summary.
        let failed = run("1", started: 0, status: .failed, error: "  provider timeout ", summary: "ignored")
        XCTAssertEqual(failed.detailText, "provider timeout")
        XCTAssertTrue(failed.detailIsError)
        let fine = run("1", started: 0, summary: "3 failures triaged")
        XCTAssertEqual(fine.detailText, "3 failures triaged")
        XCTAssertFalse(fine.detailIsError)
        XCTAssertNil(run("1", started: 0, error: "   ", summary: nil).detailText)
        // Nothing unbounded reaches the sheet.
        XCTAssertEqual(
            run("1", started: 0, summary: String(repeating: "x", count: 5_000)).detailText?.count,
            PiTheme.sessionPreviewLimit
        )
    }
}

/// Automations is a detail page keyed off `schedulesPresented`, deliberately not an `AppRoute`
/// case — so the page must be left by ordinary navigation, and leaving it must not disturb the
/// route (or the draft parked against it).
@MainActor
final class AutomationsNavigationTests: XCTestCase {
    private struct QuietGitService: GitStatusProviding {
        func snapshot(for directory: URL) async -> GitSnapshot { .none }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiAutomationsNav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOpeningNewChatOrSelectingASessionLeavesTheAutomationsPage() throws {
        let file = directory.appendingPathComponent("thread.jsonl")
        try Data("{\"type\":\"session\"}\n".utf8).write(to: file)
        let store = AppStore(
            gitService: QuietGitService(),
            persistence: AppPersistence(baseURL: directory),
            activityMonitor: SessionActivityMonitor(isActiveOverride: false)
        )
        var session = SessionSummary(
            id: "thread", fileURL: file, cwd: directory, createdAt: Date(), modifiedAt: Date(),
            name: "thread", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        store.sessions = [session]

        store.schedulesPresented = true
        store.selectSession(session)
        XCTAssertFalse(store.schedulesPresented, "Selecting a conversation leaves the Automations page")
        XCTAssertEqual(store.route, .session(file.standardizedFileURL.path))

        store.schedulesPresented = true
        XCTAssertEqual(store.route, .session(file.standardizedFileURL.path), "Visiting Automations never changes the route")

        store.openNewChat()
        XCTAssertFalse(store.schedulesPresented, "New chat leaves the Automations page")
        XCTAssertEqual(store.route, .newChat)
    }
}

/// The sidebar's clock: which conversations count as "has an automation".
@MainActor
final class ScheduledThreadStoreTests: XCTestCase {
    private struct QuietGitService: GitStatusProviding {
        func snapshot(for directory: URL) async -> GitSnapshot { .none }
    }

    private var directory: URL!
    private var store: AppStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiScheduledThreads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AppStore(
            gitService: QuietGitService(),
            persistence: AppPersistence(baseURL: directory),
            activityMonitor: SessionActivityMonitor(isActiveOverride: false)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ name: String, target: ScheduleEntry.Target, enabled: Bool = true) -> ScheduleEntry {
        ScheduleEntry(name: name, enabled: enabled, target: target, prompt: "p", trigger: .interval(everySeconds: 3_600))
    }

    func testOnlyExistingThreadTargetsMarkAConversationAndPausedStillCounts() {
        store.updateScheduledThreads(from: [
            entry("live", target: .existingThread(threadID: "t1")),
            entry("paused", target: .existingThread(threadID: "t2"), enabled: false),
            entry("fresh", target: .newThread(cwd: "/tmp/project", namePattern: nil)),
            // The degraded target an unknown daemon kind decodes to must not mark every row.
            entry("unknown", target: .existingThread(threadID: ""))
        ])
        XCTAssertEqual(store.scheduledThreadIDs, ["t1", "t2"])
    }

    func testTheRetainedSetStaysBounded() {
        store.updateScheduledThreads(from: (0..<600).map { entry("s\($0)", target: .existingThread(threadID: "t\($0)")) })
        XCTAssertEqual(store.scheduledThreadIDs.count, 500)
    }

    func testARefreshMarksTargetedThreadsAndADaemonOutageKeepsTheLastKnownSet() async {
        let service = InMemoryScheduleService()
        store.cachedScheduleService = service
        _ = try? await service.save(entry("Nightly", target: .existingThread(threadID: "t1")))

        let loaded = await store.refreshScheduledThreads()
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.scheduledThreadIDs, ["t1"])

        service.failure = ScheduleServiceError.daemonUnavailable
        let retried = await store.refreshScheduledThreads()
        XCTAssertFalse(retried, "A failed load reports itself, so launch can try once more")
        XCTAssertEqual(store.scheduledThreadIDs, ["t1"], "A transient outage must not erase the clocks already on screen")
    }
}

final class ScheduleWireBridgeTests: XCTestCase {
    func testEveryTriggerAndTargetSurvivesTheRoundTripToTheDaemon() {
        let cases: [ScheduleEntry.Trigger] = [
            .once(at: Date(timeIntervalSince1970: 2_000_000)),
            .interval(everySeconds: 900),
            .cron(expression: "0 9 * * 1-5", timeZone: "Europe/Paris"),
            .heartbeat(everySeconds: 600)
        ]
        for trigger in cases {
            XCTAssertEqual(ScheduleEntry.Trigger(wire: trigger.wire), trigger)
        }

        let targets: [ScheduleEntry.Target] = [
            .existingThread(threadID: "t1"),
            .newThread(cwd: "/Users/x/code", namePattern: "Triage {date}")
        ]
        for target in targets {
            XCTAssertEqual(ScheduleEntry.Target(wire: target.wire), target)
        }
    }

    func testAnUnknownTriggerKindDegradesInsteadOfCrashing() {
        // A newer daemon may describe a trigger this build has never heard of.
        XCTAssertEqual(ScheduleEntry.Trigger(wire: .other(kind: "lunar")), .interval(everySeconds: 3_600))
        XCTAssertEqual(ScheduleEntry.Target(wire: .other(kind: "workspace")), .existingThread(threadID: ""))
        // And an empty target is exactly what the editor refuses to save.
        let entry = ScheduleEntry(
            name: "x",
            target: ScheduleEntry.Target(wire: .other(kind: "workspace")),
            prompt: "p",
            trigger: .interval(everySeconds: 3_600)
        )
        XCTAssertNotNil(ScheduleValidation.problem(with: entry))
    }
}
