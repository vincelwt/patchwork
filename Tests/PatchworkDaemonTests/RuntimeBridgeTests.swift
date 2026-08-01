import XCTest
import PatchworkKit
@testable import PatchworkDaemon

/// A `LiveRuntimeHandle` that records what it was asked to deliver and answers however the test
/// needs. No process, no pipe, no `pi` — every steering test runs against this.
final class FakeLiveRuntime: LiveRuntimeHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [(command: String, message: String)] = []
    private var _requests: [(type: String, payload: [String: PiJSONValue])] = []
    var delivered: [(command: String, message: String)] { lock.lock(); defer { lock.unlock() }; return _delivered }
    var requests: [(type: String, payload: [String: PiJSONValue])] { lock.lock(); defer { lock.unlock() }; return _requests }

    var result: LiveDelivery = .acknowledged
    var throwsWriteFailure = false

    func deliver(command: String, message: String) async throws -> LiveDelivery {
        record(command: command, message: message)
        if throwsWriteFailure { throw RunnerError.ioFailure("stdin closed") }
        return result
    }

    func request(type: String, payload: [String: PiJSONValue]) async throws -> PiJSONValue {
        record(type: type, payload: payload)
        let data: PiJSONValue
        switch type {
        case "get_state":
            data = .object([
                "model": .object(["provider": .string("openai"), "id": .string("gpt-5"), "name": .string("GPT-5")]),
                "thinkingLevel": .string("high")
            ])
        case "get_available_models":
            data = .object(["models": .array([
                .object(["provider": .string("openai"), "id": .string("gpt-5"), "name": .string("GPT-5")]),
                .object(["provider": .string("anthropic"), "id": .string("sonnet"), "name": .string("Sonnet")])
            ])])
        case "get_available_thinking_levels":
            data = .object(["levels": .array([.string("off"), .string("high")])])
        default:
            data = .object([:])
        }
        return .object(["type": .string("response"), "success": .bool(true), "data": data])
    }

    private func record(command: String, message: String) {
        lock.lock()
        _delivered.append((command, message))
        lock.unlock()
    }

    private func record(type: String, payload: [String: PiJSONValue]) {
        lock.lock()
        _requests.append((type, payload))
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

        XCTAssertEqual(registry.respond(id: "d1", value: "Beta", confirmed: nil, cancelled: false), .answered)
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

        XCTAssertEqual(registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false), .answered)
        XCTAssertEqual(registry.respond(id: "d1", value: "Beta", confirmed: nil, cancelled: false), .notFound)
        XCTAssertEqual(registry.respond(id: "nope", value: "x", confirmed: nil, cancelled: false), .notFound)
        XCTAssertEqual(sent().count, 1, "Pi is answered exactly once")
    }

    func testFailedDeliveryCanBeRetriedAgainstTheSamePendingDialog() {
        let registry = InteractionRegistry()
        let responder = RetryResponder()
        XCTAssertTrue(registry.register(interaction(), responder: responder.respond))

        guard case .writeFailed = registry.respond(
            id: "d1", value: "Alpha", confirmed: nil, cancelled: false
        ) else { return XCTFail("the first write should fail") }
        XCTAssertEqual(registry.pending().map(\.id), ["d1"])
        XCTAssertEqual(
            registry.respond(id: "d1", value: "Beta", confirmed: nil, cancelled: false),
            .answered
        )
        XCTAssertEqual(responder.sent.map { $0["value"]?.stringValue }, ["Beta"])
        XCTAssertTrue(registry.pending().isEmpty)
    }

    func testResolvingDialogStaysPendingAndRejectsConcurrentAnswersAndRegistration() {
        let registry = InteractionRegistry()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = RespondResultBox()
        let (record, sent) = collect()
        XCTAssertTrue(registry.register(interaction(), responder: { response in
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            record(response)
        }))

        DispatchQueue.global().async {
            result.value = registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(registry.pending().map(\.id), ["d1"])
        XCTAssertFalse(registry.register(self.interaction(), responder: record))
        XCTAssertEqual(
            registry.respond(id: "d1", value: "Beta", confirmed: nil, cancelled: false),
            .inFlight
        )

        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.value, .answered)
        XCTAssertEqual(sent().count, 1)
        XCTAssertTrue(registry.pending().isEmpty)
    }

    func testRunEndingAtomicallyRetiresAnAnswerThatFailsWhileInFlight() {
        let registry = InteractionRegistry()
        let responder = BlockingFirstFailureResponder()
        let finished = DispatchSemaphore(value: 0)
        XCTAssertTrue(registry.register(interaction(), responder: responder.respond))

        DispatchQueue.global().async {
            _ = registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false)
            finished.signal()
        }
        XCTAssertEqual(responder.entered.wait(timeout: .now() + 2), .success)
        registry.cancelAll(runID: "run_1")
        responder.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertTrue(registry.pending().isEmpty)
        XCTAssertEqual(responder.attemptCount, 1, "a finished run retires instead of writing again")
    }

    func testExpiryRetriesCancellationAfterAnInFlightAnswerFails() {
        let registry = InteractionRegistry()
        let responder = BlockingFirstFailureResponder()
        let finished = DispatchSemaphore(value: 0)
        XCTAssertTrue(registry.register(
            interaction(expiresIn: 0.01), responder: responder.respond
        ))

        DispatchQueue.global().async {
            _ = registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false)
            finished.signal()
        }
        XCTAssertEqual(responder.entered.wait(timeout: .now() + 2), .success)
        let expired = expectation(description: "expiry marked the in-flight answer")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { expired.fulfill() }
        wait(for: [expired], timeout: 3)
        responder.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        XCTAssertTrue(registry.pending().isEmpty)
        XCTAssertEqual(responder.attemptCount, 2)
        XCTAssertEqual(responder.sent.last?["cancelled"]?.boolValue, true)
    }

    func testAnOldExpiryTimerCannotCancelAReusedInteractionID() {
        let registry = InteractionRegistry()
        let (record, _) = collect()
        XCTAssertTrue(registry.register(interaction(expiresIn: 0.01), responder: record))
        XCTAssertEqual(
            registry.respond(id: "d1", value: "Alpha", confirmed: nil, cancelled: false),
            .answered
        )
        XCTAssertTrue(registry.register(interaction(expiresIn: 600), responder: record))

        let oldTimerFired = expectation(description: "old timer fired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { oldTimerFired.fulfill() }
        wait(for: [oldTimerFired], timeout: 3)

        XCTAssertEqual(registry.pending().map(\.id), ["d1"])
        registry.cancelAll(runID: "run_1")
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

    private final class RetryResponder: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var storage: [[String: PiJSONValue]] = []
        var respond: InteractionRegistry.Responder {
            { [weak self] response in
                guard let self else { return }
                try self.lock.withLock {
                    self.attempts += 1
                    if self.attempts == 1 { throw RunnerError.ioFailure("stdin closed") }
                    self.storage.append(response)
                }
            }
        }
        var sent: [[String: PiJSONValue]] { lock.withLock { storage } }
    }

    private final class BlockingFirstFailureResponder: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var attempts = 0
        private var storage: [[String: PiJSONValue]] = []

        var respond: InteractionRegistry.Responder {
            { [weak self] response in
                guard let self else { return }
                let attempt = self.lock.withLock {
                    self.attempts += 1
                    return self.attempts
                }
                if attempt == 1 {
                    self.entered.signal()
                    _ = self.release.wait(timeout: .now() + 3)
                    throw RunnerError.ioFailure("stdin closed")
                }
                self.lock.withLock { self.storage.append(response) }
            }
        }

        var attemptCount: Int { lock.withLock { attempts } }
        var sent: [[String: PiJSONValue]] { lock.withLock { storage } }
    }

    private final class RespondResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: InteractionRegistry.RespondResult?
        var value: InteractionRegistry.RespondResult? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }
}
