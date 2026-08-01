import XCTest
import PatchworkKit
@testable import PatchworkDaemon

final class ScheduleEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed, deterministic "now"

    private func schedule(
        id: String = "sch_1",
        enabled: Bool = true,
        threadID: String? = "thread-1",
        trigger: ScheduleTrigger,
        skipIfRunning: Bool = true,
        catchUpMissed: Bool = false,
        quietHours: QuietHours? = nil,
        lastRunAt: Date? = nil,
        nextRunAt: Date?
    ) -> Schedule {
        Schedule(
            id: id, name: "test", enabled: enabled,
            target: threadID.map { ScheduleTarget.existingThread(threadId: $0) } ?? .newThread(cwd: "/tmp", namePattern: nil),
            prompt: "do the thing", mode: nil, trigger: trigger,
            policy: SchedulePolicy(skipIfRunning: skipIfRunning, catchUpMissed: catchUpMissed, timeoutSeconds: nil, quietHours: quietHours),
            createdAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-86_400),
            lastRunAt: lastRunAt, lastStatus: nil, nextRunAt: nextRunAt
        )
    }

    // MARK: - Basic gating

    func testDisabledScheduleNeverFiresEvenWhenOverdue() {
        let sched = schedule(enabled: false, trigger: .interval(everySeconds: 60, startAt: nil), nextRunAt: now.addingTimeInterval(-10))
        XCTAssertNil(ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }))
    }

    func testNotYetDueProducesNoDecisionWhenNextRunAtAlreadyKnown() {
        let sched = schedule(trigger: .interval(everySeconds: 60, startAt: nil), nextRunAt: now.addingTimeInterval(30))
        XCTAssertNil(ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }))
    }

    func testNextRunAtIsComputedOnceWhenNeverSet() {
        let sched = schedule(trigger: .interval(everySeconds: 60, startAt: now.addingTimeInterval(30)), nextRunAt: nil)
        guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }) else {
            return XCTFail("expected a decision")
        }
        // Comparing an `Action?` against a bare `.none` is ambiguous (it reads as "no decision",
        // not "the .none case"); unwrapping first makes the comparison unambiguous.
        XCTAssertEqual(decision.action, .none)
        XCTAssertEqual(decision.updatedSchedule.nextRunAt, now.addingTimeInterval(30))
    }

    // MARK: - Firing

    func testDueAndIdleFires() {
        let sched = schedule(trigger: .interval(everySeconds: 3_600, startAt: nil), nextRunAt: now.addingTimeInterval(-5))
        guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }) else {
            return XCTFail("expected a decision")
        }
        guard case let .fire(target, prompt, _) = decision.action else { return XCTFail("expected .fire, got \(decision.action)") }
        XCTAssertEqual(target.existingThreadID, "thread-1")
        XCTAssertEqual(prompt, "do the thing")
        XCTAssertEqual(decision.updatedSchedule.lastRunAt, now.addingTimeInterval(-5), "the grid advances from `due`, not `now`")
        XCTAssertGreaterThan(decision.updatedSchedule.nextRunAt!, now)
        XCTAssertNil(decision.updatedSchedule.lastStatus, "cleared: the outcome is not known until the run finishes")
    }

    func testDueAndBusyWithSkipIfRunningRecordsASkip() {
        let sched = schedule(trigger: .interval(everySeconds: 3_600, startAt: nil), skipIfRunning: true, nextRunAt: now.addingTimeInterval(-5))
        guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { $0 == "thread-1" }) else {
            return XCTFail("expected a decision")
        }
        guard case .skip = decision.action else { return XCTFail("expected .skip, got \(decision.action)") }
        XCTAssertEqual(decision.updatedSchedule.lastStatus, .skipped)
        XCTAssertNotNil(decision.updatedSchedule.nextRunAt)
    }

    func testDueAndBusyWithoutSkipIfRunningStillFires() {
        // The queue's own per-thread exclusivity prevents stacking; the schedule itself still
        // considers this occurrence "fired" (it queues rather than being dropped).
        let sched = schedule(trigger: .interval(everySeconds: 3_600, startAt: nil), skipIfRunning: false, nextRunAt: now.addingTimeInterval(-5))
        guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { $0 == "thread-1" }) else {
            return XCTFail("expected a decision")
        }
        guard case .fire = decision.action else { return XCTFail("expected .fire, got \(decision.action)") }
    }

    // MARK: - Heartbeat

    func testHeartbeatWhileBusyIsSilentAndNeverRecorded() {
        let sched = schedule(trigger: .heartbeat(everySeconds: 900), nextRunAt: now.addingTimeInterval(-1))
        guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { $0 == "thread-1" }) else {
            return XCTFail("expected a decision")
        }
        XCTAssertEqual(decision.action, .none)
        // Silence also means: no lastStatus is ever written for a busy heartbeat tick.
        XCTAssertNil(decision.updatedSchedule.lastStatus)
        XCTAssertGreaterThan(decision.updatedSchedule.nextRunAt!, now)
    }

    func testHeartbeatWhileIdleFires() {
        let sched = schedule(trigger: .heartbeat(everySeconds: 900), nextRunAt: now.addingTimeInterval(-1))
        let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false })
        guard case .fire = decision?.action else { return XCTFail("expected .fire") }
    }

    // MARK: - Missed occurrences / catch-up

    func testEveryMissedIntervalCatchesUpOnceRegardlessOfLegacyPolicy() {
        for legacyCatchUpValue in [false, true] {
            let due = now.addingTimeInterval(-3_600)
            let sched = schedule(
                trigger: .interval(everySeconds: 60, startAt: nil),
                catchUpMissed: legacyCatchUpValue, nextRunAt: due
            )
            guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }) else {
                return XCTFail("expected a decision")
            }
            guard case .fire = decision.action else { return XCTFail("expected .fire") }
            XCTAssertEqual(decision.updatedSchedule.lastRunAt, due)
            XCTAssertGreaterThan(decision.updatedSchedule.nextRunAt!, now, "missed periods coalesce instead of replaying")
        }
    }

    func testOrdinaryPollJitterStillFires() {
        let sched = schedule(trigger: .interval(everySeconds: 60, startAt: nil), nextRunAt: now.addingTimeInterval(-10))
        let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false })
        guard case .fire = decision?.action else { return XCTFail("expected .fire") }
    }

    // MARK: - Quiet hours

    func testQuietHoursDefersFiringUntilTheWindowEnds() {
        let quietHours = QuietHours(from: "00:00", to: "23:59", timeZone: "UTC") // effectively "always quiet" for this fixed `now`
        let sched = schedule(trigger: .interval(everySeconds: 60, startAt: nil), quietHours: quietHours, nextRunAt: now.addingTimeInterval(-5))
        guard let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }) else {
            return XCTFail("expected a decision")
        }
        XCTAssertEqual(decision.action, .none)
        XCTAssertNil(decision.updatedSchedule.lastRunAt)
        XCTAssertNotNil(decision.updatedSchedule.nextRunAt)
    }

    func testQuietHoursDoesNotSuppressHeartbeatTriggers() {
        // Quiet hours only make sense for triggers that place a human's overnight prompt; a
        // heartbeat's own busy/idle gating already prevents disturbing anyone.
        let quietHours = QuietHours(from: "00:00", to: "23:59", timeZone: "UTC")
        let sched = schedule(trigger: .heartbeat(everySeconds: 900), quietHours: quietHours, nextRunAt: now.addingTimeInterval(-5))
        let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false })
        guard case .fire = decision?.action else { return XCTFail("expected .fire") }
    }

    // MARK: - Once

    func testOnceFiresExactlyOnce() {
        let sched = schedule(trigger: .once(at: now.addingTimeInterval(-5)), nextRunAt: now.addingTimeInterval(-5))
        guard let first = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }) else {
            return XCTFail("expected a decision")
        }
        guard case .fire = first.action else { return XCTFail("expected .fire") }
        XCTAssertNil(first.updatedSchedule.nextRunAt, "a `once` trigger has nothing left to schedule")

        // Evaluating the *updated* schedule again must never fire a second time.
        let second = ScheduleEngine.evaluate(schedule: first.updatedSchedule, now: now.addingTimeInterval(3_600), isThreadBusy: { _ in false })
        XCTAssertNil(second)
    }

    // MARK: - Cron integration (not just TriggerEngine in isolation)

    func testMissedCronCoalescesToOneRunAndTheNextFutureBoundary() {
        let sched = schedule(
            trigger: .cron(expression: "*/5 * * * *", timeZone: "UTC"),
            nextRunAt: now.addingTimeInterval(-86_400)
        )
        let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false })
        guard case .fire = decision?.action,
              let next = decision?.updatedSchedule.nextRunAt else { return XCTFail("expected one catch-up run") }
        XCTAssertGreaterThan(next, now)
    }

    func testCronTriggerIntegratesThroughTheFullEngine() {
        let expr = "0 9 * * *" // daily at 09:00 UTC
        let sched = schedule(trigger: .cron(expression: expr, timeZone: "UTC"), nextRunAt: nil)
        let decision = ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false })
        // Not necessarily due yet (depends on the fixture's `now`), but nextRunAt must always be
        // computed and always land at a 09:00 UTC boundary.
        let computedNext = decision?.updatedSchedule.nextRunAt ?? sched.nextRunAt
        XCTAssertNotNil(computedNext)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.hour, from: computedNext!), 9)
        XCTAssertEqual(calendar.component(.minute, from: computedNext!), 0)
    }

    func testUnparseableTriggerKindNeverFires() {
        let sched = schedule(trigger: .other(kind: "not_a_real_kind"), nextRunAt: now.addingTimeInterval(-5))
        XCTAssertNil(ScheduleEngine.evaluate(schedule: sched, now: now, isThreadBusy: { _ in false }))
    }
}

final class FileRunStateFallbackTests: XCTestCase {
    private func entry(role: String, stopReason: String? = nil) -> PiJSONValue {
        var message: [String: PiJSONValue] = ["role": .string(role)]
        if let stopReason { message["stopReason"] = .string(stopReason) }
        return .object(["type": .string("message"), "message": .object(message)])
    }

    func testTheDaemonAndTheWindowClassifyAPreHeartbeatSessionIdentically() {
        // Work just handed to Pi, written moments ago: running.
        XCTAssertTrue(FileRunStateFallback.isRunning(lastEntry: entry(role: "toolResult"), age: 2))
        XCTAssertTrue(FileRunStateFallback.isRunning(lastEntry: entry(role: "assistant", stopReason: "toolUse"), age: 2))
        // The same entry, stalled: whatever wrote it is gone.
        XCTAssertFalse(FileRunStateFallback.isRunning(lastEntry: entry(role: "toolResult"), age: 40))
        // A terminal stop reason wins even for a write from a moment ago.
        XCTAssertFalse(FileRunStateFallback.isRunning(lastEntry: entry(role: "assistant", stopReason: "stop"), age: 1))
        XCTAssertFalse(FileRunStateFallback.isRunning(lastEntry: entry(role: "assistant", stopReason: "aborted"), age: 1))
        // Anything genuinely old is idle regardless.
        XCTAssertFalse(FileRunStateFallback.isRunning(lastEntry: entry(role: "user"), age: 600))
    }
}
