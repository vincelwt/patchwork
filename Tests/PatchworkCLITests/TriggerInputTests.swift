import XCTest
@testable import PatchworkCLI

final class TriggerInputTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testAtProducesOnceTrigger() throws {
        let trigger = try resolveTrigger(TriggerFlags(at: "2026-07-27T09:00:00Z", every: nil, cron: nil, heartbeat: nil, timezone: nil, startAt: nil), localTimeZone: utc)
        guard case let .once(at) = trigger else { return XCTFail("expected .once") }
        XCTAssertEqual(FlexibleDate.iso8601(at), "2026-07-27T09:00:00Z")
        XCTAssertEqual(trigger.wire.kind, "once")
        XCTAssertEqual(trigger.wire.at, "2026-07-27T09:00:00Z")
    }

    func testEveryProducesIntervalTrigger() throws {
        let trigger = try resolveTrigger(TriggerFlags(at: nil, every: "15m", cron: nil, heartbeat: nil, timezone: nil, startAt: nil), localTimeZone: utc)
        guard case let .interval(everySeconds, startAt) = trigger else { return XCTFail("expected .interval") }
        XCTAssertEqual(everySeconds, 900)
        XCTAssertNil(startAt)
        XCTAssertEqual(trigger.wire.everySeconds, 900)
    }

    func testEveryWithStartAt() throws {
        let trigger = try resolveTrigger(TriggerFlags(at: nil, every: "1h", cron: nil, heartbeat: nil, timezone: nil, startAt: "2026-07-27T09:00:00Z"), localTimeZone: utc)
        guard case let .interval(_, startAt) = trigger else { return XCTFail("expected .interval") }
        XCTAssertEqual(startAt.map(FlexibleDate.iso8601), "2026-07-27T09:00:00Z")
    }

    func testCronProducesCronTriggerWithDefaultLocalZone() throws {
        let trigger = try resolveTrigger(TriggerFlags(at: nil, every: nil, cron: "0 9 * * 1-5", heartbeat: nil, timezone: nil, startAt: nil), localTimeZone: utc)
        guard case let .cron(expression, timeZone) = trigger else { return XCTFail("expected .cron") }
        XCTAssertEqual(expression, "0 9 * * 1-5")
        XCTAssertEqual(timeZone, utc.identifier) // Foundation may canonicalize "UTC" to "GMT"
    }

    func testCronWithExplicitTimezone() throws {
        let trigger = try resolveTrigger(TriggerFlags(at: nil, every: nil, cron: "0 9 * * 1-5", heartbeat: nil, timezone: "Europe/Paris", startAt: nil), localTimeZone: utc)
        guard case let .cron(_, timeZone) = trigger else { return XCTFail("expected .cron") }
        XCTAssertEqual(timeZone, "Europe/Paris")
    }

    func testHeartbeatProducesHeartbeatTrigger() throws {
        let trigger = try resolveTrigger(TriggerFlags(at: nil, every: nil, cron: nil, heartbeat: "15m", timezone: nil, startAt: nil), localTimeZone: utc)
        guard case let .heartbeat(everySeconds) = trigger else { return XCTFail("expected .heartbeat") }
        XCTAssertEqual(everySeconds, 900)
        XCTAssertEqual(trigger.wire.kind, "heartbeat")
    }

    func testNoTriggerFlagIsRejected() {
        XCTAssertThrowsError(try resolveTrigger(TriggerFlags(at: nil, every: nil, cron: nil, heartbeat: nil, timezone: nil, startAt: nil))) { error in
            guard case UsageError.custom = error else { return XCTFail("expected .custom, got \(error)") }
        }
    }

    func testTwoTriggerFlagsAreRejectedAsAmbiguous() {
        XCTAssertThrowsError(try resolveTrigger(TriggerFlags(at: "2026-07-27T09:00:00Z", every: "15m", cron: nil, heartbeat: nil, timezone: nil, startAt: nil))) { error in
            guard case let UsageError.conflictingFlags(flags) = error else { return XCTFail("expected .conflictingFlags, got \(error)") }
            XCTAssertEqual(Set(flags), Set(["--at", "--every"]))
        }
    }

    func testAllFourTriggerFlagsAreRejectedAsAmbiguous() {
        XCTAssertThrowsError(try resolveTrigger(TriggerFlags(at: "2026-07-27T09:00:00Z", every: "15m", cron: "0 9 * * 1-5", heartbeat: "15m", timezone: nil, startAt: nil)))
    }

    func testInvalidCronPropagatesAsUsageError() {
        XCTAssertThrowsError(try resolveTrigger(TriggerFlags(at: nil, every: nil, cron: "not a cron", heartbeat: nil, timezone: nil, startAt: nil)))
    }

    func testInvalidDurationPropagatesAsUsageError() {
        XCTAssertThrowsError(try resolveTrigger(TriggerFlags(at: nil, every: "soon", cron: nil, heartbeat: nil, timezone: nil, startAt: nil)))
    }
}
