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

    func testAnAcceptedSteerKeepsTheRunConsumingThroughTheTurnItBought() async {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        let delivered = await registry.deliver(threadID: thread, command: "steer", message: "stop")
        XCTAssertEqual(delivered?.result, .acknowledged)

        // The `agent_settled` for the turn that was already running. Stopping here would discard
        // the message Pi just accepted.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
        XCTAssertNotNil(registry.liveRunID(threadID: thread), "still live: a turn is owed")

        // The steered turn's own settle. Nothing is owed now.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed)
        XCTAssertNil(registry.liveRunID(threadID: thread))
    }

    func testAnUnacknowledgedDeliveryAlsoBuysATurnBecauseItMayHaveApplied() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        runtime.result = .unacknowledged
        registry.register(threadID: thread, runID: run, handle: runtime)

        _ = await registry.deliver(threadID: thread, command: "follow_up", message: "and also")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
    }

    func testARejectedDeliveryBuysNothing() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        runtime.result = .rejected("nope")
        registry.register(threadID: thread, runID: run, handle: runtime)

        _ = await registry.deliver(threadID: thread, command: "steer", message: "x")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "it never ran, so it owes no turn")
    }

    func testASettleDuringAnInFlightWriteReportsBusyRatherThanClosing() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "stop") }
        XCTAssertTrue(runtime.waitForDeliveryToStart(), "the write is now genuinely mid-flight")

        // This is the race: the executor must not stop the session here.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .busy)
        XCTAssertNotNil(registry.liveRunID(threadID: thread))

        runtime.finishDelivery()
        let result = await delivery.value
        XCTAssertEqual(result?.result, .acknowledged)

        // Once the write lands it owes a turn, then the run may finish.
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
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
            let delivered = await registry.deliver(threadID: thread, command: "steer", message: "m\(index)")
            XCTAssertNotNil(delivered, "delivery \(index) should be admitted")
        }
        let refused = await registry.deliver(threadID: thread, command: "steer", message: "one too many")
        XCTAssertNil(refused, "past the bound the caller gets a fresh queued run, not an endless one")
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
