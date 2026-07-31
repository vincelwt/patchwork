import XCTest
@testable import PiDeskKit

/// The transcoders are the load-bearing piece of multi-agent history: every parser, pager, and
/// cache downstream assumes it is reading Pi-shaped records, so these assert the exact shape.
final class AgentSessionTranscoderTests: XCTestCase {
    private func transcode(_ kind: AgentKind, _ json: String) -> [String: Any]? {
        let transcoder = AgentSessionTranscoder.make(for: kind)
        guard let input = json.data(using: .utf8), let output = transcoder.transcode(input) else { return nil }
        return (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
    }

    // MARK: - Pi

    func testPiTranscoderIsIdentity() {
        let line = #"{"type":"message","id":"a","parentId":null,"message":{"role":"user"}}"#
        let data = line.data(using: .utf8)!
        XCTAssertEqual(AgentSessionTranscoder.pi.transcode(data), data)
        XCTAssertEqual(AgentSessionTranscoder.make(for: .pi).chain, .parentPointer)
    }

    // MARK: - Codex

    func testCodexSessionMetaBecomesSessionRecord() {
        let record = transcode(.codex, """
        {"timestamp":"2026-07-30T18:26:19.216Z","type":"session_meta","payload":{\
        "session_id":"019f-abc","cwd":"/Users/x/code","timestamp":"2026-07-30T18:26:19.089Z",\
        "thread_source":"user"}}
        """)
        XCTAssertEqual(record?["type"] as? String, "session")
        XCTAssertEqual(record?["id"] as? String, "019f-abc")
        XCTAssertEqual(record?["cwd"] as? String, "/Users/x/code")
        XCTAssertNil(record?["subsession"])
    }

    func testCodexSubagentRolloutIsMarked() {
        let record = transcode(.codex, """
        {"type":"session_meta","payload":{"session_id":"s","cwd":"/w","thread_source":"subagent"}}
        """)
        XCTAssertEqual(record?["subsession"] as? Bool, true)
    }

    func testCodexAssistantMessageBecomesAssistantEntry() {
        let record = transcode(.codex, """
        {"timestamp":"2026-07-30T18:26:21.400Z","type":"response_item","payload":{"type":"message",\
        "id":"msg_1","role":"assistant","phase":"final_answer",\
        "content":[{"type":"output_text","text":"Hello there"}]}}
        """)
        let message = record?["message"] as? [String: Any]
        XCTAssertEqual(record?["type"] as? String, "message")
        XCTAssertEqual(message?["role"] as? String, "assistant")
        // Only Codex's own final answer is a completed answer; see `CodexHarnessAndPhaseTests`.
        XCTAssertEqual(message?["stopReason"] as? String, "stop")
        let blocks = message?["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.first?["text"] as? String, "Hello there")
    }

    func testCodexDeveloperMessageIsDropped() {
        XCTAssertNil(transcode(.codex, """
        {"type":"response_item","payload":{"type":"message","role":"developer",\
        "content":[{"type":"input_text","text":"<app-context>"}]}}
        """))
    }

    func testCodexFunctionCallBecomesToolCallBlockWithParsedArguments() {
        let record = transcode(.codex, """
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command",\
        "arguments":"{\\"cmd\\":\\"ls -la\\"}","call_id":"call_9"}}
        """)
        let message = record?["message"] as? [String: Any]
        XCTAssertEqual(message?["stopReason"] as? String, "toolUse")
        let block = (message?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(block?["type"] as? String, "toolCall")
        XCTAssertEqual(block?["id"] as? String, "call_9")
        XCTAssertEqual(block?["name"] as? String, "exec_command")
        XCTAssertEqual((block?["arguments"] as? [String: Any])?["cmd"] as? String, "ls -la")
    }

    func testCodexFunctionCallOutputBecomesToolResult() {
        let record = transcode(.codex, """
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_9",\
        "output":"total 4"}}
        """)
        let message = record?["message"] as? [String: Any]
        XCTAssertEqual(message?["role"] as? String, "toolResult")
        XCTAssertEqual(message?["toolCallId"] as? String, "call_9")
        XCTAssertEqual((message?["content"] as? [[String: Any]])?.first?["text"] as? String, "total 4")
    }

    func testCodexReasoningBecomesThinkingBlocks() {
        let record = transcode(.codex, """
        {"type":"response_item","payload":{"type":"reasoning","id":"rs_1",\
        "summary":[{"type":"summary_text","text":"**Planning**"}],"encrypted_content":"AAAA"}}
        """)
        let blocks = (record?["message"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?.first?["type"] as? String, "thinking")
        XCTAssertEqual(blocks?.first?["thinking"] as? String, "**Planning**")
    }

    /// Codex reports a running total for the whole thread on every turn. Taking that total and
    /// marking it as superseding is what lets a summary read usage from the file's tail instead
    /// of walking every record, which on a large rollout took over a minute.
    func testCodexTokenCountEmitsTheRunningTotalWithCacheSplitOut() {
        let record = transcode(.codex, """
        {"type":"event_msg","payload":{"type":"token_count","info":{\
        "model_context_window":258400,\
        "total_token_usage":{"input_tokens":25818,"cached_input_tokens":25344,\
        "cache_write_input_tokens":12,"output_tokens":391,"total_tokens":26209},\
        "last_token_usage":{"input_tokens":11,"output_tokens":2}}}}
        """)
        XCTAssertEqual(record?["type"] as? String, "usage")
        XCTAssertEqual(record?["cumulative"] as? Bool, true, "a running total replaces, it does not add")
        let usage = record?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["input"] as? Int, 474, "the cached portion is counted separately")
        XCTAssertEqual(usage?["cacheRead"] as? Int, 25344)
        XCTAssertEqual(usage?["cacheWrite"] as? Int, 12)
        XCTAssertEqual(usage?["output"] as? Int, 391)
        XCTAssertEqual(record?["contextWindow"] as? Int, 258400)
        XCTAssertEqual(record?["contextTokens"] as? Int, 26209)
    }

    func testCodexEventMessageDuplicateOfResponseItemIsDropped() {
        // `agent_message` is the UI mirror of `response_item/message`; rendering both double-posts.
        XCTAssertNil(transcode(.codex, """
        {"type":"event_msg","payload":{"type":"agent_message","message":"Hello there"}}
        """))
        XCTAssertNil(transcode(.codex, """
        {"type":"event_msg","payload":{"type":"user_message","message":"do a thing"}}
        """))
    }

    func testCodexWorldStateIsDropped() {
        XCTAssertNil(transcode(.codex, #"{"type":"world_state","payload":{"full":true}}"#))
    }

    func testCodexIsLinearAndIdsAreStablePerContent() {
        XCTAssertEqual(AgentSessionTranscoder.make(for: .codex).chain, .linear)
        let line = """
        {"type":"response_item","payload":{"type":"message","role":"assistant",\
        "content":[{"type":"output_text","text":"same"}]}}
        """
        XCTAssertEqual(transcode(.codex, line)?["id"] as? String, transcode(.codex, line)?["id"] as? String)
        XCTAssertNotEqual(
            transcode(.codex, line)?["id"] as? String,
            transcode(.codex, line.replacingOccurrences(of: "same", with: "other"))?["id"] as? String
        )
    }

    func testCodexInlineImageSplitsMimeFromPayload() {
        let record = transcode(.codex, """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[\
        {"type":"input_image","image_url":"data:image/jpeg;base64,QUJD"}]}}
        """)
        let block = ((record?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(block?["type"] as? String, "image")
        XCTAssertEqual(block?["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(block?["data"] as? String, "QUJD")
    }

    // MARK: - Claude

    func testClaudeAssistantKeepsRealParentChain() {
        let record = transcode(.claude, """
        {"type":"assistant","uuid":"u2","parentUuid":"u1","cwd":"/Users/x/app",\
        "sessionId":"sess-1","timestamp":"2026-07-24T21:49:34.900Z","message":{"role":"assistant",\
        "model":"claude-fable-5","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}],\
        "usage":{"input_tokens":10,"output_tokens":3,"cache_read_input_tokens":7,\
        "cache_creation_input_tokens":1}}}
        """)
        XCTAssertEqual(record?["id"] as? String, "u2")
        XCTAssertEqual(record?["parentId"] as? String, "u1")
        XCTAssertEqual(record?["cwd"] as? String, "/Users/x/app")
        XCTAssertEqual(record?["sessionId"] as? String, "sess-1")
        let message = record?["message"] as? [String: Any]
        XCTAssertEqual(message?["model"] as? String, "claude-fable-5")
        XCTAssertEqual(message?["provider"] as? String, "anthropic")
        XCTAssertEqual(message?["stopReason"] as? String, "stop")
        XCTAssertEqual((message?["usage"] as? [String: Any])?["cacheWrite"] as? Int, 1)
        // Claude's parent pointers routinely dangle (compaction and resume rewrite the file),
        // so the transcript is read in file order; see `testClaudeIsReadInFileOrder`.
        XCTAssertEqual(AgentSessionTranscoder.make(for: .claude).chain, .linear)
    }

    func testClaudeToolUseBecomesToolCallAndToolResultBecomesToolRole() {
        let call = transcode(.claude, """
        {"type":"assistant","uuid":"u3","parentUuid":"u2","message":{"role":"assistant",\
        "stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_7","name":"Bash",\
        "input":{"command":"ls"}}]}}
        """)
        let callBlock = ((call?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual((call?["message"] as? [String: Any])?["stopReason"] as? String, "toolUse")
        XCTAssertEqual(callBlock?["name"] as? String, "Bash")
        XCTAssertEqual((callBlock?["arguments"] as? [String: Any])?["command"] as? String, "ls")

        let result = transcode(.claude, """
        {"type":"user","uuid":"u4","parentUuid":"u3","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"toolu_7","is_error":true,"content":"boom"}]}}
        """)
        let message = result?["message"] as? [String: Any]
        XCTAssertEqual(message?["role"] as? String, "toolResult")
        XCTAssertEqual(message?["toolCallId"] as? String, "toolu_7")
        XCTAssertEqual(message?["isError"] as? Bool, true)
    }

    func testClaudeStringContentUserMessage() {
        let record = transcode(.claude, """
        {"type":"user","uuid":"u1","message":{"role":"user","content":"just text"}}
        """)
        let message = record?["message"] as? [String: Any]
        XCTAssertEqual(message?["role"] as? String, "user")
        XCTAssertEqual((message?["content"] as? [[String: Any]])?.first?["text"] as? String, "just text")
        XCTAssertNil(record?["parentId"])
    }

    func testClaudeSidechainAndMetaRecordsAreDropped() {
        XCTAssertNil(transcode(.claude, """
        {"type":"assistant","uuid":"s1","isSidechain":true,"message":{"role":"assistant",\
        "content":[{"type":"text","text":"subagent"}]}}
        """))
        XCTAssertNil(transcode(.claude, """
        {"type":"user","uuid":"m1","isMeta":true,"message":{"role":"user","content":"harness"}}
        """))
    }

    func testClaudeTitleRecordsCarryNameWithoutJoiningTheChain() {
        for line in [
            #"{"type":"ai-title","aiTitle":"Screen AI companies","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"Screen AI companies","sessionId":"s"}"#
        ] {
            let record = transcode(.claude, line)
            XCTAssertEqual(record?["type"] as? String, "session_info")
            XCTAssertEqual(record?["name"] as? String, "Screen AI companies")
            XCTAssertNil(record?["id"], "a title must not become a chain leaf")
        }
    }

    func testClaudeCompactSummaryBecomesCompaction() {
        let record = transcode(.claude, """
        {"type":"user","uuid":"c1","parentUuid":"b0","isCompactSummary":true,\
        "message":{"role":"user","content":[{"type":"text","text":"earlier work"}]}}
        """)
        XCTAssertEqual(record?["type"] as? String, "compaction")
        XCTAssertEqual(record?["summary"] as? String, "earlier work")
        XCTAssertEqual(record?["parentId"] as? String, "b0")
    }

    func testClaudeThinkingAndImageBlocks() {
        let record = transcode(.claude, """
        {"type":"assistant","uuid":"u9","message":{"role":"assistant","content":[\
        {"type":"thinking","thinking":"hmm","signature":"sig"},\
        {"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}]}}
        """)
        let blocks = (record?["message"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?.first?["thinking"] as? String, "hmm")

        let image = transcode(.claude, """
        {"type":"user","uuid":"u10","message":{"role":"user","content":[\
        {"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}]}}
        """)
        let imageBlock = ((image?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(imageBlock?["type"] as? String, "image")
        XCTAssertEqual(imageBlock?["data"] as? String, "QUJD")
    }

    func testClaudeBookkeepingRecordsAreDropped() {
        for line in [
            #"{"type":"queue-operation","operation":"enqueue","content":"x"}"#,
            #"{"type":"last-prompt","lastPrompt":"x","leafUuid":"u"}"#,
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
            #"{"type":"attachment","uuid":"a","attachment":{"type":"deferred_tools_delta"}}"#,
            #"{"type":"file-history-snapshot","messageId":"m","snapshot":{}}"#
        ] {
            XCTAssertNil(transcode(.claude, line), "expected \(line) to be dropped")
        }
    }

    func testMalformedRecordIsDroppedNotCrashed() {
        for kind in AgentKind.allCases where kind != .pi {
            XCTAssertNil(transcode(kind, "not json at all"))
            XCTAssertNil(transcode(kind, "[1,2,3]"))
            XCTAssertNil(transcode(kind, "{}"))
        }
    }
}

/// The prefilter is an optimisation, so the property that matters is that it never changes the
/// answer: it may only decide a record the full transcoder would have decided the same way.
final class CodexPrefilterTests: XCTestCase {
    private let transcoder = AgentSessionTranscoder.make(for: .codex)

    func testValueScanFindsARecordTypeAndItsPayloadTypeSeparately() {
        let bytes = Array(#"{"timestamp":"T","type":"event_msg","payload":{"type":"token_count"}}"#.utf8)
        XCTAssertEqual(CodexSessionTranscoder.Prefilter.value(of: "type", in: bytes), "event_msg")
        XCTAssertEqual(CodexSessionTranscoder.Prefilter.value(of: "type", in: bytes, occurrence: 2), "token_count")
        XCTAssertEqual(CodexSessionTranscoder.Prefilter.value(of: "timestamp", in: bytes), "T")
        XCTAssertNil(CodexSessionTranscoder.Prefilter.value(of: "absent", in: bytes))
    }

    /// A value cut off by the prefix window, or one carrying an escape, must be inconclusive
    /// rather than a wrong guess.
    func testValueScanIsInconclusiveRatherThanWrongOnATruncatedOrEscapedValue() {
        XCTAssertNil(CodexSessionTranscoder.Prefilter.value(of: "type", in: Array(#"{"type":"trunc"#.utf8)))
        XCTAssertNil(CodexSessionTranscoder.Prefilter.value(of: "type", in: Array(#"{"type":"a\"b"}"#.utf8)))
    }

    func testDroppedRecordTypesAreDecidedWithoutParsing() {
        for type in CodexSessionTranscoder.Prefilter.droppedRecordTypes {
            let line = #"{"timestamp":"T","type":"\#(type)","payload":{"anything":true}}"#
            guard case .drop? = CodexSessionTranscoder.Prefilter.decide(Data(line.utf8)) else {
                return XCTFail("\(type) should be dropped by the prefilter")
            }
            XCTAssertNil(transcoder.transcode(Data(line.utf8)))
        }
    }

    /// `compacted` embeds an entire replaced history and yields one constant line, so the payload
    /// must never be parsed, and a huge payload must not change the result.
    func testCompactedIsEmittedWithoutParsingItsEmbeddedHistory() throws {
        let huge = String(repeating: "x", count: 400_000)
        let line = #"{"timestamp":"2026-07-30T18:33:38.615Z","type":"compacted","payload":{"message":"","replacement_history":"\#(huge)"}}"#
        let data = Data(line.utf8)
        guard case let .emit(emitted)? = CodexSessionTranscoder.Prefilter.decide(data), let emitted else {
            return XCTFail("compacted should be emitted by the prefilter")
        }
        let record = try XCTUnwrap(TranscodeSupport.decode(emitted))
        XCTAssertEqual(record["type"] as? String, "compaction")
        XCTAssertEqual(record["timestamp"] as? String, "2026-07-30T18:33:38.615Z")
        XCTAssertEqual(record["summary"] as? String, "Earlier context was compacted.")
        XCTAssertLessThan(emitted.count, 1_000, "the embedded history must not survive into the record")
        // The public transform agrees with the prefilter's shortcut. Compared field by field:
        // JSON object key order is not stable between two encodes of the same dictionary.
        let viaTransform = try XCTUnwrap(transcoder.transcode(data).flatMap(TranscodeSupport.decode))
        XCTAssertEqual(viaTransform["type"] as? String, record["type"] as? String)
        XCTAssertEqual(viaTransform["id"] as? String, record["id"] as? String)
        XCTAssertEqual(viaTransform["summary"] as? String, record["summary"] as? String)
        XCTAssertEqual(viaTransform["timestamp"] as? String, record["timestamp"] as? String)
    }

    func testEventMessagesTheTranscoderKeepsAreNeverDroppedByThePrefilter() {
        for payload in CodexSessionTranscoder.Prefilter.keptEventPayloads {
            let line = #"{"timestamp":"T","type":"event_msg","payload":{"type":"\#(payload)"}}"#
            XCTAssertNil(
                CodexSessionTranscoder.Prefilter.decide(Data(line.utf8)),
                "\(payload) must fall through to the full transcoder"
            )
        }
    }

    func testEventMessagesWithNothingToRenderAreDroppedEarly() {
        for payload in ["image_generation_end", "mcp_tool_call_end", "agent_message", "web_search_end"] {
            let line = #"{"timestamp":"T","type":"event_msg","payload":{"type":"\#(payload)","big":"x"}}"#
            guard case .drop? = CodexSessionTranscoder.Prefilter.decide(Data(line.utf8)) else {
                return XCTFail("\(payload) should be dropped by the prefilter")
            }
            XCTAssertNil(transcoder.transcode(Data(line.utf8)), "the full transcoder must agree")
        }
    }

    /// An `event_msg` whose payload type sits past the prefix window must fall through, because
    /// dropping it on a guess would silently lose token usage.
    func testAnEventMessageWithADistantPayloadTypeFallsThroughInsteadOfGuessing() {
        let padding = String(repeating: "p", count: CodexSessionTranscoder.Prefilter.prefixBytes)
        let line = #"{"note":"\#(padding)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":3}}}}"#
        XCTAssertNil(CodexSessionTranscoder.Prefilter.decide(Data(line.utf8)))
        let transcoded = transcoder.transcode(Data(line.utf8))
        XCTAssertEqual((transcoded.flatMap(TranscodeSupport.decode))?["type"] as? String, "usage")
    }

    func testRecordsTheTranscoderRendersAreNeverDecidedByThePrefilter() {
        for line in [
            #"{"type":"session_meta","payload":{"session_id":"s","cwd":"/w"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
            #"{"type":"turn_context","payload":{"model":"m"}}"#
        ] {
            XCTAssertNil(CodexSessionTranscoder.Prefilter.decide(Data(line.utf8)), "\(line) must be parsed")
        }
    }

    func testGarbageIsNotDecidedByThePrefilter() {
        XCTAssertNil(CodexSessionTranscoder.Prefilter.decide(Data("not json".utf8)))
        XCTAssertNil(CodexSessionTranscoder.Prefilter.decide(Data()))
    }
}
