import XCTest
@testable import PiDeskCLI

/// `pidesk` carrying an agent end to end: filtering the list, choosing one for a new thread, and
/// showing it in the table without ever contacting a daemon.
final class ThreadsAgentTests: XCTestCase {
    private func thread(_ id: String, agent: String?) -> WireThread {
        WireThread(
            id: id, path: "/tmp/\(id).jsonl", name: "Thread \(id)", cwd: "/code", folder: "code",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z",
            running: false, unread: false, archived: false, preview: "hi", agent: agent
        )
    }

    func testListPassesTheAgentFilterThrough() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "list", "--agent", "codex"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            plane.calls.first?.detail,
            "query= limit=20 cursor= archived=Optional(false) running=nil automated=nil agent=codex"
        )
    }

    func testListNormalisesAgentCase() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["threads", "list", "--agent", "Claude"], controlPlane: plane)
        XCTAssertTrue(plane.calls.first?.detail.hasSuffix("agent=claude") == true)
    }

    func testListRejectsAnUnknownAgentBeforeAnyRequest() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "list", "--agent", "gemini"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--agent"))
        XCTAssertTrue(plane.calls.isEmpty, "an invalid flag must not cost a round trip")
    }

    func testNewPassesTheChosenAgent() async {
        let plane = FakeControlPlane()
        let result = await runCLI(["threads", "new", "--cwd", "/code", "--agent", "codex"], controlPlane: plane)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(plane.lastCreateThreadRequest?.agent, "codex")
    }

    func testNewWithoutAnAgentSendsNoneSoTheDaemonKeepsItsDefault() async {
        let plane = FakeControlPlane()
        _ = await runCLI(["threads", "new", "--cwd", "/code"], controlPlane: plane)
        XCTAssertNil(plane.lastCreateThreadRequest?.agent)
    }

    func testListTableShowsAnAgentColumn() async {
        let plane = FakeControlPlane()
        plane.threadListResult = WireThreadListResponse(
            threads: [thread("t1", agent: "codex"), thread("t2", agent: nil)], nextCursor: nil
        )
        let result = await runCLI(["threads", "list"], controlPlane: plane)
        XCTAssertTrue(result.stdout.contains("AGENT"))
        XCTAssertTrue(result.stdout.contains("codex"))
        XCTAssertTrue(result.stdout.contains("pi"))
    }

    func testShowPrintsTheAgent() async {
        let plane = FakeControlPlane()
        plane.threadDetailResult = WireThreadDetailResponse(thread: thread("t1", agent: "claude"), messages: [])
        let result = await runCLI(["threads", "show", "t1"], controlPlane: plane)
        XCTAssertTrue(result.stdout.contains("agent: claude"))
    }

    /// An agent this CLI predates still has to appear in the table rather than being blanked out
    /// or silently relabelled as Pi.
    func testUnknownAgentFromANewerDaemonIsShownVerbatim() {
        XCTAssertEqual(Rendering.threadAgent(thread("t1", agent: "gemini")), "gemini")
        XCTAssertEqual(Rendering.threadAgent(thread("t2", agent: nil)), "pi")
        XCTAssertEqual(Rendering.threadAgent(thread("t3", agent: "")), "pi")
    }

    func testUnknownAgentLabelStaysBounded() {
        let long = String(repeating: "z", count: 400)
        // The shared `truncated` helper keeps 12 characters and adds its own ellipsis.
        XCTAssertEqual(Rendering.threadAgent(thread("t1", agent: long)), truncated(long, max: 12))
        XCTAssertLessThanOrEqual(Rendering.threadAgent(thread("t1", agent: long)).count, 13)
    }
}
