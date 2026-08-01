import Foundation
import PatchworkKit
import XCTest
@testable import Patchwork

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

    func testAgentRoundTripsAndRequestsStayScopedToNewConversations() {
        let now = Date()
        let wire = Schedule(
            id: "s1", name: "Claude automation", target: .newThread(
                cwd: "/tmp/project", namePattern: nil
            ), prompt: "work", trigger: .interval(everySeconds: 3_600, startAt: nil),
            agent: .claude, createdAt: now, updatedAt: now
        )
        let entry = ScheduleEntry(wire: wire)
        XCTAssertEqual(entry.agent, .claude)
        XCTAssertEqual(entry.createRequest.agent, .claude)
        XCTAssertEqual(entry.updateRequest.agent, .claude)

        var existing = entry
        existing.target = .existingThread(threadID: "thread-1")
        XCTAssertNil(existing.createRequest.agent)
        XCTAssertNil(existing.updateRequest.agent)
    }

    func testUpdateRequestCanClearAHiddenModeAndValidationRejectsNonPiMode() {
        var value = entry(target: .newThread(cwd: "/tmp/project", namePattern: nil))
        value.agent = .codex
        value.mode = "ultra"
        XCTAssertNotNil(ScheduleValidation.problem(with: value))

        value.mode = nil
        XCTAssertEqual(value.updateRequest.mode, "")
        XCTAssertNil(ScheduleValidation.problem(with: value))
    }
}

@MainActor
private final class MemoryScheduleIntentPersistence: ScheduleMutationIntentPersisting {
    var scheduleMutationIntents: [String: ScheduleMutationIntent] = [:]
    var failWrites = false
    private(set) var writeCount = 0

    func replaceScheduleMutationIntents(_ values: [String: ScheduleMutationIntent]) -> Bool {
        writeCount += 1
        guard !failWrites else { return false }
        scheduleMutationIntents = values
        return true
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
        _ = await model.save(entry, isNew: true)
        XCTAssertEqual(model.entries.map(\.name), ["Nightly"])

        await model.setPaused(entry, paused: true)
        XCTAssertEqual(model.entries.first?.enabled, false)

        await model.delete(entry)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.error)
    }

    func testInternalPullRequestWatchesNeverAppearAsAutomations() async {
        let service = InMemoryScheduleService(entries: [
            ScheduleEntry(
                id: "sch_req_pr_review_test", name: "Codex review acme/widgets#1",
                target: .existingThread(threadID: "t1"),
                prompt: "/patchwork-pr-review https://github.com/acme/widgets/pull/1 123",
                trigger: .heartbeat(everySeconds: 300)
            )
        ])
        let model = SchedulesModel(service: service)

        await model.reload()

        XCTAssertTrue(model.entries.isEmpty)
    }

    func testAMissingBackgroundServiceIsReportedInsteadOfSilentlyEmpty() async {
        let service = InMemoryScheduleService()
        service.failure = ScheduleServiceError.daemonUnavailable
        let model = SchedulesModel(service: service)
        await model.reload()
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testReloadUsesOneScheduleRequest() async {
        let service = InMemoryScheduleService()
        let model = SchedulesModel(service: service)

        await model.reload()

        XCTAssertEqual(service.loadCount, 1)
    }

    func testFailedCreationKeepsItsIDAndUnknownCreationRequiresListReview() async {
        let entry = ScheduleEntry(
            name: "Nightly", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let replacement = ScheduleEntry(
            name: "Replacement", target: .existingThread(threadID: "t2"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let service = InMemoryScheduleService()
        let model = SchedulesModel(service: service)

        service.failure = ScheduleServiceError.daemonUnavailable
        guard case .failed = await model.save(entry, isNew: true) else {
            return XCTFail("expected a retryable create failure")
        }
        model.beginNew(defaultEntry: replacement)
        XCTAssertEqual(model.editing?.entry.id, entry.id)

        service.failure = ScheduleServiceError.creationOutcomeUnknown
        guard case .needsReview = await model.save(entry, isNew: true) else {
            return XCTFail("expected an ambiguous create result")
        }
        XCTAssertTrue(model.creationNeedsReview)
        let attemptsBeforeBlockedRetry = service.savedIDs.count
        _ = await model.save(entry, isNew: true)
        XCTAssertEqual(service.savedIDs.count, attemptsBeforeBlockedRetry)
        model.editing = nil
        model.beginNew(defaultEntry: replacement)
        XCTAssertNil(model.editing)

        service.failure = nil
        let reviewed = await model.reviewCreationOutcome()
        XCTAssertTrue(reviewed)
        XCTAssertFalse(model.creationNeedsReview)
        model.beginNew(defaultEntry: replacement)
        XCTAssertEqual(model.editing?.entry.id, replacement.id)
    }

    func testCreationRecoveryIsDurableBeforeSendAndSurvivesRelaunch() async {
        let entry = ScheduleEntry(
            name: "Nightly", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let persistence = MemoryScheduleIntentPersistence()
        let service = InMemoryScheduleService()
        var observedIntent: ScheduleMutationIntent?
        service.saveHandler = { candidate, _ in
            observedIntent = persistence.scheduleMutationIntents[ScheduleMutationIntent.creationKey]
            throw ScheduleServiceError.daemonUnavailable
        }
        let first = SchedulesModel(service: service, persistence: persistence)

        guard case .failed = await first.save(entry, isNew: true) else {
            return XCTFail("expected a retryable create failure")
        }
        XCTAssertEqual(observedIntent?.phase, .dispatching)
        XCTAssertEqual(observedIntent?.clientID, entry.id)
        XCTAssertEqual(
            persistence.scheduleMutationIntents[ScheduleMutationIntent.creationKey]?.phase,
            .retryable
        )

        service.saveHandler = nil
        service.failure = nil
        let relaunched = SchedulesModel(service: service, persistence: persistence)
        guard case .saved = await relaunched.save(entry, isNew: true) else {
            return XCTFail("expected the retained create to replay")
        }
        XCTAssertEqual(service.savedIDs, [entry.id, entry.id])
        XCTAssertEqual(service.entries.map(\.id), [entry.id])
        XCTAssertNil(persistence.scheduleMutationIntents[ScheduleMutationIntent.creationKey])
    }

    func testScheduleRecoveryRefusesToExceedItsRunBound() {
        let now = Date()
        let intents = Dictionary(uniqueKeysWithValues: (0...ScheduleMutationIntent.maximumRunCount).map { index in
            let scheduleID = "schedule-\(index)"
            return (
                ScheduleMutationIntent.runKey(scheduleID),
                ScheduleMutationIntent(
                    kind: .manualRun, phase: .retryable, clientID: "run-\(index)",
                    scheduleID: scheduleID, creationDraft: nil,
                    startedAt: now.addingTimeInterval(TimeInterval(index))
                )
            )
        })

        XCTAssertFalse(ScheduleMutationIntent.isWithinNormalBounds(intents))
        XCTAssertEqual(
            ScheduleMutationIntent.boundedDecoded(intents).count,
            ScheduleMutationIntent.maximumRunCount
        )
    }

    func testRunNowSingleFlightsWhileAdmissionIsPending() async {
        let entry = ScheduleEntry(
            name: "Manual", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let service = InMemoryScheduleService(entries: [entry])
        var continuation: CheckedContinuation<Void, Never>?
        service.runHandler = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let model = SchedulesModel(service: service)

        let first = Task { await model.runNow(entry) }
        while service.runClientIDs.isEmpty { await Task.yield() }
        let second = Task { await model.runNow(entry) }
        await Task.yield()

        XCTAssertEqual(service.runClientIDs.count, 1)
        XCTAssertTrue(model.runningNowIDs.contains(entry.id))
        continuation?.resume()
        _ = await first.value
        _ = await second.value
        XCTAssertFalse(model.runningNowIDs.contains(entry.id))
    }

    func testRunNowReusesAnAmbiguousClientIDThenRotatesAfterSuccess() async {
        let entry = ScheduleEntry(
            name: "Manual", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let service = InMemoryScheduleService(entries: [entry])
        let model = SchedulesModel(service: service)

        service.failure = ScheduleServiceError.daemonUnavailable
        await model.runNow(entry)
        service.failure = nil
        await model.runNow(entry)
        await model.runNow(entry)

        XCTAssertEqual(service.runClientIDs.count, 3)
        XCTAssertEqual(service.runClientIDs[0], service.runClientIDs[1])
        XCTAssertNotEqual(service.runClientIDs[1], service.runClientIDs[2])
        XCTAssertFalse(model.runningNowIDs.contains(entry.id))
    }

    func testUnknownRunOutcomeRequiresHistoryReviewBeforeAnotherAttempt() async {
        let entry = ScheduleEntry(
            name: "Manual", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let service = InMemoryScheduleService(entries: [entry])
        service.failure = ScheduleServiceError.outcomeUnknown
        let model = SchedulesModel(service: service)

        await model.runNow(entry)
        XCTAssertTrue(model.runNeedsReviewIDs.contains(entry.id))
        let ambiguousID = service.runClientIDs.last

        await model.runNow(entry)
        XCTAssertEqual(service.runClientIDs.count, 1, "review-only state blocks another admission")

        model.reviewRunHistory(entry)
        XCTAssertTrue(model.runNeedsReviewIDs.contains(entry.id), "opening history is not authoritative review")
        XCTAssertEqual(model.history?.id, entry.id)

        XCTAssertTrue(model.acknowledgeRunHistory(entry))
        XCTAssertFalse(model.runNeedsReviewIDs.contains(entry.id))
        XCTAssertNil(model.error)

        service.failure = nil
        await model.runNow(entry)
        XCTAssertNotEqual(service.runClientIDs.last, ambiguousID)
    }

    func testExplicitDaemonUnknownRunCodeRequiresReview() {
        let mapped = DaemonScheduleService.surfacedRun(PatchworkClientError.badRequest(
            code: "schedule_run_outcome_unknown", message: "review runs"
        ))
        guard let error = mapped as? ScheduleServiceError,
              case .outcomeUnknown = error else {
            return XCTFail("expected the explicit daemon code to become review-only")
        }
    }

    func testRunIDConflictAlsoRequiresReview() {
        for source in [
            PatchworkClientError.badRequest(code: "run_id_conflict", message: "different work"),
            PatchworkClientError.server(status: 409, code: "run_id_conflict", message: "different work")
        ] {
            guard let mapped = DaemonScheduleService.surfacedRun(source) as? ScheduleServiceError,
                  case .outcomeUnknown = mapped else {
                return XCTFail("expected run_id_conflict to require review")
            }
        }
    }

    func testRecoveryIsDurableBeforeSendAndSurvivesRelaunch() async {
        let entry = ScheduleEntry(
            name: "Manual", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let persistence = MemoryScheduleIntentPersistence()
        let service = InMemoryScheduleService(entries: [entry])
        var observedIntent: ScheduleMutationIntent?
        service.runHandler = { _, _ in
            observedIntent = persistence.scheduleMutationIntents[
                ScheduleMutationIntent.runKey(entry.id)
            ]
            throw ScheduleServiceError.daemonUnavailable
        }
        let first = SchedulesModel(
            service: service, persistence: persistence,
            runClientIDFactory: { "desktop-run-stable" }
        )

        await first.runNow(entry)
        XCTAssertEqual(observedIntent?.phase, .dispatching)
        XCTAssertEqual(observedIntent?.clientID, "desktop-run-stable")
        XCTAssertEqual(
            persistence.scheduleMutationIntents[ScheduleMutationIntent.runKey(entry.id)]?.phase,
            .retryable
        )

        service.runHandler = nil
        service.failure = nil
        let relaunched = SchedulesModel(
            service: service, persistence: persistence,
            runClientIDFactory: { "must-not-be-used" }
        )
        await relaunched.runNow(entry)
        XCTAssertEqual(service.runClientIDs, ["desktop-run-stable", "desktop-run-stable"])
        XCTAssertNil(persistence.scheduleMutationIntents[ScheduleMutationIntent.runKey(entry.id)])
    }

    func testCrashDuringDispatchRestoresReviewOnlyState() async {
        let entry = ScheduleEntry(
            name: "Manual", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let persistence = MemoryScheduleIntentPersistence()
        let key = ScheduleMutationIntent.runKey(entry.id)
        persistence.scheduleMutationIntents[key] = ScheduleMutationIntent(
            kind: .manualRun, phase: .dispatching, clientID: "desktop-run-crashed",
            scheduleID: entry.id, creationDraft: nil, startedAt: Date()
        )
        let service = InMemoryScheduleService(entries: [entry])
        let model = SchedulesModel(service: service, persistence: persistence)

        XCTAssertTrue(model.runNeedsReviewIDs.contains(entry.id))
        XCTAssertEqual(persistence.scheduleMutationIntents[key]?.phase, .needsReview)
        await model.runNow(entry)
        XCTAssertTrue(service.runClientIDs.isEmpty)
        model.reviewRunHistory(entry)
        XCTAssertTrue(model.runNeedsReviewIDs.contains(entry.id))
    }

    func testPersistenceFailurePreventsAnyMutationRequest() async {
        let entry = ScheduleEntry(
            name: "Nightly", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let persistence = MemoryScheduleIntentPersistence()
        persistence.failWrites = true
        let service = InMemoryScheduleService(entries: [entry])
        let model = SchedulesModel(service: service, persistence: persistence)

        guard case .failed = await model.save(entry, isNew: true) else {
            return XCTFail("expected a local recovery write failure")
        }
        await model.runNow(entry)
        XCTAssertTrue(service.savedIDs.isEmpty)
        XCTAssertTrue(service.runClientIDs.isEmpty)
    }

    func testConcurrentSavesAndOutOfOrderReloadsPublishOnlyOneCurrentResult() async {
        let older = ScheduleEntry(
            id: "older", name: "Older", target: .existingThread(threadID: "t1"),
            prompt: "work", trigger: .interval(everySeconds: 3_600)
        )
        let newer = ScheduleEntry(
            id: "newer", name: "Newer", target: .existingThread(threadID: "t1"),
            prompt: "work", trigger: .interval(everySeconds: 3_600)
        )
        let service = InMemoryScheduleService()
        var loadContinuations: [CheckedContinuation<[ScheduleEntry], Error>] = []
        service.loadHandler = {
            try await withCheckedThrowingContinuation { loadContinuations.append($0) }
        }
        let model = SchedulesModel(service: service)
        let firstReload = Task { await model.reload() }
        while loadContinuations.count < 1 { await Task.yield() }
        let secondReload = Task { await model.reload() }
        while loadContinuations.count < 2 { await Task.yield() }
        loadContinuations[1].resume(returning: [newer])
        _ = await secondReload.value
        XCTAssertEqual(model.entries.map(\.id), ["newer"])
        XCTAssertTrue(model.isBusy)
        loadContinuations[0].resume(returning: [older])
        _ = await firstReload.value
        XCTAssertEqual(model.entries.map(\.id), ["newer"])
        XCTAssertFalse(model.isBusy)

        service.loadHandler = nil
        var saveContinuation: CheckedContinuation<ScheduleEntry, Error>?
        service.saveHandler = { entry, _ in
            try await withCheckedThrowingContinuation { saveContinuation = $0 }
        }
        let firstSave = Task { await model.save(newer, isNew: true) }
        while saveContinuation == nil { await Task.yield() }
        let secondSave = await model.save(newer, isNew: true)
        guard case .failed = secondSave else { return XCTFail("second save must be refused") }
        XCTAssertEqual(service.savedIDs.count, 1)
        saveContinuation?.resume(returning: newer)
        _ = await firstSave.value
    }

    func testAppPersistenceRoundTripsBoundedScheduleRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiScheduleRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = ScheduleEntry(
            name: "Nightly", target: .existingThread(threadID: "t1"), prompt: "work",
            trigger: .interval(everySeconds: 3_600)
        )
        let intent = ScheduleMutationIntent(
            kind: .creation, phase: .needsReview, clientID: entry.id,
            scheduleID: nil, creationDraft: entry, startedAt: Date()
        )
        let first = AppPersistence(baseURL: directory)
        XCTAssertTrue(first.replaceScheduleMutationIntents([ScheduleMutationIntent.creationKey: intent]))
        let reopened = AppPersistence(baseURL: directory)
        XCTAssertEqual(reopened.scheduleMutationIntents[ScheduleMutationIntent.creationKey], intent)
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
        XCTAssertEqual(model.runs.count, PatchworkTheme.runHistoryLimit)
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
        XCTAssertEqual(run("1", started: 0, status: .queued).statusLabel, "Queued")
        XCTAssertEqual(run("1", started: 0, status: .ok).statusLabel, "Succeeded")
        XCTAssertEqual(run("1", started: 0, status: .timeout).statusLabel, "Timed out")
        XCTAssertEqual(run("1", started: 0, status: .interrupted).statusLabel, "Interrupted")
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
            PatchworkTheme.sessionPreviewLimit
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

    private func entry(
        _ name: String,
        id: String = UUID().uuidString,
        target: ScheduleEntry.Target,
        enabled: Bool = true,
        prompt: String = "p"
    ) -> ScheduleEntry {
        ScheduleEntry(id: id, name: name, enabled: enabled, target: target, prompt: prompt, trigger: .interval(everySeconds: 3_600))
    }

    private func session(_ id: String) -> SessionSummary {
        var session = SessionSummary(
            id: id, fileURL: directory.appendingPathComponent("\(id).jsonl"), cwd: directory,
            createdAt: Date(), modifiedAt: Date(), name: id, preview: "",
            messageCount: 0, metrics: TokenMetrics()
        )
        session.prepareSearchKey()
        return session
    }

    func testOnlyExistingThreadTargetsMarkAConversationAndPausedStillCounts() {
        store.updateScheduledThreads(from: [
            entry("live", target: .existingThread(threadID: "t1")),
            entry("paused", target: .existingThread(threadID: "t2"), enabled: false),
            entry("fresh", target: .newThread(cwd: "/tmp/project", namePattern: nil)),
            // PR-review heartbeats belong to Open PRs or Done, never user-facing Automated.
            entry(
                "review", id: "sch_req_pr_review_test", target: .existingThread(threadID: "t3"),
                prompt: "/patchwork-pr-review https://github.com/acme/widgets/pull/1 123"
            ),
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
        _ = try? await service.save(
            entry("Nightly", target: .existingThread(threadID: "t1")), isNew: true
        )

        let loaded = await store.refreshScheduledThreads()
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.scheduledThreadIDs, ["t1"])

        service.failure = ScheduleServiceError.daemonUnavailable
        let retried = await store.refreshScheduledThreads()
        XCTAssertFalse(retried, "A failed load reports itself, so launch can try once more")
        XCTAssertEqual(store.scheduledThreadIDs, ["t1"], "A transient outage must not erase the clocks already on screen")
    }

    func testRefreshRemovesLegacyPullRequestSchedules() async throws {
        let review = entry(
            "review", id: "sch_req_pr_review_legacy", target: .existingThread(threadID: "t1"),
            prompt: "/patchwork-pr-review https://github.com/acme/widgets/pull/1 123"
        )
        let service = InMemoryScheduleService(entries: [
            review,
            entry("Nightly", target: .existingThread(threadID: "t2"))
        ])
        store.cachedScheduleService = service

        let loaded = await store.refreshScheduledThreads()

        XCTAssertTrue(loaded)
        XCTAssertEqual(service.entries.map(\.name), ["Nightly"])
        XCTAssertEqual(store.scheduledThreadIDs, ["t2"])
    }

    func testArchivingAThreadConfirmsThenDeletesAllLinkedAutomations() async throws {
        let service = InMemoryScheduleService(entries: [
            entry("Morning", target: .existingThread(threadID: "t1")),
            entry("Evening", target: .existingThread(threadID: "t1")),
            entry("Other", target: .existingThread(threadID: "t2"))
        ])
        store.cachedScheduleService = service
        store.sessions = [session("t1"), session("t2")]

        await store.requestArchive(store.sessions[0])
        let cancelled = try XCTUnwrap(store.archiveConfirmation)
        XCTAssertEqual(cancelled.automationCount, 2)
        XCTAssertFalse(store.sessions[0].isArchived)

        store.cancelArchiveConfirmation()
        XCTAssertEqual(service.entries.count, 3)
        XCTAssertFalse(store.sessions[0].isArchived)

        await store.requestArchive(store.sessions[0])
        let confirmed = try XCTUnwrap(store.archiveConfirmation)
        await store.confirmArchive(confirmed)

        XCTAssertTrue(store.sessions[0].isArchived)
        XCTAssertEqual(service.entries.map(\.name), ["Other"])
        XCTAssertEqual(store.scheduledThreadIDs, ["t2"])
    }

    func testArchiveStaysActiveWhenLinkedAutomationsCannotBeDeleted() async throws {
        let service = InMemoryScheduleService(entries: [
            entry("Morning", target: .existingThread(threadID: "t1"))
        ])
        store.cachedScheduleService = service
        store.sessions = [session("t1")]

        await store.requestArchive(store.sessions[0])
        let confirmation = try XCTUnwrap(store.archiveConfirmation)
        service.failure = ScheduleServiceError.daemonUnavailable
        await store.confirmArchive(confirmation)

        XCTAssertFalse(store.sessions[0].isArchived)
        XCTAssertEqual(service.entries.count, 1)
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
