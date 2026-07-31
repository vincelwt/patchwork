import PiDeskKit
import XCTest
@testable import PiDesktop

/// Pull-request detection used to match one hardcoded shape: a tool called `bash` with a
/// `command` argument. Pi and Claude Code happen to fit it. Codex does not, in three separate
/// ways, so every Codex pull request was invisible — no toolbar link, no Open PRs bucket, no
/// review watching.
final class AgentPullRequestDetectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func summary(_ lines: [String], agent: AgentKind) throws -> SessionSummary {
        let url = root.appendingPathComponent("s-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return try SessionParser.summary(at: url, transcoder: .make(for: agent))
    }

    private let prURL = "https://github.com/acme/widgets/pull/42"

    // MARK: - Codex

    /// Codex's shell tool is `exec_command` and its command lives under `cmd`.
    func testCodexShellPullRequestIsDetected() throws {
        let result = try summary([
            #"{"type":"session_meta","payload":{"session_id":"c1","cwd":"/w"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1","arguments":"{\"cmd\":\"gh pr create --fill\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"\#(prURL)"}}"#
        ], agent: .codex)
        XCTAssertEqual(result.pullRequestURL?.absoluteString, prURL)
    }

    /// Its `exec` tool buries the shell call inside a script, so naming argument keys misses it.
    func testCodexScriptedPullRequestIsDetected() throws {
        let result = try summary([
            #"{"type":"session_meta","payload":{"session_id":"c2","cwd":"/w"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call_2","input":"const r = await tools.exec_command({cmd: \"gh pr create --fill\"});"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_2","output":[{"type":"input_text","text":"\#(prURL)"}]}}"#
        ], agent: .codex)
        XCTAssertEqual(result.pullRequestURL?.absoluteString, prURL)
    }

    /// And it can open one through MCP without any shell at all.
    func testCodexMCPPullRequestIsDetected() throws {
        let result = try summary([
            #"{"type":"session_meta","payload":{"session_id":"c3","cwd":"/w"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"_create_pull_request","call_id":"call_3","arguments":"{\"base\":\"main\",\"head\":\"feat/x\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_3","output":"{\"url\":\"\#(prURL)\"}"}}"#
        ], agent: .codex)
        XCTAssertEqual(result.pullRequestURL?.absoluteString, prURL)
    }

    /// An ordinary Codex shell call must not be mistaken for one.
    func testAnUnrelatedCodexCommandIsNotAPullRequest() throws {
        let result = try summary([
            #"{"type":"session_meta","payload":{"session_id":"c4","cwd":"/w"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_4","arguments":"{\"cmd\":\"gh pr list\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_4","output":"\#(prURL)"}}"#
        ], agent: .codex)
        XCTAssertNil(result.pullRequestURL)
    }

    // MARK: - Claude and Pi

    func testClaudeBashPullRequestIsStillDetected() throws {
        let result = try summary([
            #"{"type":"assistant","uuid":"a1","cwd":"/w","sessionId":"cl1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"gh pr create --fill"}}]}}"#,
            #"{"type":"user","uuid":"a2","parentUuid":"a1","cwd":"/w","sessionId":"cl1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"\#(prURL)"}]}}"#
        ], agent: .claude)
        XCTAssertEqual(result.pullRequestURL?.absoluteString, prURL)
    }

    func testPiIsUnchanged() throws {
        let result = try summary([
            #"{"type":"session","id":"p1","cwd":"/w"}"#,
            #"{"type":"message","id":"m1","message":{"role":"assistant","content":[{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"gh pr create --fill"}}]}}"#,
            #"{"type":"message","id":"m2","parentId":"m1","message":{"role":"toolResult","toolCallId":"t1","content":[{"type":"text","text":"\#(prURL)"}]}}"#
        ], agent: .pi)
        XCTAssertEqual(result.pullRequestURL?.absoluteString, prURL)
    }

    /// Pi has no MCP pull-request tool, so nothing new is matched for it.
    func testToolShapesAreAgentSpecific() {
        XCTAssertTrue(AgentKind.pi.toolShapes.isShellTool("bash"))
        XCTAssertFalse(AgentKind.pi.toolShapes.opensPullRequest("_create_pull_request"))
        XCTAssertTrue(AgentKind.codex.toolShapes.isShellTool("exec_command"))
        XCTAssertTrue(AgentKind.codex.toolShapes.opensPullRequest("mcp__github___create_pull_request"))
        XCTAssertTrue(AgentKind.claude.toolShapes.isShellTool("Bash"))
    }
}
