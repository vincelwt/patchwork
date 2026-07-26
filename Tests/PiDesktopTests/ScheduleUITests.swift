import Foundation
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
