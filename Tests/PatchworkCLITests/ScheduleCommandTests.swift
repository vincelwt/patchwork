import XCTest
@testable import PatchworkCLI

final class ScheduleAddTests: XCTestCase {
    func testRequiresName() async {
        let result = await runCLI(["schedule", "add", "--cwd", ".", "--prompt", "p", "--every", "15m"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--name"))
    }

    func testRequiresPrompt() async {
        let result = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--every", "15m"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testRequiresThreadOrCwd() async {
        let result = await runCLI(["schedule", "add", "--name", "n", "--prompt", "p", "--every", "15m"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--thread") || result.stderr.contains("--cwd"))
    }

    func testThreadAndCwdTogetherIsRejected() async {
        let result = await runCLI(["schedule", "add", "--name", "n", "--prompt", "p", "--thread", "t1", "--cwd", ".", "--every", "15m"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testExistingThreadTarget() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["schedule", "add", "--name", "Keep-alive", "--thread", "t1", "--prompt", "ping", "--heartbeat", "15m"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.target.kind, "existingThread")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.target.threadId, "t1")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.trigger.kind, "heartbeat")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.trigger.everySeconds, 900)
        XCTAssertTrue((16...64).contains(plane.lastScheduleCreateRequest?.idempotencyKey?.utf8.count ?? 0))
    }

    func testExplicitScheduleCreationIDIsPassedThroughAndInvalidIDsAreRejected() async {
        let plane = FakeControlPlane()
        let stableID = "schedule-create-001"
        let result = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p",
            "--every", "15m", "--client-id", stableID
        ], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.idempotencyKey, stableID)

        let invalid = FakeControlPlane()
        let invalidResult = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p",
            "--every", "15m", "--client-id", "short"
        ], controlPlane: invalid)
        XCTAssertEqual(invalidResult.exitCode, 2)
        XCTAssertNil(invalid.lastScheduleCreateRequest)
    }

    func testTriggerModifiersRequireTheirMatchingTrigger() async {
        let timezone = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p",
            "--every", "15m", "--timezone", "UTC"
        ])
        XCTAssertEqual(timezone.exitCode, 2)
        XCTAssertTrue(timezone.stderr.contains("--cron"))

        let start = await runCLI([
            "schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p",
            "--heartbeat", "15m", "--start-at", "2026-08-02T10:00"
        ])
        XCTAssertEqual(start.exitCode, 2)
        XCTAssertTrue(start.stderr.contains("--every"))
    }

    func testNewThreadTargetDefaultsNamePatternToName() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["schedule", "add", "--name", "Morning triage", "--cwd", "/code", "--prompt", "p", "--cron", "0 9 * * 1-5"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.target.kind, "newThread")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.target.cwd, "/code")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.target.namePattern, "Morning triage")
    }

    func testExplicitNamePatternOverridesDefault() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["schedule", "add", "--name", "Triage", "--cwd", "/code", "--prompt", "p", "--cron", "0 9 * * 1-5", "--name-pattern", "Triage {date}"], controlPlane: plane)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.target.namePattern, "Triage {date}")
    }

    func testCronExpressionAndTimezonePassThrough() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--cron", "0 9 * * 1-5", "--timezone", "Europe/Paris"], controlPlane: plane)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.trigger.expression, "0 9 * * 1-5")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.trigger.timeZone, "Europe/Paris")
    }

    func testAtProducesOnceTrigger() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--at", "2026-07-27T09:00:00Z"], controlPlane: plane)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.trigger.kind, "once")
        XCTAssertEqual(plane.lastScheduleCreateRequest?.trigger.at, "2026-07-27T09:00:00Z")
    }

    func testSkipIfRunningAndTimeoutBuildPolicy() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--every", "15m", "--skip-if-running", "--timeout", "30m"], controlPlane: plane)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.policy?.skipIfRunning, true)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.policy?.timeoutSeconds, 1800)
    }

    /// The command-level `--timeout` (run policy duration) must never be mistaken for the global
    /// request-timeout flag: "30m" is not a valid number of seconds.
    func testScheduleAddTimeoutIsADurationNotARequestTimeout() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--every", "15m", "--timeout", "30m"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNoPolicyFlagsMeansNilPolicy() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--every", "15m"], controlPlane: plane)
        XCTAssertNil(plane.lastScheduleCreateRequest?.policy)
    }

    func testModeFlagPassesThrough() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--every", "15m", "--mode", "ultra"], controlPlane: plane)
        XCTAssertEqual(plane.lastScheduleCreateRequest?.mode, "ultra")
    }

    func testJSONOutputMatchesFakeResponse() async throws {
        let plane = FakeControlPlane()
        plane.scheduleCreateResult = WireScheduleResponse(schedule: WireSchedule(id: "sch_42", name: "n"))
        let result = await runCLI(["schedule", "add", "--name", "n", "--cwd", ".", "--prompt", "p", "--every", "15m", "--json"], controlPlane: plane)
        let decoded = try JSONDecoder().decode(WireScheduleResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.schedule.id, "sch_42")
    }
}

final class ScheduleOtherCommandsTests: XCTestCase {
    func testListEmptyPrintsHumanMessage() async {
        let result = await runCLI(["schedule", "list"])
        XCTAssertTrue(result.stdout.contains("No schedules."))
    }

    func testListJSONRoundTrips() async throws {
        let plane = FakeControlPlane()
        plane.scheduleListResult = WireScheduleListResponse(schedules: [WireSchedule(id: "sch_1", name: "Nightly")])
        let result = await runCLI(["schedule", "list", "--json"], controlPlane: plane)
        let decoded = try JSONDecoder().decode(WireScheduleListResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.schedules.first?.id, "sch_1")
    }

    func testShowRequiresId() async {
        let result = await runCLI(["schedule", "show"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testShowIncludesRuns() async throws {
        let plane = FakeControlPlane()
        plane.scheduleDetailResult = WireScheduleDetailResponse(
            schedule: WireSchedule(id: "sch_1", name: "Nightly"),
            runs: [WireRun(id: "run_1", status: "ok")]
        )
        let result = await runCLI(["schedule", "show", "sch_1", "--json"], controlPlane: plane)
        let decoded = try JSONDecoder().decode(WireScheduleDetailResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.runs.first?.id, "run_1")
    }

    func testPauseSendsPausedTrue() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["schedule", "pause", "sch_1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=sch_1 paused=true")
    }

    func testResumeSendsPausedFalse() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["schedule", "resume", "sch_1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=sch_1 paused=false")
    }

    func testRemoveCallsDelete() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["schedule", "remove", "sch_1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.method, "deleteSchedule")
    }

    func testRunCallsRunNow() async {
        let plane = FakeControlPlane()
        plane.scheduleRunResult = WireScheduleRunResponse(runId: "run_9")
        let result = await runCLI(["schedule", "run", "sch_1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("run_9"))
        XCTAssertFalse(plane.lastScheduleRunRequest?.clientId?.isEmpty ?? true)
    }

    func testRunPassesAnExplicitIDAndExplainsProtectedInFlightRetry() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.apiError(
            status: 409, code: "schedule_run_in_flight", message: "still admitting"
        )
        let result = await runCLI([
            "schedule", "run", "sch_1", "--client-id", "manual-run-001"
        ], controlPlane: plane)

        XCTAssertEqual(plane.lastScheduleRunRequest?.clientId, "manual-run-001")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("--client-id manual-run-001"))
    }

    func testRunWithUnprotectedUnknownOutcomeRequiresHistoryReview() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.outcomeUnknown("connection closed")
        let result = await runCLI([
            "schedule", "run", "sch_1", "--client-id", "manual-run-002"
        ], controlPlane: plane)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Review the schedule's run history"))
        XCTAssertFalse(result.stderr.contains("Retry the exact"))
    }

    func testCreateWithUnprotectedUnknownOutcomeRequiresScheduleListReview() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.outcomeUnknown("connection closed")
        let result = await runCLI([
            "schedule", "add", "--name", "Nightly", "--cwd", "/tmp/project",
            "--prompt", "work", "--every", "1h",
            "--client-id", "schedule-create-001"
        ], controlPlane: plane)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Review the schedule list"))
        XCTAssertFalse(result.stderr.contains("Review the thread"))
        XCTAssertFalse(result.stderr.contains("Retry the exact"))
    }

    func testUnknownSubcommandIsBadUsage() async {
        let result = await runCLI(["schedule", "bogus"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testGroupHelp() async {
        let result = await runCLI(["schedule", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("add"))
    }
}
