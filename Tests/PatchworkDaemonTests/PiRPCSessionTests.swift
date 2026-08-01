import XCTest
import PatchworkKit
@testable import PatchworkDaemon

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

        let event = try await session.receiveNext(timeout: 1)
        XCTAssertEqual(event?["type"]?.stringValue, "extension_ui_request")
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

/// A pipe write blocks once the kernel buffer fills, which is exactly what a wedged `pi` looks
/// like. Unbounded, that pins whichever task issued the write — a steer arriving over HTTP would
/// hold an HTTP handler and the session's write lock until the process was killed. These tests use
/// a child that reads nothing at all; no provider is ever contacted.
final class BlockingPipeWriteTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        // `patchworkd`'s own `main.swift` does this at startup: writing to a pipe whose reader has
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
            guard case let RunnerError.ioFailure(message) = error else { return XCTFail("expected an I/O failure, got \(error)") }
            XCTAssertTrue(message.contains("did not accept input"), message)
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
        XCTAssertTrue("\(thrown)".contains("did not accept input"), "\(thrown)")

        // The stream now holds a partial record that no later write can repair.
        XCTAssertThrowsError(try session.send(type: "get_state"), "later writes must fail fast, not append to a torn command")
    }
}
