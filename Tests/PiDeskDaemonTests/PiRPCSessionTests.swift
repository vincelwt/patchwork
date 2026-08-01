import XCTest
import PiDeskKit
@testable import PiDeskDaemon

final class PiRPCSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testReceiveMatchingSkipsAndPreservesEarlierEvents() async throws {
        let executable = directory.appendingPathComponent("fake-pi")
        try """
        #!/bin/sh
        IFS= read -r request
        id=$(printf '%s' "$request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '%s\\n' '{"type":"extension_ui_request","method":"setStatus"}'
        /bin/sleep 0.1
        printf '{"type":"response","id":"%s","success":true}\\n' "$id"
        /bin/sleep 10
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let session = try PiRPCSession.start(
            cwd: directory,
            sessionPath: nil,
            piExecutable: executable,
            environment: ProcessInfo.processInfo.environment
        )
        defer { session.stop() }

        let requestID = try session.send(type: "get_state")
        let response = try await session.receiveMatching(id: requestID, timeout: 1)
        XCTAssertEqual(response["id"]?.stringValue, requestID)
        let cachedDuplicate = await session.awaitCachedResponse(id: requestID, timeout: 0.05)
        XCTAssertNil(cachedDuplicate, "the ordinary matching reader consumes its cached duplicate")

        let event = try await session.receiveNext(timeout: 1)
        XCTAssertEqual(event?["type"]?.stringValue, "extension_ui_request")
    }

    func testAdapterWritebackFailureSurfacesImmediatelyAndBreaksTheSession() async throws {
        let executable = directory.appendingPathComponent("writeback-pi")
        try """
        #!/bin/sh
        printf '%s\n' '{"trigger":true}'
        /bin/sleep 30
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let session = try PiRPCSession.start(
            cwd: directory,
            sessionPath: nil,
            piExecutable: executable,
            environment: ProcessInfo.processInfo.environment,
            writeTimeout: 0.2,
            adapter: LargeWritebackAdapter()
        )
        defer { session.stop() }

        let started = Date()
        do {
            _ = try await session.receiveNext(timeout: 2)
            XCTFail("expected the writeback to fail")
        } catch let error as RunnerError {
            guard case .ioFailure = error else { return XCTFail("expected ioFailure, got \(error)") }
        } catch {
            XCTFail("expected RunnerError.ioFailure, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertThrowsError(try session.send(type: "get_state"), "a torn stream must stay broken")
    }

    func testPartialGroupedDialogAnswerIsAcceptedWithoutWritingYet() throws {
        let executable = directory.appendingPathComponent("waiting-agent")
        try """
        #!/bin/sh
        /bin/sleep 30
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = try PiRPCSession.start(
            cwd: directory, sessionPath: nil, piExecutable: executable,
            environment: ProcessInfo.processInfo.environment,
            adapter: AcceptedWithoutWriteAdapter()
        )
        defer { session.stop() }

        XCTAssertNoThrow(try session.sendRaw([
            "type": .string("extension_ui_response"), "id": .string("question-1")
        ]))
    }

    func testResponseCacheEvictsByBytesAndKeepsTheNewestAcknowledgement() async throws {
        let executable = directory.appendingPathComponent("large-response-pi")
        try """
        #!/bin/sh
        printf '%s\n' '{"id":"one"}' '{"id":"two"}'
        /bin/sleep 30
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let session = try PiRPCSession.start(
            cwd: directory,
            sessionPath: nil,
            piExecutable: executable,
            environment: ProcessInfo.processInfo.environment,
            adapter: LargeResponseAdapter()
        )
        defer { session.stop() }

        _ = try await session.receiveNext(timeout: 2)
        _ = try await session.receiveNext(timeout: 2)
        let usage = session.responseCacheUsageForTesting
        XCTAssertEqual(usage.count, 1)
        XCTAssertLessThanOrEqual(usage.bytes, PiRPCSession.responseCacheByteLimit)
        let evicted = await session.awaitCachedResponse(id: "one", timeout: 0.05)
        let newest = await session.awaitCachedResponse(id: "two", timeout: 0.05)
        XCTAssertNil(evicted)
        XCTAssertEqual(newest?["id"]?.stringValue, "two")
    }

    /// An echo `pi`: records every request line it receives and answers each one. Enough to prove
    /// the write path stays intact under concurrency without ever running the real CLI.
    private func makeEchoPi(recordingTo transcript: URL) throws -> URL {
        let executable = directory.appendingPathComponent("echo-pi")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$PI_TEST_TRANSCRIPT"
          id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
          printf '{"type":"response","id":"%s","success":true}\\n' "$id"
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        return executable
    }

    /// Prompts come from the run's own task while steer/follow-up deliveries and dialog answers
    /// arrive from HTTP handlers on others. Two interleaved partial lines would corrupt Pi's
    /// stdin, so every write is serialized and every request id stays unique.
    func testConcurrentWritesProduceWholeDistinctJSONLLines() async throws {
        let transcript = directory.appendingPathComponent("stdin.jsonl")
        let executable = try makeEchoPi(recordingTo: transcript)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_TEST_TRANSCRIPT"] = transcript.path

        let session = try PiRPCSession.start(
            cwd: directory, sessionPath: nil, piExecutable: executable, environment: environment
        )
        defer { session.stop() }

        let writes = 16
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<writes {
                group.addTask {
                    // A mix of the three writers that really do overlap in production.
                    if index % 3 == 0 { return try session.send(type: "steer", payload: ["message": .string("s\(index)")]) }
                    if index % 3 == 1 { return try session.send(type: "follow_up", payload: ["message": .string("f\(index)")]) }
                    try session.sendRaw([
                        "type": .string("extension_ui_response"), "id": .string("dialog-\(index)"), "cancelled": .bool(true)
                    ])
                    return "dialog-\(index)"
                }
            }
            var collected: [String] = []
            for try await id in group { collected.append(id) }
            return collected
        }

        XCTAssertEqual(Set(ids).count, writes, "every correlated request gets a distinct id")

        // Give the echo process time to consume everything it was sent.
        let deadline = Date().addingTimeInterval(5)
        var lines: [String] = []
        while Date() < deadline {
            lines = ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            if lines.count >= writes { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(lines.count, writes, "no write was lost or merged into another")
        for line in lines {
            let value = try XCTUnwrap(try? PiJSONValue.decode(Data(line.utf8)), "a torn line would not parse: \(line)")
            XCTAssertNotNil(value["type"]?.stringValue)
            XCTAssertNotNil(value["id"]?.stringValue)
        }
    }

    func testCausalWritebackPrecedesAConcurrentOutboundCommand() async throws {
        let transcript = directory.appendingPathComponent("causal-stdin.jsonl")
        let executable = directory.appendingPathComponent("causal-agent")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$PI_TEST_TRANSCRIPT"
          case "$line" in
            *'"kind":"prime"'*) printf '%s\n' '{"trigger":true}' ;;
          esac
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_TEST_TRANSCRIPT"] = transcript.path
        let adapter = CausalWritebackAdapter()
        let session = try PiRPCSession.start(
            cwd: directory, sessionPath: nil, piExecutable: executable,
            environment: environment, adapter: adapter
        )
        defer { session.stop() }

        _ = try session.send(type: "prime")
        let receive = Task { try await session.receiveNext(timeout: 3) }
        XCTAssertEqual(adapter.decodeEntered.wait(timeout: .now() + 2), .success)
        let sendAttempted = DispatchSemaphore(value: 0)
        let newer = Task {
            sendAttempted.signal()
            return try session.send(type: "newer")
        }
        XCTAssertEqual(sendAttempted.wait(timeout: .now() + 2), .success)
        adapter.releaseDecode.signal()
        _ = try await receive.value
        _ = try await newer.value

        let deadline = Date().addingTimeInterval(2)
        var kinds: [String] = []
        while Date() < deadline {
            kinds = ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { line in
                    (try? PiJSONValue.decode(Data(line.utf8)))?["kind"]?.stringValue
                }
            if kinds.count == 3 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(kinds, ["prime", "writeback", "newer"])
    }

    /// A steer delivered from an HTTP handler collects its acknowledgement from the cache the
    /// run's own drain loop fills, so the two never read the pipe at the same time.
    func testAnAcknowledgementIsReadableByANonDrainingCaller() async throws {
        let transcript = directory.appendingPathComponent("stdin.jsonl")
        let executable = try makeEchoPi(recordingTo: transcript)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_TEST_TRANSCRIPT"] = transcript.path

        let session = try PiRPCSession.start(
            cwd: directory, sessionPath: nil, piExecutable: executable, environment: environment
        )
        defer { session.stop() }

        let steerID = try session.send(type: "steer", payload: ["message": .string("stop")])

        // Stand in for `consumeUntilSettled`: the only reader of stdout.
        let drain = Task { while (try? await session.receiveNext(timeout: 1)) != nil, !Task.isCancelled {} }
        defer { drain.cancel() }

        let response = await session.awaitCachedResponse(id: steerID, timeout: 5)
        XCTAssertEqual(response?["id"]?.stringValue, steerID)
        XCTAssertEqual(response?["success"]?.boolValue, true)

        let again = await session.awaitCachedResponse(id: steerID, timeout: 0.2)
        XCTAssertNil(again, "an acknowledgement is consumed once, so the cache cannot grow")
    }

    func testAwaitingAnAcknowledgementThatNeverArrivesReportsUnknownRatherThanHanging() async throws {
        let executable = directory.appendingPathComponent("silent-pi")
        try """
        #!/bin/sh
        /bin/sleep 10
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let session = try PiRPCSession.start(
            cwd: directory, sessionPath: nil, piExecutable: executable, environment: ProcessInfo.processInfo.environment
        )
        defer { session.stop() }

        let id = try session.send(type: "steer", payload: ["message": .string("x")])
        let response = await session.awaitCachedResponse(id: id, timeout: 0.3)
        XCTAssertNil(response, "callers treat this as outcome-unknown, never as \"not delivered\"")
    }
}

private final class LargeWritebackAdapter: AgentProtocolAdapter, AdapterWriteback {
    let agent = AgentKind.pi
    private var pending: [Data] = []

    func launchArguments(sessionPath: URL?, cwd: URL) -> [String] { [] }
    func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        .write([AdapterEncoding.line(.object(["type": .string(command), "id": .string(id)]))])
    }
    func encodeUncorrelated(_ value: PiJSONValue) -> [Data] { [AdapterEncoding.line(value)] }
    func decode(line: Data) -> [AdapterInbound] {
        pending = [Data(repeating: 0x41, count: 2 * 1_024 * 1_024)]
        return [.event(AdapterEncoding.event("trigger"))]
    }
    func drainPendingWrites() -> [Data] {
        defer { pending.removeAll() }
        return pending
    }
    func reset() { pending.removeAll() }
}

private final class AcceptedWithoutWriteAdapter: AgentProtocolAdapter {
    let agent = AgentKind.codex
    func launchArguments(sessionPath: URL?, cwd: URL) -> [String] { [] }
    func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        .unsupported(command)
    }
    func encodeUncorrelated(_ value: PiJSONValue) -> [Data] { [] }
    func encodeUncorrelatedWithDisposition(
        _ value: PiJSONValue
    ) -> AdapterUncorrelatedOutbound {
        .acceptedWithoutWrite
    }
    func decode(line: Data) -> [AdapterInbound] { [] }
}

private final class CausalWritebackAdapter: AgentProtocolAdapter, AdapterWriteback {
    let agent = AgentKind.codex
    let decodeEntered = DispatchSemaphore(value: 0)
    let releaseDecode = DispatchSemaphore(value: 0)
    private var pending: [Data] = []

    func launchArguments(sessionPath: URL?, cwd: URL) -> [String] { [] }
    func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
        .write([AdapterEncoding.line(.object([
            "kind": .string(command), "id": .string(id)
        ]))])
    }
    func encodeUncorrelated(_ value: PiJSONValue) -> [Data] { [] }
    func decode(line: Data) -> [AdapterInbound] {
        decodeEntered.signal()
        _ = releaseDecode.wait(timeout: .now() + 3)
        pending = [AdapterEncoding.line(.object(["kind": .string("writeback")]))]
        return [.event(AdapterEncoding.event("trigger"))]
    }
    func drainPendingWrites() -> [Data] {
        defer { pending.removeAll() }
        return pending
    }
    func reset() { pending.removeAll() }
}

private final class LargeResponseAdapter: AgentProtocolAdapter {
    let agent = AgentKind.pi
    private let payload = String(repeating: "x", count: 9 * 1_024 * 1_024)

    func launchArguments(sessionPath: URL?, cwd: URL) -> [String] { [] }
    func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound { .unsupported(command) }
    func encodeUncorrelated(_ value: PiJSONValue) -> [Data] { [] }
    func decode(line: Data) -> [AdapterInbound] {
        guard let marker = try? PiJSONValue.decode(line), let id = marker["id"]?.stringValue else { return [] }
        return [.response(id: id, value: .object([
            "type": .string("response"),
            "id": .string(id),
            "data": .object(["blob": .string(payload)])
        ]))]
    }
}

/// A pipe write blocks once the kernel buffer fills, which is exactly what a wedged `pi` looks
/// like. Unbounded, that pins whichever task issued the write — a steer arriving over HTTP would
/// hold an HTTP handler and the session's write lock until the process was killed. These tests use
/// a child that reads nothing at all; no provider is ever contacted.
final class BlockingPipeWriteTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        // `pi-deskd`'s own `main.swift` does this at startup: writing to a pipe whose reader has
        // gone must surface as EPIPE on the write, not kill the process. The test binary has no
        // such startup, so it opts in here.
        signal(SIGPIPE, SIG_IGN)
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Sleeps without ever reading stdin, so the pipe buffer fills and stays full.
    private func makeDeafPi() throws -> URL {
        let executable = directory.appendingPathComponent("deaf-pi")
        try """
        #!/bin/sh
        /bin/sleep 30
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testAWriteToAChildThatNeverReadsFailsWithinItsTimeoutInsteadOfHanging() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        // Far more than any pipe buffer, so the write cannot complete without a reader.
        let payload = Data(repeating: 0x41, count: 8 * 1_024 * 1_024)
        let started = Date()
        XCTAssertThrowsError(try BlockingPipeIO.writeAll(fd: fd, data: payload, timeoutSeconds: 0.4)) { error in
            guard case BlockingPipeIOError.timedOut = error else {
                return XCTFail("expected a bounded timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the whole point is that it returns")
    }

    func testAWriteToAClosedReaderFailsImmediatelyRatherThanWaitingOutTheTimeout() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        try pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }

        let started = Date()
        XCTAssertThrowsError(try BlockingPipeIO.writeAll(fd: fd, data: Data(repeating: 0x41, count: 8 * 1_024 * 1_024), timeoutSeconds: 30))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "EPIPE is known immediately; no need to wait it out")
    }

    func testAnOrdinaryWriteStillSucceeds() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try BlockingPipeIO.writeAll(fd: pipe.fileHandleForWriting.fileDescriptor, data: Data("hello\n".utf8), timeoutSeconds: 5)
        XCTAssertEqual(pipe.fileHandleForReading.availableData, Data("hello\n".utf8))
    }

    func testASessionWhoseChildNeverReadsFailsItsSendAndThenRefusesFurtherWrites() async throws {
        let session = try PiRPCSession.start(
            cwd: directory, sessionPath: nil, piExecutable: try makeDeafPi(),
            environment: ProcessInfo.processInfo.environment, writeTimeout: 0.4
        )
        defer { session.stop() }

        // Fill the pipe. One of these writes will exhaust the buffer and hit the bound.
        let huge = String(repeating: "x", count: 256 * 1_024)
        var failure: Error?
        for _ in 0..<64 where failure == nil {
            do {
                _ = try session.send(type: "prompt", payload: ["message": .string(huge)])
            } catch {
                failure = error
            }
        }
        let thrown = try XCTUnwrap(failure, "a child that never reads must eventually fail a write")
        guard let runnerError = thrown as? RunnerError else {
            return XCTFail("expected RunnerError, got \(thrown)")
        }
        guard case .ioFailure = runnerError else {
            return XCTFail("expected an I/O failure, got \(runnerError)")
        }

        // The stream now holds a partial record that no later write can repair.
        XCTAssertThrowsError(try session.send(type: "get_state"), "later writes must fail fast, not append to a torn command")
    }
}
