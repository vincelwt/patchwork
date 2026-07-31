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

    private func blocks(of record: [String: Any]?) -> [[String: Any]] {
        ((record?["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    /// Every one of these was observed as a real `user`-role turn in this machine's rollouts.
    /// They are Codex's scaffolding, not the user talking, so they become a titled card rather
    /// than pages of markup in the middle of the conversation.
    func testScaffoldingBecomesACardRatherThanProse() {
        for (injected, title) in [
            ("<recommended_plugins>\nHere is a list of plugins available.\n</recommended_plugins>", "Recommended plugins"),
            ("<environment_context>\n  <current_date>2026-07-31</current_date>\n</environment_context>", "Environment"),
            ("# AGENTS.md instructions for /Users/x/project\n\nDo the thing.", "Project instructions"),
            ("## Code review guidelines:\nYou are acting as a reviewer", "Review guidelines")
        ] {
            let rendered = blocks(of: transcode(userMessage(injected)))
            XCTAssertEqual(rendered.count, 1, "expected one card for \(title)")
            XCTAssertEqual(rendered.first?["type"] as? String, "note")
            XCTAssertEqual(rendered.first?["title"] as? String, title)
            XCTAssertFalse((rendered.first?["symbol"] as? String ?? "").isEmpty)
        }
    }

    /// A card carries no prose, so it cannot become the conversation's name — which is how every
    /// Codex thread ended up called after the plugin catalogue.
    func testACardContributesNoTextForNaming() {
        let rendered = blocks(of: transcode(userMessage("<recommended_plugins>\nplugins\n</recommended_plugins>")))
        XCTAssertNil(rendered.first?["text"])
    }

    /// Memory citations trail a real answer; the answer must stay prose and the citation must not.
    func testMemoryCitationIsSplitOutOfAnAnswer() {
        let record = transcode("""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer",\
        "content":[{"type":"output_text","text":"Done, the branch is merged.\\n\\n\
        <oai-mem-citation>\\n<citation_entries>\\nMEMORY.md:25-28|note=[x]\\n</citation_entries>\\n</oai-mem-citation>"}]}}
        """)
        let rendered = blocks(of: record)
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered.first?["type"] as? String, "text")
        XCTAssertEqual(rendered.first?["text"] as? String, "Done, the branch is merged.")
        XCTAssertEqual(rendered.last?["type"] as? String, "note")
        XCTAssertEqual(rendered.last?["title"] as? String, "Memory")
    }

    /// An automation's trigger is a card, but its instructions stay readable inside it.
    func testHeartbeatBecomesAnAutomationCardKeepingItsInstructions() {
        let rendered = blocks(of: transcode(userMessage(
            "<heartbeat>\n<automation_id>verify-live</automation_id>\n<instructions>\nCheck the thing.\n</instructions>\n</heartbeat>"
        )))
        XCTAssertEqual(rendered.first?["title"] as? String, "Automation trigger")
        XCTAssertTrue((rendered.first?["body"] as? String ?? "").contains("Check the thing."))
    }

    /// An unterminated tag is prose, not an excuse to swallow the rest of the message.
    func testAnUnterminatedTagStaysProse() {
        let rendered = blocks(of: transcode(userMessage("<environment_context> never closed, and then real words")))
        XCTAssertEqual(rendered.first?["type"] as? String, "text")
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

    /// The attachment list survives as a card even when the request body is empty.
    func testAWrapperWithNoRequestBodyKeepsOnlyItsAttachmentCard() {
        let rendered = blocks(of: transcode(userMessage(
            "# Files mentioned by the user:\n\n## a.png: /tmp/a.png\n\n## My request for Codex:\n   "
        )))
        XCTAssertEqual(rendered.count, 1)
        XCTAssertEqual(rendered.first?["title"] as? String, "Attachments")
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

/// Claude Code's transcript is an append-only log, not one parent chain: compaction and resume
/// leave parents pointing at records the file no longer contains. Walking back from the leaf
/// found 13 of 1,897 real records on this machine, so a conversation rendered as a stub.
final class ClaudeTranscriptShapeTests: XCTestCase {
    func testClaudeIsReadInFileOrder() {
        XCTAssertEqual(AgentSessionTranscoder.make(for: .claude).chain, .linear)
    }

    /// Pi does keep a real chain, and its branch selection must not change.
    func testPiStillFollowsItsParentChain() {
        XCTAssertEqual(AgentSessionTranscoder.make(for: .pi).chain, .parentPointer)
    }

    /// The parent pointers are still emitted, so nothing is lost if the chain is ever usable.
    func testParentPointersAreStillRecorded() throws {
        let transcoder = AgentSessionTranscoder.make(for: .claude)
        let line = #"{"type":"assistant","uuid":"u2","parentUuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
        let out = try XCTUnwrap(transcoder.transcode(Data(line.utf8)))
        let record = try XCTUnwrap((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])
        XCTAssertEqual(record["parentId"] as? String, "u1")
    }
}
