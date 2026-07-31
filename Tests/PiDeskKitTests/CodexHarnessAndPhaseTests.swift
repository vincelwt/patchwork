import XCTest
@testable import PiDeskKit

/// Codex delivers scaffolding as user turns and narrates continuously while it works. Both were
/// being taken at face value: every thread was named after the plugin catalogue, and every
/// mid-turn remark looked like a finished answer.
final class CodexHarnessAndPhaseTests: XCTestCase {
    private let transcoder = AgentSessionTranscoder.make(for: .codex)

    private func transcode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8), let out = transcoder.transcode(data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
    }

    private func userMessage(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(escaped)"}]}}"#
    }

    private func text(of record: [String: Any]?) -> String? {
        ((record?["message"] as? [String: Any])?["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.first
    }

    // MARK: - Scaffolding

    /// Every one of these was observed as a real `user`-role turn in this machine's rollouts.
    func testScaffoldingTurnsAreNotTreatedAsTheUserTalking() {
        for injected in [
            "<recommended_plugins>\nHere is a list of plugins that are available but not installed.\n\n- Atlassian Rovo",
            "<environment_context>\n  <current_date>2026-07-31</current_date>\n</environment_context>",
            "# AGENTS.md instructions for /Users/x/project\n\n<INSTRUCTIONS>\nDo the thing.\n</INSTRUCTIONS>",
            "## Code review guidelines:\n# Review Guidelines\n\nYou are acting as a reviewer"
        ] {
            XCTAssertNil(transcode(userMessage(injected)), "expected scaffolding to be dropped: \(injected.prefix(30))")
        }
    }

    func testARealUserTurnIsKept() {
        XCTAssertEqual(text(of: transcode(userMessage("did you find anything in the podcast logs?"))),
                       "did you find anything in the podcast logs?")
    }

    /// The attachment wrapper contains the real request; dropping the whole turn would lose it,
    /// and keeping it whole put the file list in the conversation's name.
    func testAnAttachmentWrapperIsUnwrappedToTheRealRequest() {
        let wrapped = """
        \n# Files mentioned by the user:\n\n## codex-clipboard-ff97.png: /var/folders/T/codex-clipboard-ff97.png\n\n\
        ## My request for Codex:\nDoes the price cut in Luna become interesting for any of our tasks?
        """
        XCTAssertEqual(text(of: transcode(userMessage(wrapped))),
                       "Does the price cut in Luna become interesting for any of our tasks?")
    }

    func testAWrapperWithNoRequestBodyIsDropped() {
        XCTAssertNil(transcode(userMessage("# Files mentioned by the user:\n\n## a.png: /tmp/a.png\n\n## My request for Codex:\n   ")))
    }

    /// An attachment-only turn is a real turn even with no prose.
    func testAnImageOnlyTurnSurvives() {
        let record = transcode("""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[\
        {"type":"input_image","image_url":"data:image/png;base64,QUJD"}]}}
        """)
        let blocks = (record?["message"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.first?["type"] as? String, "image")
    }

    // MARK: - Phase

    /// Codex marks which message is the answer. Treating commentary as an answer made the
    /// sidebar flip between running and done, and stopped the transcript collapsing its work.
    func testOnlyTheFinalAnswerIsATerminalStop() {
        for (phase, expected) in [("final_answer", "stop"), ("commentary", "toolUse")] {
            let record = transcode("""
            {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"\(phase)",\
            "content":[{"type":"output_text","text":"text"}]}}
            """)
            XCTAssertEqual((record?["message"] as? [String: Any])?["stopReason"] as? String, expected,
                           "phase \(phase)")
        }
    }

    /// An older rollout with no phase must not be reported as still running forever.
    func testAMessageWithNoPhaseStillSettles() {
        let record = transcode("""
        {"type":"response_item","payload":{"type":"message","role":"assistant",\
        "content":[{"type":"output_text","text":"text"}]}}
        """)
        XCTAssertEqual((record?["message"] as? [String: Any])?["stopReason"] as? String, "toolUse")
    }
}
