import XCTest
@testable import PiDeskDaemon

final class AutomationDeliveryTests: XCTestCase {
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

    func testOnlyDefinitePrePromptTransportFailuresAreRetryable() {
        XCTAssertFalse(RunnerError.piNotFound.retryableBeforePrompt)
        XCTAssertTrue(RunnerError.timedOut(afterSeconds: 1).retryableBeforePrompt)
        XCTAssertTrue(RunnerError.processExited("gone").retryableBeforePrompt)
        XCTAssertTrue(RunnerError.ioFailure("pipe").retryableBeforePrompt)
    }
}
