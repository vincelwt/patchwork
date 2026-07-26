import XCTest
@testable import PiDeskCLI

final class ThreadsListShowTests: XCTestCase {
    func testListDefaultsToLimitFiftyAndNoFilters() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "list"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "query= limit=50 cursor= archived=nil running=nil")
    }

    func testListPassesThroughFilters() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "list", "--query", "triage", "--running", "--archived", "--limit", "5", "--cursor", "abc"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "query=triage limit=5 cursor=abc archived=Optional(true) running=Optional(true)")
    }

    func testListRejectsInvalidLimit() async {
        let result = await runCLI(["threads", "list", "--limit", "0"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--limit"))
    }

    func testListEmptyPrintsHumanMessage() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [], nextCursor: nil)
        let result = await runCLI(["threads", "list"], controlPlane: plane)
        XCTAssertTrue(result.stdout.contains("No threads."))
    }

    func testListJSONShapeRoundTrips() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(
            threads: [WireThread(id: "t1", path: "/p", name: "Nightly", cwd: "/code", folder: "code", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z", running: true, unread: false, archived: false, preview: "hi", cost: 1.5, contextPercent: 40)],
            nextCursor: "cur1"
        )
        let result = await runCLI(["threads", "list", "--json"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        let decoded = try? JSONDecoder().decode(WireThreadListResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded, plane.threadListResult)
        // Stable key set: exact keys, sorted, nothing extra.
        XCTAssertTrue(result.stdout.contains("\"nextCursor\""))
        XCTAssertTrue(result.stdout.contains("\"threads\""))
    }

    func testListHumanTableShowsCursorHint() async {
        // Progress/hint text is incidental, not data — it goes to stderr so stdout stays clean
        // for piping, and disappears entirely under --quiet.
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A")], nextCursor: "cur1")
        let result = await runCLI(["threads", "list"], controlPlane: plane)
        XCTAssertTrue(result.stderr.contains("--cursor cur1"))
        XCTAssertFalse(result.stdout.contains("--cursor"))
    }

    func testListHumanTableCursorHintSuppressedByQuiet() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(threads: [WireThread(id: "t1", name: "A")], nextCursor: "cur1")
        let result = await runCLI(["threads", "list", "--quiet"], controlPlane: plane)
        XCTAssertFalse(result.stderr.contains("--cursor"))
    }

    func testShowRequiresId() async {
        let result = await runCLI(["threads", "show"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("<id>"))
    }

    func testShowDefaultsToTwentyMessages() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "show", "t1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=t1 messages=20")
    }

    func testShowRespectsMessagesFlag() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["threads", "show", "t1", "--messages", "3"], controlPlane: plane)
        XCTAssertEqual(plane.calls.first?.detail, "id=t1 messages=3")
    }

    func testShowJSONMatchesFakeResponse() async {
        let plane = FakeControlPlane()
        plane.threadDetailResult = WireThreadDetailResponse(
            thread: WireThread(id: "t1", name: "Nightly"),
            messages: [WireMessage(id: "m1", role: "user", text: "hi", at: "2026-01-01T00:00:00Z", isError: false)]
        )
        let result = await runCLI(["threads", "show", "t1", "--json"], controlPlane: plane)
        let decoded = try? JSONDecoder().decode(WireThreadDetailResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded, plane.threadDetailResult)
    }

    func testUnreachableDaemonExitsThree() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.unreachable("connection refused")
        let result = await runCLI(["threads", "list"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("cannot reach"))
        XCTAssertTrue(result.stderr.lowercased().contains("daemon start"))
    }

    func testApiErrorExitsOne() async {
        let plane = FakeControlPlane()
        plane.error = ControlPlaneError.apiError(status: 404, code: "not_found", message: "no such thread")
        let result = await runCLI(["threads", "show", "t1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("not_found"))
    }
}

final class ThreadsNewTests: XCTestCase {
    func testRequiresCwd() async {
        let result = await runCLI(["threads", "new"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--cwd"))
    }

    func testCreatesIdleThreadWithoutMessage() async {
        let plane = FakeControlPlane()
        plane.createThreadResult = WireCreateThreadResponse(thread: WireThread(id: "t1", name: "New"), runId: nil)
        let result = await runCLI(["threads", "new", "--cwd", "/code"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastCreateThreadRequest?.cwd, "/code")
        XCTAssertNil(plane.lastCreateThreadRequest?.message)
        XCTAssertFalse(result.stdout.contains("Run started"))
    }

    func testCreatesWithMessageAndMode() async {
        let plane = FakeControlPlane()
        plane.createThreadResult = WireCreateThreadResponse(thread: WireThread(id: "t1"), runId: "run_1")
        let result = await runCLI(["threads", "new", "--cwd", "/code", "--message", "survey", "--mode", "ultra"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastCreateThreadRequest?.message, "survey")
        XCTAssertEqual(plane.lastCreateThreadRequest?.mode, "ultra")
        XCTAssertTrue(result.stderr.contains("run_1")) // "Run started: ..." is incidental, not the primary result line
    }

    func testMessageDashReadsStdin() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "new", "--cwd", "/code", "--message", "-"], controlPlane: plane, stdin: Data("piped message\n".utf8))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastCreateThreadRequest?.message, "piped message")
    }

    func testJSONOutputIncludesRunIdWhenPresent() async {
        let plane = FakeControlPlane()
        plane.createThreadResult = WireCreateThreadResponse(thread: WireThread(id: "t1"), runId: "run_9")
        let result = await runCLI(["threads", "new", "--cwd", "/code", "--message", "hi", "--json"], controlPlane: plane)
        let decoded = try? JSONDecoder().decode(WireCreateThreadResponse.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded?.runId, "run_9")
    }
}

final class ThreadsMutationTests: XCTestCase {
    func testAbortCallsPlaneAndPrintsResult() async {
        let plane = FakeControlPlane()
        plane.abortResult = WireAbortResponse(aborted: true)
        let result = await runCLI(["threads", "abort", "t1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=t1")
        XCTAssertTrue(result.stdout.contains("Aborted t1"))
    }

    func testArchiveSendsArchivedTrue() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "archive", "t1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=t1 archived=true")
    }

    func testUnarchiveSendsArchivedFalse() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "unarchive", "t1"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=t1 archived=false")
    }

    func testRenameRequiresBothPositionals() async {
        let result = await runCLI(["threads", "rename", "t1"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testRenamePassesNewName() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "rename", "t1", "New Name"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.calls.first?.detail, "id=t1 name=New Name")
    }

    func testTooManyPositionalsIsBadUsage() async {
        let result = await runCLI(["threads", "rename", "t1", "a", "b"])
        XCTAssertEqual(result.exitCode, 2)
    }
}

final class ThreadsHelpTests: XCTestCase {
    func testGroupHelpListsSubcommands() async {
        let result = await runCLI(["threads", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("list"))
        XCTAssertTrue(result.stdout.contains("watch"))
    }

    func testNoSubcommandIsBadUsage() async {
        let result = await runCLI(["threads"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testUnknownSubcommandIsBadUsage() async {
        let result = await runCLI(["threads", "bogus"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("bogus"))
    }

    func testLeafHelpShowsUsageAndExamples() async {
        let result = await runCLI(["threads", "send", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage:"))
        XCTAssertTrue(result.stdout.contains("Examples:"))
        XCTAssertTrue(result.stdout.contains("--wait"))
    }

    func testHelpWorksEvenWithMissingRequiredArgs() async {
        // --help must short-circuit before "missing --cwd" would otherwise fire.
        let result = await runCLI(["threads", "new", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stderr.contains("missing"))
    }
}
