import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// A `LiveRuntimeHandle` that records what it was asked to deliver and answers however the test
/// needs. No process, no pipe, no `pi` — every steering test runs against this.
final class FakeLiveRuntime: LiveRuntimeHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [(command: String, message: String)] = []
    var delivered: [(command: String, message: String)] { lock.lock(); defer { lock.unlock() }; return _delivered }

    var result: LiveDelivery = .acknowledged
    var throwsWriteFailure = false

    func deliver(command: String, message: String) async throws -> LiveDelivery {
        record(command: command, message: message)
        if throwsWriteFailure { throw RunnerError.ioFailure("stdin closed") }
        return result
    }

    private func record(command: String, message: String) {
        lock.lock()
        _delivered.append((command, message))
        lock.unlock()
    }
}

final class LiveSessionRegistryTests: XCTestCase {
    func testNoLiveTurnMeansNothingWasDelivered() async {
        let registry = LiveSessionRegistry()
        let outcome = await registry.deliver(threadID: "t1", command: "steer", message: "hi")
        XCTAssertNil(outcome, "nil is the caller's signal that it is safe to queue instead")
    }

    func testDeliversPisOwnCommandVerbatimAndReportsTheOwningRun() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        registry.register(threadID: "t1", runID: "run_1", handle: runtime)

        let outcome = await registry.deliver(threadID: "t1", command: "steer", message: "stop that")
        XCTAssertEqual(outcome?.runID, "run_1")
        XCTAssertEqual(outcome?.result, .acknowledged)
        XCTAssertEqual(runtime.delivered.map(\.command), ["steer"])
        XCTAssertEqual(runtime.delivered.map(\.message), ["stop that"])
    }

    func testAWriteFailureReportsNothingDeliveredSoTheCallerMayQueue() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        runtime.throwsWriteFailure = true
        registry.register(threadID: "t1", runID: "run_1", handle: runtime)

        let outcome = await registry.deliver(threadID: "t1", command: "steer", message: "hi")
        XCTAssertNil(outcome)
    }

    func testAnUnacknowledgedDeliveryIsStillADeliveryNotAQueueFallback() async {
        let registry = LiveSessionRegistry()
        let runtime = FakeLiveRuntime()
        runtime.result = .unacknowledged
        registry.register(threadID: "t1", runID: "run_1", handle: runtime)

        let outcome = await registry.deliver(threadID: "t1", command: "steer", message: "hi")
        XCTAssertEqual(outcome?.result, .unacknowledged, "re-queueing here would risk prompting Pi twice")
    }

    func testAStaleRunCannotUnregisterItsSuccessor() {
        let registry = LiveSessionRegistry()
        registry.register(threadID: "t1", runID: "run_1", handle: FakeLiveRuntime())
        registry.register(threadID: "t1", runID: "run_2", handle: FakeLiveRuntime())

        // run_1 settles late and runs its own cleanup.
        registry.unregister(threadID: "t1", runID: "run_1")
        XCTAssertEqual(registry.liveRunID(threadID: "t1"), "run_2", "the live turn must survive")

        registry.unregister(threadID: "t1", runID: "run_2")
        XCTAssertNil(registry.liveRunID(threadID: "t1"))
        XCTAssertTrue(registry.liveThreadIDs.isEmpty)
    }
}

final class InteractionRegistryTests: XCTestCase {
    private func interaction(
        id: String = "d1",
        runID: String = "run_1",
        method: InteractionMethod = .select,
        options: [String] = ["Alpha", "Beta"],
        expiresIn: TimeInterval = 600
    ) -> PendingInteraction {
        PendingInteraction(
            id: id, runId: runID, threadId: "t1", method: method, title: "Pick one",
            options: options, expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Captures what the registry would have written back to Pi.
    private func collect() -> (record: @Sendable ([String: PiJSONValue]) -> Void, sent: () -> [[String: PiJSONValue]]) {
        let box = ResponseBox()
        return ({ box.append($0) }, { box.all })
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String: PiJSONValue]] = []
        func append(_ value: [String: PiJSONValue]) { lock.lock(); storage.append(value); lock.unlock() }
        var all: [[String: PiJSONValue]] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testRegisteredDialogIsListedAndAnsweredWithPisExactOptionValue() {
        let registry = InteractionRegistry()
        let (record, sent) = collect()
        XCTAssertTrue(registry.register(interaction(), responder: record))

        XCTAssertEqual(registry.pending().map(\.id), ["d1"])
        XCTAssertEqual(registry.pending(threadID: "t1").count, 1)
        XCTAssertEqual(registry.pending(threadID: "other").count, 0)

        XCTAssertTrue(registry.respond(id: "d1", value: "Beta", confirmed: nil, cancelled: false))
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent()[0]["type"]?.stringValue, "extension_ui_response")
        XCTAssertEqual(sent()[0]["id"]?.stringValue, "d1")
        XCTAssertEqual(sent()[0]["value"]?.stringValue, "Beta")
        XCTAssertTrue(registry.pending().isEmpty, "an answered dialog is forgotten")
    }

    func testConfirmAndCancelUseTheirOwnFieldsAndAnEmptyAnswerIsACancellation() {
        let registry = InteractionRegistry()
        let (record, sent) = collect()
        _ = registry.register(interaction(id: "c1", method: .confirm), responder: record)
        registry.respond(id: "c1", value: nil, confirmed: false, cancelled: false)
        XCTAssertEqual(sent()[0]["confirmed"]?.boolValue, false)

        _ = registry.register(interaction(id: "c2"), responder: record)
        registry.respond(id: "c2", value: nil, confirmed: nil, cancelled: true)
        XCTAssertEqual(sent()[1]["cancelled"]?.boolValue, true)

        // Neither a value nor a confirmation: a cancellation, never an invented blank answer.
        _ = registry.register(interaction(id: "c3"), responder: record)
        registry.respond(id: "c3", value: nil, confirmed: nil, cancelled: false)
        XCTAssertEqual(sent()[2]["cancelled"]?.boolValue, true)
        XCTAssertNil(sent()[2]["value"])
    }

    func testAnsweringTwiceOrAnsweringAnUnknownDialogIsRefused() {
        let registry = InteractionRegistry()
        let (record, sent) = collect()
        _ = registry.register(interaction(), responder: record)

        XCTAssertTrue(registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false))
        XCTAssertFalse(registry.respond(id: "d1", value: "Beta", confirmed: nil, cancelled: false))
        XCTAssertFalse(registry.respond(id: "nope", value: "x", confirmed: nil, cancelled: false))
        XCTAssertEqual(sent().count, 1, "Pi is answered exactly once")
    }

    func testPendingDialogsAreBoundedAndTheOverflowIsRefusedNotSwallowed() {
        let registry = InteractionRegistry()
        let (record, _) = collect()
        for index in 0..<InteractionRegistry.maxPending {
            XCTAssertTrue(registry.register(interaction(id: "d\(index)"), responder: record))
        }
        XCTAssertFalse(
            registry.register(interaction(id: "overflow"), responder: record),
            "the caller must cancel it itself rather than leave Pi blocked"
        )
        XCTAssertEqual(registry.pending().count, InteractionRegistry.maxPending)
        XCTAssertFalse(registry.register(interaction(id: "d0"), responder: record), "duplicate ids are refused")
    }

    func testARunEndingCancelsOnlyItsOwnDialogs() {
        let registry = InteractionRegistry()
        let (record, sent) = collect()
        _ = registry.register(interaction(id: "a", runID: "run_1"), responder: record)
        _ = registry.register(interaction(id: "b", runID: "run_1"), responder: record)
        _ = registry.register(interaction(id: "c", runID: "run_2"), responder: record)

        registry.cancelAll(runID: "run_1")
        XCTAssertEqual(registry.pending().map(\.id), ["c"])
        XCTAssertEqual(sent().count, 2)
        XCTAssertTrue(sent().allSatisfy { $0["cancelled"]?.boolValue == true })
    }

    func testAnExpiredDialogIsCancelledNeverAnswered() {
        let registry = InteractionRegistry()
        let (record, sent) = collect()
        // The registry's own timer floors at one second, so expiry is asserted through the
        // published deadline plus the cancellation it produces, not by sleeping for it.
        _ = registry.register(interaction(id: "e1", expiresIn: 0.01), responder: record)

        let expectation = expectation(description: "expired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) { expectation.fulfill() }
        wait(for: [expectation], timeout: 5)

        XCTAssertTrue(registry.pending().isEmpty)
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent()[0]["cancelled"]?.boolValue, true, "expiry unblocks the run; it never invents an answer")
        XCTAssertNil(sent()[0]["value"])
    }

    func testEventsArePublishedOnRegistrationAndOnResolution() throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bus = EventBus(logger: TestSupport.logger(in: directory))
        let registry = InteractionRegistry()
        registry.attach(bus: bus)

        let received = ResponseBox()
        let names = NameBox()
        bus.subscribe { name, payload in
            names.append(name)
            if let value = try? PiJSONValue.decode(payload), let object = value.objectValue { received.append(object) }
        }

        let (record, _) = collect()
        _ = registry.register(interaction(), responder: record)
        registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false)

        let expectation = expectation(description: "delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 3)

        XCTAssertEqual(names.all, ["interaction", "interaction"])
        XCTAssertNil(received.all.first?["resolvedAt"], "the first frame is the pending dialog")
        XCTAssertNotNil(received.all.last?["resolvedAt"], "the last frame retires it")
    }

    private final class NameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
