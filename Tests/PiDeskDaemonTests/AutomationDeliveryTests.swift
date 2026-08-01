import XCTest
@testable import PiDeskDaemon

final class AutomationDeliveryTests: XCTestCase {
    func testModeCommandIsOnlyASeparatePiPrompt() {
        XCTAssertEqual(PiProcessRunExecutor.piModeCommand(" ultra ", agent: .pi), "/mode ultra")
        XCTAssertNil(PiProcessRunExecutor.piModeCommand("ultra", agent: .codex))
        XCTAssertNil(PiProcessRunExecutor.piModeCommand("ultra", agent: .claude))
    }

    func testScheduledNameUsesTheOwedOccurrenceDateInUTC() throws {
        let scheduledAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-03T23:30:00Z")
        )
        let queuedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-02-05T01:00:00Z")
        )
        let job = RunJob(
            id: "dated", scheduleId: "schedule", scheduledAt: scheduledAt,
            trigger: .schedule,
            target: .newThread(cwd: "/tmp", namePattern: "Triage {date}"),
            prompt: "fixture", mode: nil, timeoutSeconds: 30, queuedAt: queuedAt
        )

        XCTAssertEqual(
            PiProcessRunExecutor.initialSessionName(for: job),
            "Triage 2026-02-03"
        )
    }

    func testPromptIsNeverWrittenWhenDurableDispatchStateCannotBeSaved() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("stdin.jsonl")
        let executable = directory.appendingPathComponent("fake-pi")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> '\(transcript.path)'
          id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
          printf '{"id":"%s","type":"response","success":true,"data":{"sessionId":"fake","sessionFile":"\(directory.path)/session.jsonl"}}\\n' "$id"
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let executor = PiProcessRunExecutor(
            logger: TestSupport.logger(in: directory), piExecutableOverride: executable
        )
        let outcome = await executor.execute(RunJob(
            id: "run-safe", scheduleId: "schedule", occurrenceId: "occurrence",
            trigger: .schedule, target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "must not be sent", mode: nil, timeoutSeconds: 30, queuedAt: Date(),
            onPromptDispatch: { _ in .retry }
        ))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.retryable)
        let requests = try String(contentsOf: transcript, encoding: .utf8)
        XCTAssertTrue(requests.contains("get_state"))
        XCTAssertFalse(requests.contains("must not be sent"))
    }

    func testMismatchedPreallocatedIdentityStopsBeforePromptDelivery() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestsURL = directory.appendingPathComponent("requests.jsonl")
        let executable = directory.appendingPathComponent("fake-pi-mismatch")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> '\(requestsURL.path)'
          id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
          printf '{"id":"%s","type":"response","success":true,"data":{"sessionId":"unexpected","sessionFile":"\(directory.path)/unexpected.jsonl"}}\\n' "$id"
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        let executor = PiProcessRunExecutor(
            logger: TestSupport.logger(in: directory), piExecutableOverride: executable
        )

        let outcome = await executor.execute(RunJob(
            id: "run-identity-mismatch", scheduleId: "schedule", trigger: .schedule,
            target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "must not be sent", mode: nil, timeoutSeconds: 30, queuedAt: Date(),
            initialSessionID: "expected"
        ))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.retryable)
        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
        XCTAssertTrue(requests.contains("get_state"))
        XCTAssertFalse(requests.contains("must not be sent"))
    }

    func testCommandOnlyReviewPollCompletesWithoutAgentSettled() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-pi")
        try """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
          if [ "$count" -eq 1 ]; then
            printf '{"id":"%s","type":"response","success":true,"data":{"sessionId":"fake","sessionFile":"\(directory.path)/session.jsonl"}}\\n' "$id"
          else
            printf '%s\\n' '{"type":"extension_ui_request","id":"done","method":"setStatus","statusKey":"pi-desktop-pr-review-complete"}'
            printf '{"id":"%s","type":"response","command":"prompt","success":true}\\n' "$id"
          fi
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let executor = PiProcessRunExecutor(
            logger: TestSupport.logger(in: directory), piExecutableOverride: executable
        )
        let outcome = await executor.execute(RunJob(
            id: "run-review-poll", scheduleId: "schedule", trigger: .schedule,
            target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "/pi-desktop-pr-review https://github.com/acme/widgets/pull/42 9999999999999",
            mode: nil, timeoutSeconds: 1, queuedAt: Date()
        ))

        XCTAssertEqual(outcome.status, .ok, "command-only polls must not wait for an agent turn")
    }

    func testFreshRunPublishesReadyIdentityOnceAfterPromptAcceptance() async throws {
        let directory = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-pi-ready")
        let transcript = directory.appendingPathComponent("session.jsonl")
        let header = #"{"type":"session","id":"ready-session","version":3,"timestamp":"2026-08-01T00:00:00.000Z","cwd":"/tmp"}"#
        try """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
          if [ "$count" -eq 1 ]; then
            printf '{"id":"%s","type":"response","success":true,"data":{"sessionId":"ready-session","sessionFile":"\(transcript.path)"}}\n' "$id"
          else
            printf '%s\n' '\(header)' > '\(transcript.path)'
            printf '{"id":"%s","type":"response","success":true}\n' "$id"
            printf '%s\n' '{"type":"agent_settled"}'
          fi
        done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let capture = ThreadReadyCapture()
        let executor = PiProcessRunExecutor(
            logger: TestSupport.logger(in: directory), piExecutableOverride: executable
        )

        let outcome = await executor.execute(RunJob(
            id: "run-ready", scheduleId: nil, trigger: .api,
            target: .newThread(cwd: directory.path, namePattern: nil),
            prompt: "fixture prompt", mode: nil, timeoutSeconds: 2, queuedAt: Date(),
            onThreadReady: { id, path in
                await capture.record(
                    id: id,
                    path: path,
                    transcriptExists: FileManager.default.fileExists(atPath: path)
                )
            }
        ))

        XCTAssertEqual(outcome.status, .ok)
        let values = await capture.snapshot()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.id, "ready-session")
        XCTAssertEqual(values.first?.path, transcript.path)
        XCTAssertEqual(values.first?.transcriptExists, true)
    }

    func testOnlyDefinitePrePromptTransportFailuresAreRetryable() {
        XCTAssertFalse(RunnerError.piNotFound.retryableBeforePrompt)
        XCTAssertTrue(RunnerError.timedOut(afterSeconds: 1).retryableBeforePrompt)
        XCTAssertTrue(RunnerError.processExited("gone").retryableBeforePrompt)
        XCTAssertTrue(RunnerError.ioFailure("pipe").retryableBeforePrompt)
    }
}

private actor ThreadReadyCapture {
    struct Value {
        let id: String
        let path: String
        let transcriptExists: Bool
    }

    private var values: [Value] = []

    func record(id: String, path: String, transcriptExists: Bool) {
        values.append(Value(id: id, path: path, transcriptExists: transcriptExists))
    }

    func snapshot() -> [Value] { values }
}
