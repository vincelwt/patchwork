import PiDeskKit
import XCTest
@testable import PiDesktop

/// Liveness is read from a raw file tail, so it has to understand each agent's records. Before
/// this, a Codex thread's tail was unreadable: it fell through to the age windows alone and the
/// sidebar flipped between running and done on every write.
final class CodexActivityClassificationTests: XCTestCase {
    private var root: URL!
    private var codexRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-activity-\(UUID().uuidString)", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        setenv("PI_DESKTOP_CODEX_SESSION_DIR", codexRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PI_DESKTOP_CODEX_SESSION_DIR")
        try? FileManager.default.removeItem(at: root)
    }

    private func tail(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private var codex: AgentSessionTranscoder { .make(for: .codex) }

    /// Codex writes token counts and world state constantly; the last renderable record can sit
    /// well beyond the previous four-line lookback.
    func testTheLastMeaningfulEntryIsFoundBehindBookkeepingNoise() throws {
        var lines = [#"{"type":"response_item","payload":{"type":"function_call","name":"exec","call_id":"c1","arguments":"{}"}}"#]
        for _ in 0..<30 {
            lines.append(#"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#)
            lines.append(#"{"type":"world_state","payload":{"full":true}}"#)
        }
        let entry = try XCTUnwrap(SessionActivityClassifier.lastEntry(inTail: tail(lines), transcoder: codex))
        XCTAssertEqual(entry["type"]?.stringValue, "message")
        XCTAssertEqual(entry["message"]?["stopReason"]?.stringValue, "toolUse")
    }

    /// A tool call means the turn continues, whatever the age window says.
    func testAToolCallTailClassifiesAsRunningPastTheRecentWriteWindow() {
        let lines = [#"{"type":"response_item","payload":{"type":"function_call","name":"exec","call_id":"c1","arguments":"{}"}}"#]
        let entry = SessionActivityClassifier.lastEntry(inTail: tail(lines), transcoder: codex)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: entry, age: 10), .running)
    }

    /// Commentary is not the answer, so a turn still in progress must not settle.
    func testMidTurnCommentaryDoesNotSettleTheTurn() {
        let lines = ["""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary",\
        "content":[{"type":"output_text","text":"I'll check the logs next"}]}}
        """]
        let entry = SessionActivityClassifier.lastEntry(inTail: tail(lines), transcoder: codex)
        XCTAssertNotEqual(SessionActivityClassifier.classify(lastEntry: entry, age: 2), .idle)
        XCTAssertNil(
            SessionParser.latestTerminalAssistantCompletion(inTail: tail(lines), transcoder: codex),
            "commentary is not a completed answer"
        )
    }

    func testTheFinalAnswerSettlesTheTurnEvenOnAFreshWrite() throws {
        let lines = ["""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer",\
        "content":[{"type":"output_text","text":"Done."}]}}
        """]
        let entry = SessionActivityClassifier.lastEntry(inTail: tail(lines), transcoder: codex)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: entry, age: 1), .idle)
        let completion = try XCTUnwrap(
            SessionParser.latestTerminalAssistantCompletion(inTail: tail(lines), transcoder: codex)
        )
        XCTAssertEqual(completion.stopReason, "stop")
    }

    /// A real file goes through the path-derived transcoder, which is the piece that was missing.
    func testClassifyFilePicksTheTranscoderFromThePath() throws {
        let file = codexRoot.appendingPathComponent("2026/07/31/rollout-2026-07-31T00-00-00-abc.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try tail(["""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer",\
        "content":[{"type":"output_text","text":"Done."}]}}
        """]).write(to: file)

        let activity = try XCTUnwrap(SessionActivityClassifier.classifyFile(at: file))
        XCTAssertEqual(activity.state, .idle, "a settled Codex turn must not read as running")
        XCTAssertEqual(activity.lastStopReason, "stop")
    }

    /// Pi's own tails must classify exactly as before.
    func testPiTailsAreUnaffected() {
        let lines = [#"{"type":"message","id":"m1","message":{"role":"assistant","stopReason":"stop","content":[]}}"#]
        let entry = SessionActivityClassifier.lastEntry(inTail: tail(lines))
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: entry, age: 1), .idle)
    }
}

/// The composer ladder means "weakest to strongest". Pi declares that ladder; Codex and Claude
/// Code do not have one, but their model list is the same gesture.
final class AgentLadderTests: XCTestCase {
    func testPiUsesItsDeclaredModeLadder() {
        XCTAssertEqual(AgentKind.pi.capabilities.ladder, .modes)
        XCTAssertEqual(AgentKind.pi.capabilities.modes.map(\.id), ["xfast", "fast", "smart", "ultra"])
    }

    func testTheOtherAgentsDriveTheirModelList() {
        XCTAssertEqual(AgentKind.codex.capabilities.ladder, .models)
        XCTAssertEqual(AgentKind.claude.capabilities.ladder, .models)
        XCTAssertEqual(AgentKind.codex.capabilities.modeControlTitle, "Model")
    }
}
