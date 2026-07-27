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

    /// Waits for `count` gated deliveries to be mid-flight, then releases all of them. The gate is
    /// always opened, even when a delivery never arrived, so a failing assertion reports a failure
    /// instead of leaving the test blocked on a write nobody will ever release.
    func waitForAndFinish(_ count: Int) -> Bool {
        var allStarted = true
        for _ in 0..<count where !waitForDeliveryToStart() { allStarted = false }
        for _ in 0..<count { finishDelivery() }
        return allStarted
    }
}

/// A counter shared across tasks, so a test can assert the drain kept pumping the pipe rather
/// than spinning or returning early.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class LiveSettlementTests: XCTestCase {
    private let thread = "t1"
    private let run = "run_1"

    /// Polls a condition another task is expected to satisfy. Bounded, so a regression fails the
    /// assertion that follows rather than hanging the suite.
    private static func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

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

    // MARK: - Shutdown: a timeout or an abort, which arrive nowhere near a settle boundary

    func testATimeoutWaitsForAnInFlightWriteInsteadOfStoppingPiUnderIt() async {
        // The hazard: `RunManager`'s timeout cancels the run task while a steer is mid-write. The
        // executor unregisters and `session.stop()` kills Pi — and the HTTP caller, still waiting
        // on an acknowledgement that can now never arrive, is told the message may have landed.
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "stop") }
        XCTAssertTrue(runtime.waitForDeliveryToStart(), "the write is genuinely mid-flight")

        let pumps = Counter()
        let released = Flag()
        let drain = Task { () -> (finished: Bool, sawRelease: Bool) in
            let finished = await registry.drainForShutdown(
                threadID: self.thread, runID: self.run, deadline: Date().addingTimeInterval(5)
            ) {
                pumps.increment()
                try? await Task.sleep(nanoseconds: 5_000_000)
                return true
            }
            return (finished, released.isSet)
        }

        // Admission shuts immediately, so nothing new is written into a session about to stop.
        await Self.waitUntil { registry.liveRunID(threadID: self.thread) == nil }
        XCTAssertNil(registry.liveRunID(threadID: thread))
        if registry.liveRunID(threadID: thread) == nil {
            let late = await registry.deliver(threadID: thread, command: "steer", message: "too late")
            XCTAssertNil(late, "a caller arriving during the drain queues a fresh run")
        }

        // The pipe keeps being read while the drain waits: an acknowledgement nobody consumes is
        // indistinguishable from one Pi never sent.
        await Self.waitUntil { pumps.count >= 2 }
        XCTAssertGreaterThanOrEqual(pumps.count, 2)

        released.set()
        runtime.finishDelivery()
        let outcome = await drain.value
        XCTAssertTrue(outcome.finished, "the drain ended because the write finished, not on its bound")
        XCTAssertTrue(outcome.sawRelease, "it waited for the write instead of stopping Pi under it")
        let delivered = await delivery.value
        XCTAssertEqual(delivered?.result, .acknowledged, "the caller hears what really happened")
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "a run that timed out never continues")
    }

    func testTheShutdownDrainIsBoundedSoAWedgedWriteCannotHoldAStopOpen() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "follow_up", message: "hi") }
        XCTAssertTrue(runtime.waitForDeliveryToStart())

        let finished = await registry.drainForShutdown(
            threadID: thread, runID: run, deadline: Date().addingTimeInterval(0.2)
        ) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return true
        }
        XCTAssertFalse(finished, "an explicit stop stays bounded even when a write never lands")

        runtime.finishDelivery()
        _ = await delivery.value
    }

    func testTheDrainStopsAtOnceWhenNothingCanAnswerAnyMore() async {
        // The pump reports a process that has already exited: it can neither acknowledge anything
        // nor be stopped twice, so waiting out the bound would be pure delay. An unbounded
        // deadline here would hang if that were not true.
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let delivery = Task { await registry.deliver(threadID: thread, command: "steer", message: "hi") }
        XCTAssertTrue(runtime.waitForDeliveryToStart())

        let finished = await registry.drainForShutdown(threadID: thread, runID: run, deadline: .distantFuture) { false }
        XCTAssertFalse(finished)

        runtime.finishDelivery()
        _ = await delivery.value
    }

    func testDrainingAnIdleRunReturnsImmediatelyAndClosesAdmission() async {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())
        let pumps = Counter()

        let finished = await registry.drainForShutdown(threadID: thread, runID: run, deadline: .distantFuture) {
            pumps.increment()
            return true
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(pumps.count, 0, "the ordinary settle path pays nothing for this")
        XCTAssertNil(registry.liveRunID(threadID: thread))
    }

    func testAnotherRunsShutdownCannotCloseThisOne() async {
        let registry = LiveSessionRegistry()
        registry.register(threadID: thread, runID: run, handle: FakeLiveRuntime())

        let drained = await registry.drainForShutdown(threadID: thread, runID: "someone_else", deadline: .distantFuture) { true }
        XCTAssertTrue(drained)
        XCTAssertEqual(registry.liveRunID(threadID: thread), run, "a stranger's shutdown must not retire this run")
    }

    // MARK: - Concurrency against the credit bound

    func testSimultaneousFollowUpsCannotOutrunTheTurnCreditBound() async {
        // Every reservation used to read `grantedCredits` before any release had incremented it,
        // so N concurrent follow-ups all saw an untouched budget and all were admitted — N extra
        // turns from a bound of eight.
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let attempts = LiveSessionRegistry.maxTurnCredits * 2 + 1
        let tasks = (0..<attempts).map { index in
            Task { await registry.deliver(threadID: self.thread, command: "follow_up", message: "m\(index)") }
        }
        XCTAssertTrue(runtime.waitForAndFinish(LiveSessionRegistry.maxTurnCredits))

        var admitted = 0
        for task in tasks where await task.value != nil { admitted += 1 }
        XCTAssertEqual(admitted, LiveSessionRegistry.maxTurnCredits, "capacity is taken at reservation, not at release")
        XCTAssertEqual(runtime.delivered.count, LiveSessionRegistry.maxTurnCredits, "nothing past the bound reached Pi")

        for index in 0..<LiveSessionRegistry.maxTurnCredits {
            XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming, "turn \(index)")
        }
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "and not one turn more")
    }

    func testARejectedConcurrentFollowUpRefundsItsCapacity() async {
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        runtime.result = .rejected("nope")
        registry.register(threadID: thread, runID: run, handle: runtime)

        let tasks = (0..<LiveSessionRegistry.maxTurnCredits).map { index in
            Task { await registry.deliver(threadID: self.thread, command: "follow_up", message: "m\(index)") }
        }
        XCTAssertTrue(runtime.waitForAndFinish(LiveSessionRegistry.maxTurnCredits))
        for task in tasks { _ = await task.value }

        // None of them ran, so none of them spent anything: the budget is whole again.
        runtime.gated = false
        runtime.result = .acknowledged
        let after = await registry.deliver(threadID: thread, command: "follow_up", message: "later")
        XCTAssertNotNil(after, "a refused message must not consume the run's extension budget")
    }

    func testManySteersCrossingOneBoundaryExtendTheRunExactlyOnce() async {
        // They all raced the same settle. Crediting each of them would extend the run once per
        // concurrent write, which is the unbounded version of "conservatively keep it alive".
        let registry = LiveSessionRegistry()
        let runtime = GatedLiveRuntime()
        runtime.gated = true
        registry.register(threadID: thread, runID: run, handle: runtime)

        let steers = 5
        let tasks = (0..<steers).map { index in
            Task { await registry.deliver(threadID: self.thread, command: "steer", message: "s\(index)") }
        }
        for _ in 0..<steers { XCTAssertTrue(runtime.waitForDeliveryToStart()) }
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .busy)

        for _ in 0..<steers { runtime.finishDelivery() }
        for task in tasks { _ = await task.value }

        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .continueConsuming)
        XCTAssertEqual(registry.closeAdmission(threadID: thread, runID: run), .closed, "one turn covers all of them")
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

    func testAnInFlightClaimIsNeverEvictedToMakeRoomForANewOne() async {
        // Evicting one would un-protect a send that is still running: its retry would be a second
        // prompt, which is the exact failure `clientId` exists to prevent.
        let registry = SubmissionRegistry()
        for index in 0..<SubmissionRegistry.maxEntries {
            let claim = await registry.claim(threadID: "t1", clientID: "c\(index)")
            XCTAssertEqual(claim, .proceed, "claim \(index)")
        }

        let overflow = await registry.claim(threadID: "t1", clientID: "one-too-many")
        XCTAssertEqual(overflow, .overloaded, "the new submission is refused, not an old one forgotten")
        let oldest = await registry.claim(threadID: "t1", clientID: "c0")
        XCTAssertEqual(oldest, .inFlight, "the oldest is still protected")

        // Finishing one frees exactly one slot, and the completed entry is the eviction victim.
        await registry.complete(threadID: "t1", clientID: "c0", response: response("run_0"))
        let admitted = await registry.claim(threadID: "t1", clientID: "one-too-many")
        XCTAssertEqual(admitted, .proceed)
        let stillRunning = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(stillRunning, .inFlight, "and no in-flight claim was touched")
    }

    func testALateCompletionCannotResurrectAClaimNobodyOwnsAnyMore() async {
        let registry = SubmissionRegistry()
        _ = await registry.claim(threadID: "t1", clientID: "c1")
        await registry.abandon(threadID: "t1", clientID: "c1")

        // The handler failed, released its claim, and only then managed to report a response.
        await registry.complete(threadID: "t1", clientID: "c1", response: response("run_1"))
        let retry = await registry.claim(threadID: "t1", clientID: "c1")
        XCTAssertEqual(retry, .proceed, "a released claim stays released")
    }

    func testACompletionAfterTheTTLDoesNotReviveTheEntry() async {
        let registry = SubmissionRegistry()
        let start = Date()
        _ = await registry.claim(threadID: "t1", clientID: "c1", now: start)

        let later = start.addingTimeInterval(SubmissionRegistry.entryTTL + 60)
        // Any call prunes; this one is a different submission entirely.
        _ = await registry.claim(threadID: "t2", clientID: "c9", now: later)
        await registry.complete(threadID: "t1", clientID: "c1", response: response("run_1"), now: later)
        let afterTTL = await registry.claim(threadID: "t1", clientID: "c1", now: later)
        XCTAssertEqual(afterTTL, .proceed, "not replayed from a dead claim")
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
