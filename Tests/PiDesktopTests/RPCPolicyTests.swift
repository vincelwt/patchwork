import Foundation
import XCTest
@testable import PiDesktop

final class RPCTimeoutPolicyTests: XCTestCase {
    func testStateQueriesFailAuthoritativelyAndSideEffectsDoNot() {
        XCTAssertEqual(RPCTimeoutPolicy.outcome(for: "get_state"), .authoritativeFailure(after: 30))
        XCTAssertEqual(RPCTimeoutPolicy.outcome(for: "get_session_stats"), .authoritativeFailure(after: 30))
        XCTAssertEqual(RPCTimeoutPolicy.outcome(for: "get_fork_messages"), .authoritativeFailure(after: 30))
        XCTAssertEqual(RPCTimeoutPolicy.outcome(for: "get_entries"), .authoritativeFailure(after: 30))
        XCTAssertEqual(RPCTimeoutPolicy.outcome(for: "get_commands"), .authoritativeFailure(after: 30))

        for command in ["prompt", "steer", "follow_up", "abort", "fork", "set_session_name", "export_html"] {
            guard case .outcomeUnknown = RPCTimeoutPolicy.outcome(for: command) else {
                return XCTFail("\(command) must never be reported as an authoritative rejection")
            }
            XCTAssertTrue(RPCFailureHandling.isOutcomeUnknown(RPCTimeoutPolicy.error(for: command)))
        }
    }

    func testCompactionIsAllowedToExceedThirtySeconds() {
        XCTAssertEqual(RPCTimeoutPolicy.outcome(for: "compact"), .outcomeUnknown(after: 900))
        XCTAssertGreaterThan(RPCTimeoutPolicy.delay(for: "compact"), 30)
    }

    func testAuthoritativeTimeoutIsNotTreatedAsOutcomeUnknown() {
        let error = RPCTimeoutPolicy.error(for: "get_state")
        XCTAssertFalse(RPCFailureHandling.isOutcomeUnknown(error))
        XCTAssertTrue(error.localizedDescription.contains("30 seconds"))
        XCTAssertFalse(RPCFailureHandling.isOutcomeUnknown(PiRPCError.processExited("gone")))
    }
}

final class RPCPendingRegistryTests: XCTestCase {
    func testResponsesFromASupersededGenerationAreDroppedNotPublished() {
        let registry = RPCPendingRegistry()
        let first = RuntimeGeneration(sequence: 1)
        let second = RuntimeGeneration(sequence: 2)
        var delivered: [String] = []

        registry.register(id: "desktop-1-1", command: "get_state", generation: first) { _ in
            delivered.append("first")
        }
        registry.register(id: "desktop-2-1", command: "get_state", generation: second) { _ in
            delivered.append("second")
        }

        // The old runtime's late response must not land in the replacement.
        XCTAssertNil(registry.takeForDelivery(id: "desktop-1-1", currentGeneration: second))
        XCTAssertFalse(registry.contains(id: "desktop-1-1"), "The stale entry is discarded, not left dangling")

        let callback = registry.takeForDelivery(id: "desktop-2-1", currentGeneration: second)
        XCTAssertNotNil(callback)
        callback?(.success(.object(["success": .bool(true)])))
        XCTAssertEqual(delivered, ["second"])
    }

    func testInvalidatedGenerationSuppressesDeliveryEvenForItsOwnID() {
        let registry = RPCPendingRegistry()
        let generation = RuntimeGeneration(sequence: 1)
        registry.register(id: "desktop-1-1", command: "get_state", generation: generation) { _ in
            XCTFail("A retired generation must never publish a success")
        }
        generation.invalidate()
        XCTAssertFalse(generation.isValid)
        XCTAssertNil(registry.takeForDelivery(id: "desktop-1-1", currentGeneration: generation))
        XCTAssertEqual(registry.count, 0)
    }

    func testTimeoutOnlyFiresForItsOwnGeneration() {
        let registry = RPCPendingRegistry()
        let first = RuntimeGeneration(sequence: 1)
        let second = RuntimeGeneration(sequence: 2)
        registry.register(id: "desktop-1-1", command: "prompt", generation: first) { _ in }

        XCTAssertNil(registry.takeForTimeout(id: "desktop-1-1", generation: second))
        XCTAssertTrue(registry.contains(id: "desktop-1-1"))
        XCTAssertNotNil(registry.takeForTimeout(id: "desktop-1-1", generation: first))
    }

    func testDrainAllDeliversEveryPendingCallbackExactlyOnce() {
        let registry = RPCPendingRegistry()
        let generation = RuntimeGeneration(sequence: 1)
        var count = 0
        for index in 0..<3 {
            registry.register(id: "desktop-1-\(index)", command: "prompt", generation: generation) { _ in count += 1 }
        }
        let drained = registry.drainAll()
        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual(registry.count, 0)
        for (_, callback) in drained { callback(.failure(PiRPCError.processExited("stopped"))) }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(registry.drainAll().isEmpty, "A second drain must not re-deliver")
    }

    func testDrainAllReturnsTheCommandEachCallbackWasRegisteredFor() {
        let registry = RPCPendingRegistry()
        let generation = RuntimeGeneration(sequence: 1)
        registry.register(id: "desktop-1-1", command: "get_state", generation: generation) { _ in }
        registry.register(id: "desktop-1-2", command: "prompt", generation: generation) { _ in }

        let commands = Set(registry.drainAll().map(\.command))
        XCTAssertEqual(commands, ["get_state", "prompt"])
    }
}

final class PiRPCClientProcessTests: XCTestCase {
    /// A fake RPC process: echoes one response per request after a delay, so a stop that races
    /// an in-flight response is deterministic.
    private static let slowEchoScript = """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
      sleep 0.6
      printf '{"type":"response","id":"%s","success":true,"data":{"echo":true}}\\n' "$id"
    done
    """

    private static let fastEchoScript = """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
      printf '{"type":"response","id":"%s","success":true,"data":{"echo":true}}\\n' "$id"
    done
    """

    private static let responseThenEventScript = """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
      printf '{"type":"response","id":"%s","success":true,"data":{}}\\n{"type":"owner_event"}\\n' "$id"
    done
    """

    private func client(script: String) -> PiRPCClient {
        PiRPCClient(
            executableOverride: URL(fileURLWithPath: "/bin/sh"),
            argumentsOverride: ["-c", script]
        )
    }

    func testStoppedRuntimeNeverPublishesIntoItsReplacement() throws {
        let client = self.client(script: Self.slowEchoScript)
        try client.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)

        var outcomes: [Result<JSONValue, Error>] = []
        let completed = expectation(description: "stale request completes once")
        client.send(type: "get_state", payload: [:]) { result in
            outcomes.append(result)
            completed.fulfill()
        }
        // Stop before the fake process answers: the in-flight response must be dropped and the
        // caller completed exactly once with a terminal failure.
        client.stop()
        wait(for: [completed], timeout: 5)

        let settled = expectation(description: "no late duplicate delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(outcomes.count, 1, "A stopped runtime must deliver exactly one terminal result")
        guard case .failure = outcomes[0] else {
            return XCTFail("A stopped runtime must not publish a success response")
        }
        XCTAssertFalse(client.isRunning)
    }

    func testBufferedEventKeepsTheHandlerThatOwnedItsPipeChunk() throws {
        let client = self.client(script: Self.responseThenEventScript)
        defer { client.stop() }
        try client.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)
        let oldOwner = expectation(description: "old owner receives buffered event")
        let wrongOwner = expectation(description: "new owner never receives buffered event")
        wrongOwner.isInverted = true
        client.onEvent = { event in
            if event["type"]?.stringValue == "owner_event" { oldOwner.fulfill() }
        }

        let response = expectation(description: "response rebinds owner first")
        client.send(type: "get_state", payload: [:]) { _ in
            client.onEvent = { event in
                if event["type"]?.stringValue == "owner_event" { wrongOwner.fulfill() }
            }
            response.fulfill()
        }
        wait(for: [response, oldOwner, wrongOwner], timeout: 2)
    }

    func testReplacementRuntimeAnswersWithItsOwnGenerationScopedIDs() throws {
        let client = self.client(script: Self.fastEchoScript)
        try client.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)
        client.stop()
        try client.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)
        defer { client.stop() }

        var response: JSONValue?
        let answered = expectation(description: "replacement answers")
        client.send(type: "get_state", payload: [:]) { result in
            if case let .success(value) = result { response = value }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 6)

        let id = try XCTUnwrap(response?["id"]?.stringValue)
        XCTAssertTrue(id.hasPrefix("desktop-"))
        // Request IDs carry the runtime generation, so a stale ID can never alias a live one.
        XCTAssertEqual(id.split(separator: "-").count, 3, "IDs are desktop-<generation>-<counter>")
        XCTAssertNotEqual(id, "desktop-1-1", "The replacement runs in a later generation")
    }

    func testStoppingWhileASideEffectingCommandIsPendingIsOutcomeUnknown() throws {
        // Stopped before the fake process can answer: models a crash/stop while a "prompt" is in
        // flight. The pending completion must not be reported as a definite failure, because Pi
        // may already have durably accepted the message — exactly the ambiguity that must never
        // be resolved by silently assuming "safe to resend". Reuses the same slow-echo fixture
        // and stop-while-pending shape as `testStoppedRuntimeNeverPublishesIntoItsReplacement`
        // above, which is already proven stable under the full suite.
        let client = self.client(script: Self.slowEchoScript)
        try client.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)

        var outcome: Result<JSONValue, Error>?
        let completed = expectation(description: "prompt settles")
        client.send(type: "prompt", payload: ["message": .string("hi")]) { result in
            outcome = result
            completed.fulfill()
        }
        client.stop()
        wait(for: [completed], timeout: 5)

        guard case let .failure(error) = try XCTUnwrap(outcome) else {
            return XCTFail("A stopped runtime must not report success for an unconfirmed prompt")
        }
        XCTAssertTrue(RPCFailureHandling.isOutcomeUnknown(error), "Pi may have already accepted the prompt before the client gave up")
    }

    func testStoppingWhileAStateQueryIsPendingIsAnAuthoritativeFailure() throws {
        // A read-only query has no side effect to protect, so its death is a definite failure —
        // unlike a side-effecting command such as "prompt".
        let client = self.client(script: Self.slowEchoScript)
        try client.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)

        var outcome: Result<JSONValue, Error>?
        let completed = expectation(description: "get_state settles")
        client.send(type: "get_state", payload: [:]) { result in
            outcome = result
            completed.fulfill()
        }
        client.stop()
        wait(for: [completed], timeout: 5)

        guard case let .failure(error) = try XCTUnwrap(outcome) else {
            return XCTFail("A dead process must not report success")
        }
        XCTAssertFalse(RPCFailureHandling.isOutcomeUnknown(error), "A read-only query has no side effect to protect")
    }

    func testReapEscalatesToKillForAProcessThatIgnoresSIGTERM() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 0.2; done"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        PiProcessReaper.reap(process, gracefulDeadline: 0.3)
        let reaped = expectation(description: "process reaped")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if !process.isRunning { reaped.fulfill() }
        }
        wait(for: [reaped], timeout: 6)
        XCTAssertFalse(process.isRunning, "SIGTERM-ignoring runtimes must be escalated to SIGKILL")
    }
}
