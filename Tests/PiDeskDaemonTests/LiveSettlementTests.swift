import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// The settlement boundary, exercised deterministically: a fake runtime whose delivery can be
/// held open on demand, so "a steer is mid-flight when `agent_settled` arrives" is a controlled
/// state rather than a timing accident. Nothing here spawns `pi`.
final class GatedLiveRuntime: LiveRuntimeHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [(command: String, message: String)] = []
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    var delivered: [(command: String, message: String)] { lock.lock(); defer { lock.unlock() }; return _delivered }
    var result: LiveDelivery = .acknowledged
    /// When true, `deliver` blocks until `finishDelivery()` is called.
    var gated = false
    /// Simulates a write that fails only once the boundary has already been crossed.
    var throwsAfterGate = false

    func deliver(command: String, message: String) async throws -> LiveDelivery {
        lock.lock(); _delivered.append((command, message)); lock.unlock()
        if gated {
            started.signal()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { [release] in
                    release.wait()
                    continuation.resume()
                }
            }
        }
        if throwsAfterGate { throw RunnerError.ioFailure("Pi did not accept input within 15s.") }
        return result
    }

    /// Blocks until a gated delivery has actually entered `deliver`.
    func waitForDeliveryToStart(timeout: TimeInterval = 5) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func finishDelivery() { release.signal() }
}

final class LiveSettlementTests: XCTestCase {
    private let thread = "t1"
    private let run = "run_1"

    func testAnIdleRunClosesAdmissionAtItsFirstSettle() {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
        XCTAssertNil(registry.liveRunID(threadID: thread), "nothing may reach the session after this")
    }

    func testClosingAdmissionIsIdempotentAndIgnoresAnotherRunsBoundary() {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: "someone_else"), .closed)
        XCTAssertNotNil(registry.liveRunID(threadID: thread), "a stranger's settle must not close this run")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
    }

    // MARK: - What a delivery owes the run

    func testAMidTurnSteerOwesNoExtraTurnSoTheNextSettleEndsTheRun() async {
        // Pi folds a steer into the turn already running, so the next `agent_settled` *is* that
        // message's settle. Treating it as owing another turn would leave the executor waiting for
        // a turn that never starts, stalling to the deadline and recording success as a timeout.
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        let delivered = await registry.deliver(threadID: thread, command: "steer", message: "stop")
        XCTAssertEqual(delivered?.result, .acknowledged)

        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
        XCTAssertNil(registry.liveRunID(threadID: thread))
    }

    func testAnAcceptedFollowUpOwnsALaterTurnAndKeepsTheRunConsuming() async {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        _ = await registry.deliver(threadID: thread, command: "follow_up", message: "and also")

        // The settle of the turn that was already running. Stopping here would discard the
        // follow-up, which has not run yet.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
        XCTAssertNotNil(registry.liveRunID(threadID: thread), "admission reopens for the new turn")

        // The follow-up's own settle. Nothing is owed now.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
        XCTAssertNil(registry.liveRunID(threadID: thread))
    }

    func testEachAcceptedFollowUpOwnsExactlyOneTurn() async {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        _ = await registry.deliver(threadID: thread, command: "follow_up", message: "one")
        _ = await registry.deliver(threadID: thread, command: "follow_up", message: "two")

        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
    }

    func testAnUnacknowledgedFollowUpAlsoOwnsATurnBecauseItMayHaveApplied() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        runtime.result = .unacknowledged
        registry.register(threadID: thread, runID: run, handle: runtime)

        _ = await registry.deliver(threadID: thread, command: "follow_up", message: "and also")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
    }

    func testARejectedFollowUpOwesNothing() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        runtime.result = .rejected("nope")
        registry.register(threadID: thread, runID: run, handle: runtime)

        _ = await registry.deliver(threadID: thread, command: "follow_up", message: "x")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "it never ran")
    }

    // MARK: - The settlement boundary itself

    func testASettleDuringAnInFlightWriteWaitsAndRefusesLateCallers() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "stop") }
        XCTAssertTrue(runtime.waitForDeliveryToStart(), "the write is now genuinely mid-flight")

        // This is the race: the executor must not stop the session here.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .busy)

        // …and admission is already shut, so anyone arriving in this window queues a fresh run
        // instead of writing into a session that is about to be stopped.
        XCTAssertNil(registry.liveRunID(threadID: thread))
        let late = await registry.deliver(threadID: thread, command: "steer", message: "too late")
        XCTAssertNil(late)

        runtime.finishDelivery()
        let result = await delivery.value
        XCTAssertEqual(result?.result, .acknowledged)
        XCTAssertEqual(runtime.delivered.count, 1, "the late caller never wrote anything")
    }

    func testASteerThatCrossedTheBoundaryContinuesOnceBecauseItMayHaveMissedTheTurn() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "stop") }
        XCTAssertTrue(runtime.waitForDeliveryToStart())
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .busy)

        runtime.finishDelivery()
        _ = await delivery.value

        // It may have landed too late to join the settling turn, so the conservative reading is
        // one more turn — never a stop that would discard it.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "exactly once, not forever")
    }

    func testASteerThatCrossedTheBoundaryAndWasRejectedClosesImmediately() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        runtime.result = .rejected("nothing to steer")
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "stop") }
        XCTAssertTrue(runtime.waitForDeliveryToStart())
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .busy)

        runtime.finishDelivery()
        _ = await delivery.value
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "it never ran, so nothing is owed")
    }

    func testASteerThatCrossedTheBoundaryAndFailedToWriteClosesImmediately() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        runtime.throwsAfterGate = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "stop") }
        XCTAssertTrue(runtime.waitForDeliveryToStart())
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .busy)

        runtime.finishDelivery()
        let result = await delivery.value
        XCTAssertNil(result, "nothing reached Pi, so the caller may queue it instead")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
    }

    func testACallerArrivingAfterAdmissionClosedIsToldNothingReachedPi() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        registry.register(threadID: thread, runID: run, handle: runtime)
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)

        let late = await registry.deliver(threadID: thread, command: "steer", message: "too late")
        XCTAssertNil(late, "the caller queues a fresh run instead of writing into a stopping process")
        XCTAssertTrue(runtime.delivered.isEmpty, "and nothing was written")
    }

    func testTurnCreditsAreBoundedSoARunCannotBeExtendedForever() async {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        for index in 0..<LiveSessionRegistry.maxTurnCredits {
            let delivered = await registry.deliver(threadID: thread, command: "follow_up", message: "m\(index)")
            XCTAssertNotNil(delivered, "delivery \(index) should be admitted")
        }
        let refused = await registry.deliver(threadID: thread, command: "follow_up", message: "one too many")
        XCTAssertNil(refused, "past the bound the caller gets a fresh queued run, not an endless one")
    }

    func testSteeringIsNotRateLimitedByTheTurnCreditBound() async {
        // Steers owe no turns, so a long steering conversation must not exhaust the extension
        // budget that exists to stop a run being kept alive forever.
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        for index in 0..<(LiveSessionRegistry.maxTurnCredits * 3) {
            let delivered = await registry.deliver(threadID: thread, command: "steer", message: "m\(index)")
            XCTAssertNotNil(delivered, "steer \(index) should still be admitted")
        }
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
    }

    func testUnregisterStillRespectsGenerationAfterAClose() {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)

        registry.register(threadID: thread, runID: "run_2", handle: FakeLiveRuntime())
        registry.unregister(threadID: thread, runID: run)
        XCTAssertEqual(registry.liveRunID(threadID: thread), "run_2", "the new run survives the old one's cleanup")
    }
}

final class SubmissionRegistryTests: XCTestCase {
    private func response(_ runID: String) -> SendMessageResponse {
        SendMessageResponse(runId: runID, queued: false, delivery: .auto)
    }

    func testAFirstSubmissionProceedsAndARepeatReplaysTheSameAnswer() async {
        let registry = SubmissionRegistry()
        let claim = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(claim, .proceed)

        await registry.complete(threadID: "t1", clientID: "c1", response: response("run_1"))
        let again = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(again, .replay(response("run_1")), "a retry gets the original answer, not a second run")
    }

    func testAnOverlappingRepeatIsRefusedRatherThanRun() async {
        let registry = SubmissionRegistry()
        let first = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(first, .proceed)
        let overlapping = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(overlapping, .inFlight)
    }

    func testTheSameIDOnADifferentThreadIsADifferentSubmission() async {
        let registry = SubmissionRegistry()
        _ = await registry.claim(threadID: "t1", clientID: "c1")
        let other = await registry.claim(threadID: "t2", clientID: "c1")
        XCTAssertEqual(other, .proceed)
    }

    func testAbandoningAFailedClaimLetsAnHonestRetryThrough() async {
        let registry = SubmissionRegistry()
        _ = await registry.claim(threadID: "t1", clientID: "c1")
        await registry.abandon(threadID: "t1", clientID: "c1")
        let retry = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(retry, .proceed)
    }

    func testEntriesExpireSoTheRegistryCannotGrowWithoutBound() async {
        let registry = SubmissionRegistry()
        let start = Date()
        _ = await registry.claim(threadID: "t1", clientID: "c1", now: start)
        await registry.complete(threadID: "t1", clientID: "c1", response: response("run_1"), now: start)

        let later = start.addingTimeInterval(SubmissionRegistry.entryTTL + 60)
        let expired = await registry.claim(threadID: "t1", clientID: "c1", now: later)
        XCTAssertEqual(expired, .proceed)
    }

    func testAnInFlightClaimThatNeverFinishedIsEventuallyReleased() async {
        let registry = SubmissionRegistry()
        let start = Date()
        _ = await registry.claim(threadID: "t1", clientID: "c1", now: start)

        let later = start.addingTimeInterval(SubmissionRegistry.entryTTL + 60)
        let released = await registry.claim(threadID: "t1", clientID: "c1", now: later)
        XCTAssertEqual(released, .proceed, "a crashed handler must not block that submission forever")
    }

    func testTheRegistryIsBoundedByEntryCount() async {
        let registry = SubmissionRegistry()
        for index in 0...(SubmissionRegistry.maxEntries + 10) {
            _ = await registry.claim(threadID: "t1", clientID: "c\(index)")
            await registry.complete(threadID: "t1", clientID: "c\(index)", response: response("run_\(index)"))
        }
        let evicted = await registry.claim(threadID: "t1", clientID: "c0")
        XCTAssertEqual(evicted, .proceed, "the oldest entries were evicted")
        let newest = SubmissionRegistry.maxEntries + 10
        let retained = await registry.claim(threadID: "t1", clientID: "c\(newest)")
        XCTAssertEqual(retained, .replay(response("run_\(newest)")), "the newest are still protected")
    }
}
