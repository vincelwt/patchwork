import Foundation
import XCTest
@testable import PiDeskKit

/// Drives `ClaudeProtocolAdapter` directly with realistic protocol lines. Nothing here launches
/// `claude` or reaches a provider: every byte is a fixture.
final class ClaudeProtocolAdapterTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/tmp/Pi Desktop Claude", isDirectory: true)

    // MARK: - Helpers

    private func adapter() -> ClaudeProtocolAdapter { ClaudeProtocolAdapter() }

    private func decode(_ adapter: ClaudeProtocolAdapter, _ object: [String: Any]) -> [AdapterInbound] {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return adapter.decode(line: data)
    }

    private func events(_ messages: [AdapterInbound]) -> [PiJSONValue] {
        messages.compactMap { if case let .event(value) = $0 { return value } else { return nil } }
    }

    private func eventTypes(_ messages: [AdapterInbound]) -> [String] {
        events(messages).compactMap { $0["type"]?.stringValue }
    }

    private func responses(_ messages: [AdapterInbound]) -> [(String, PiJSONValue)] {
        messages.compactMap { if case let .response(id, value) = $0 { return (id, value) } else { return nil } }
    }

    private func written(_ outbound: AdapterOutbound) -> [PiJSONValue] {
        guard case let .write(lines) = outbound else { return [] }
        return lines.compactMap { try? PiJSONValue.decode($0) }
    }

    private func immediate(_ outbound: AdapterOutbound) -> PiJSONValue? {
        guard case let .immediate(value) = outbound else { return nil }
        return value
    }

    private func initLine(sessionID: String = "11111111-2222-3333-4444-555555555555") -> [String: Any] {
        [
            "type": "system", "subtype": "init", "session_id": sessionID,
            "tools": ["Bash", "Read"], "model": "claude-sonnet-5", "cwd": cwd.path,
            "permissionMode": "manual", "slash_commands": ["compact", "cost"],
            "apiKeySource": "none", "uuid": "u-init"
        ]
    }

    /// Runs a full turn to its `result` line, returning everything emitted.
    private func runTurn(_ adapter: ClaudeProtocolAdapter) -> [AdapterInbound] {
        var out = decode(adapter, [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": "hi"]]],
            "session_id": "s", "uuid": "u1"
        ])
        out += decode(adapter, [
            "type": "assistant",
            "message": [
                "id": "msg_1", "role": "assistant", "model": "claude-sonnet-5",
                "content": [["type": "text", "text": "done"]], "stop_reason": "end_turn",
                "usage": ["input_tokens": 10, "output_tokens": 4]
            ],
            "session_id": "s", "uuid": "u2"
        ])
        out += decode(adapter, [
            "type": "result", "subtype": "success", "is_error": false, "num_turns": 1,
            "duration_ms": 900, "result": "done", "session_id": "s", "total_cost_usd": 0.5,
            "usage": ["input_tokens": 10, "output_tokens": 4]
        ])
        return out
    }

    // MARK: - Launch

    func testFreshLaunchGeneratesASessionIdSoTheTranscriptPathIsKnownUpFront() throws {
        let adapter = adapter()
        let arguments = adapter.launchArguments(sessionPath: nil, cwd: cwd)

        XCTAssertEqual(
            arguments.prefix(9).map { $0 },
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
             "--verbose", "--include-partial-messages", "--replay-user-messages", "--session-id"]
        )
        XCTAssertFalse(arguments.contains("--resume"))
        let generated = try XCTUnwrap(arguments.last)
        XCTAssertNotNil(UUID(uuidString: generated))

        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "1", payload: [:])))
        XCTAssertEqual(state["sessionId"]?.stringValue, generated)
        let file = try XCTUnwrap(state["sessionFile"]?.stringValue)
        XCTAssertTrue(file.hasSuffix("/-tmp-Pi Desktop Claude/\(generated).jsonl"), file)
    }

    func testResumingParsesTheSessionIdFromTheTranscriptFilename() throws {
        let adapter = adapter()
        let transcript = URL(fileURLWithPath: "/Users/x/.claude/projects/-tmp-p/abcd-1234.jsonl")
        let arguments = adapter.launchArguments(sessionPath: transcript, cwd: cwd)

        XCTAssertEqual(arguments.suffix(2).map { $0 }, ["--resume", "abcd-1234"])
        XCTAssertFalse(arguments.contains("--session-id"))
        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "1", payload: [:])))
        XCTAssertEqual(state["sessionId"]?.stringValue, "abcd-1234")
        XCTAssertEqual(state["sessionFile"]?.stringValue, transcript.path)
    }

    func testStoredEffortAndModelRideTheNextLaunchEvenThoughEffortCannotApplyLive() {
        let adapter = adapter()
        _ = adapter.launchArguments(sessionPath: nil, cwd: cwd)

        // Effort is a launch flag, so the live change is refused rather than faked.
        let outcome = adapter.encode(command: "set_thinking_level", id: "1", payload: ["level": .string("xhigh")])
        guard case let .unsupported(reason) = outcome else { return XCTFail("expected unsupported, got \(outcome)") }
        XCTAssertTrue(reason.contains("effort"))

        _ = adapter.decode(line: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"m1"}}"#.utf8))
        _ = adapter.encode(command: "set_model", id: "m1", payload: ["modelId": .string("opus")])
        _ = adapter.decode(line: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"m1"}}"#.utf8))

        adapter.reset()
        let arguments = adapter.launchArguments(sessionPath: nil, cwd: cwd)
        XCTAssertTrue(arguments.contains("--effort"))
        XCTAssertTrue(arguments.contains("xhigh"))
        XCTAssertTrue(arguments.contains("--model"))
        XCTAssertTrue(arguments.contains("opus"))
    }

    // MARK: - system/init

    func testInitPopulatesModelCommandsAndSessionState() throws {
        let adapter = adapter()
        _ = adapter.launchArguments(sessionPath: nil, cwd: cwd)

        // init arrives before any prompt and must not start a turn.
        XCTAssertTrue(decode(adapter, initLine()).isEmpty)

        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "1", payload: [:])))
        XCTAssertEqual(state["sessionId"]?.stringValue, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(state["model"]?["id"]?.stringValue, "claude-sonnet-5")
        XCTAssertEqual(state["model"]?["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(state["isStreaming"]?.boolValue, false)

        let commands = try XCTUnwrap(immediate(adapter.encode(command: "get_commands", id: "2", payload: [:])))
        XCTAssertEqual(commands["commands"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["compact", "cost"])
    }

    // MARK: - Streaming

    func testStreamingDeltasAccumulateIntoMessageUpdatesThenAMessageEnd() throws {
        let adapter = adapter()
        var emitted: [AdapterInbound] = []
        emitted += decode(adapter, [
            "type": "stream_event", "session_id": "s", "uuid": "e1",
            "event": ["type": "message_start", "message": [
                "id": "msg_1", "role": "assistant", "model": "claude-sonnet-5", "content": []
            ]]
        ])
        emitted += decode(adapter, [
            "type": "stream_event", "session_id": "s", "uuid": "e2",
            "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]
        ])
        for chunk in ["Hel", "lo"] {
            emitted += decode(adapter, [
                "type": "stream_event", "session_id": "s", "uuid": "e-\(chunk)",
                "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": chunk]]
            ])
        }

        // The turn begins on the first conversation line, not on init.
        XCTAssertEqual(eventTypes(emitted).prefix(3).map { $0 }, ["agent_start", "turn_start", "message_start"])
        let updates = events(emitted).filter { $0["type"]?.stringValue == "message_update" }
        XCTAssertEqual(updates.count, 3)
        let latest = try XCTUnwrap(updates.last)
        XCTAssertEqual(latest["message"]?["role"]?.stringValue, "assistant")
        XCTAssertEqual(latest["message"]?["model"]?.stringValue, "claude-sonnet-5")
        XCTAssertEqual(latest["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "Hello")

        let final = decode(adapter, [
            "type": "assistant", "session_id": "s", "uuid": "u2",
            "message": [
                "id": "msg_1", "role": "assistant", "model": "claude-sonnet-5",
                "content": [["type": "text", "text": "Hello"]], "stop_reason": "end_turn",
                "usage": [
                    "input_tokens": 12, "output_tokens": 3,
                    "cache_read_input_tokens": 7, "cache_creation_input_tokens": 1
                ]
            ]
        ])
        // The message already started from the stream, so it is not restarted.
        XCTAssertEqual(eventTypes(final), ["message_end"])
        let message = try XCTUnwrap(events(final).first?["message"])
        XCTAssertEqual(message["stopReason"]?.stringValue, "stop")
        XCTAssertEqual(message["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(message["usage"]?["cacheRead"]?.intValue, 7)
        XCTAssertEqual(message["usage"]?["cacheWrite"]?.intValue, 1)
    }

    func testThinkingDeltasProjectAsThinkingBlocks() throws {
        let adapter = adapter()
        _ = decode(adapter, [
            "type": "stream_event", "session_id": "s", "uuid": "e1",
            "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]
        ])
        let emitted = decode(adapter, [
            "type": "stream_event", "session_id": "s", "uuid": "e2",
            "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "weighing"]]
        ])
        let block = try XCTUnwrap(events(emitted).last?["message"]?["content"]?.arrayValue?.first)
        XCTAssertEqual(block["type"]?.stringValue, "thinking")
        XCTAssertEqual(block["thinking"]?.stringValue, "weighing")

        let final = decode(adapter, [
            "type": "assistant", "session_id": "s", "uuid": "u1",
            "message": [
                "id": "msg_1", "role": "assistant", "model": "claude-sonnet-5", "stop_reason": "end_turn",
                "content": [
                    ["type": "thinking", "thinking": "weighing"],
                    ["type": "text", "text": "answer"]
                ]
            ]
        ])
        let ended = try XCTUnwrap(events(final).first { $0["type"]?.stringValue == "message_end" })
        let content = try XCTUnwrap(ended["message"]?["content"]?.arrayValue)
        XCTAssertEqual(content.compactMap { $0["type"]?.stringValue }, ["thinking", "text"])
    }

    // MARK: - Tools

    func testToolUseBecomesExecutionStartAndTheMatchingResultEndsIt() throws {
        let adapter = adapter()
        let started = decode(adapter, [
            "type": "assistant", "session_id": "s", "uuid": "u1",
            "message": [
                "id": "msg_1", "role": "assistant", "model": "claude-sonnet-5", "stop_reason": "tool_use",
                "content": [[
                    "type": "tool_use", "id": "toolu_9", "name": "Bash",
                    "input": ["command": "ls", "description": "list"]
                ]]
            ]
        ])
        XCTAssertEqual(eventTypes(started), ["agent_start", "turn_start", "message_start", "message_end", "tool_execution_start"])
        let start = try XCTUnwrap(events(started).last)
        XCTAssertEqual(start["toolCallId"]?.stringValue, "toolu_9")
        XCTAssertEqual(start["toolName"]?.stringValue, "Bash")
        XCTAssertEqual(start["args"]?["command"]?.stringValue, "ls")
        XCTAssertEqual(events(started)[3]["message"]?["stopReason"]?.stringValue, "toolUse")

        let ended = decode(adapter, [
            "type": "user", "session_id": "s", "uuid": "u2",
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_9",
                "content": [["type": "text", "text": "a.txt"]], "is_error": false
            ]]]
        ])
        XCTAssertEqual(eventTypes(ended), ["tool_execution_end", "message_end"])
        let end = try XCTUnwrap(events(ended).first)
        XCTAssertEqual(end["toolCallId"]?.stringValue, "toolu_9")
        XCTAssertEqual(end["isError"]?.boolValue, false)
        XCTAssertEqual(end["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "a.txt")
        XCTAssertEqual(events(ended).last?["message"]?["role"]?.stringValue, "toolResult")
    }

    func testFailingToolResultIsMarkedAsAnError() throws {
        let adapter = adapter()
        let ended = decode(adapter, [
            "type": "user", "session_id": "s", "uuid": "u2",
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_9", "content": "boom", "is_error": true
            ]]]
        ])
        let end = try XCTUnwrap(events(ended).first { $0["type"]?.stringValue == "tool_execution_end" })
        XCTAssertEqual(end["isError"]?.boolValue, true)
        XCTAssertEqual(end["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "boom")
    }

    // MARK: - Turn lifecycle

    func testExactlyOneAgentSettledPerResult() {
        let adapter = adapter()
        let emitted = runTurn(adapter)
        let types = eventTypes(emitted)

        XCTAssertEqual(types.filter { $0 == "agent_start" }.count, 1)
        XCTAssertEqual(types.filter { $0 == "agent_settled" }.count, 1)
        XCTAssertEqual(types.suffix(2).map { $0 }, ["turn_end", "agent_settled"])

        // A second turn on the same process starts and settles exactly once again.
        let second = eventTypes(runTurn(adapter))
        XCTAssertEqual(second.filter { $0 == "agent_start" }.count, 1)
        XCTAssertEqual(second.filter { $0 == "agent_settled" }.count, 1)
    }

    func testResultRecordsUsageForSessionStatsAndClearsStreamingState() throws {
        let adapter = adapter()
        _ = runTurn(adapter)

        let stats = try XCTUnwrap(immediate(adapter.encode(command: "get_session_stats", id: "1", payload: [:])))
        XCTAssertEqual(stats["tokens"]?["input"]?.intValue, 10)
        XCTAssertEqual(stats["tokens"]?["output"]?.intValue, 4)
        XCTAssertEqual(stats["cost"]?.doubleValue, 0.5)

        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "2", payload: [:])))
        XCTAssertEqual(state["isStreaming"]?.boolValue, false)
    }

    func testErroredResultSurfacesTheReasonAsAnAssistantMessage() throws {
        let adapter = adapter()
        let emitted = decode(adapter, [
            "type": "result", "subtype": "error_during_execution", "is_error": true,
            "result": "the tool crashed", "session_id": "s", "num_turns": 1, "duration_ms": 5
        ])
        XCTAssertEqual(eventTypes(emitted), ["message_end", "turn_end", "agent_settled"])
        let message = try XCTUnwrap(events(emitted).first?["message"])
        XCTAssertEqual(message["stopReason"]?.stringValue, "error")
        XCTAssertEqual(message["isError"]?.boolValue, true)
        XCTAssertEqual(message["errorMessage"]?.stringValue, "the tool crashed")
    }

    func testCompactBoundaryBracketsCompaction() {
        let adapter = adapter()
        let emitted = decode(adapter, [
            "type": "system", "subtype": "compact_boundary", "session_id": "s",
            "compact_metadata": ["trigger": "manual", "pre_tokens": 90_000]
        ])
        XCTAssertEqual(eventTypes(emitted), ["compaction_start", "compaction_end"])
    }

    func testSubagentOutputIsNotProjectedIntoTheParentTranscript() {
        let adapter = adapter()
        let emitted = decode(adapter, [
            "type": "assistant", "session_id": "s", "uuid": "u1", "parent_tool_use_id": "toolu_parent",
            "message": [
                "id": "msg_sub", "role": "assistant", "model": "claude-sonnet-5",
                "content": [["type": "text", "text": "subagent chatter"]], "stop_reason": "end_turn"
            ]
        ])
        XCTAssertTrue(emitted.isEmpty)
    }

    // MARK: - Prompts

    func testPromptWritesAUserLineAndTheReplayResolvesIt() throws {
        let adapter = adapter()
        _ = adapter.launchArguments(sessionPath: nil, cwd: cwd)
        let outbound = adapter.encode(command: "prompt", id: "desktop-1-1", payload: ["message": .string("hello")])
        let line = try XCTUnwrap(written(outbound).first)

        XCTAssertEqual(line["type"]?.stringValue, "user")
        XCTAssertEqual(line["message"]?["role"]?.stringValue, "user")
        XCTAssertEqual(line["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "hello")

        let replay = decode(adapter, [
            "type": "user", "session_id": "s", "uuid": "u1",
            "message": ["role": "user", "content": [["type": "text", "text": "hello"]]]
        ])
        let answered = responses(replay)
        XCTAssertEqual(answered.count, 1)
        XCTAssertEqual(answered.first?.0, "desktop-1-1")
        XCTAssertEqual(answered.first?.1["type"]?.stringValue, "response")
        XCTAssertNil(answered.first?.1["error"])
    }

    func testAPromptSentMidTurnIsReportedAsSteeringUntilTheTurnSettles() throws {
        let adapter = adapter()
        _ = decode(adapter, [
            "type": "assistant", "session_id": "s", "uuid": "u1",
            "message": [
                "id": "msg_1", "role": "assistant", "model": "claude-sonnet-5", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": [:]]]
            ]
        ])
        _ = adapter.encode(command: "prompt", id: "p2", payload: ["message": .string("also check tests")])

        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "s1", payload: [:])))
        // Claude takes a mid-turn message into the running turn, so it is outstanding *steering*
        // rather than work waiting behind the turn.
        XCTAssertEqual(state["steeringQueue"]?.arrayValue?.compactMap { $0.stringValue }, ["also check tests"])
        XCTAssertEqual(state["followUpQueue"]?.arrayValue?.count, 0)

        let replay = decode(adapter, [
            "type": "user", "session_id": "s", "uuid": "u2",
            "message": ["role": "user", "content": [["type": "text", "text": "also check tests"]]]
        ])
        let queued = try XCTUnwrap(events(replay).first { $0["type"]?.stringValue == "queue_update" })
        XCTAssertEqual(queued["steering"]?.arrayValue?.count, 1)

        let settled = decode(adapter, [
            "type": "result", "subtype": "success", "is_error": false,
            "result": "ok", "session_id": "s", "num_turns": 1, "duration_ms": 5
        ])
        let cleared = try XCTUnwrap(events(settled).first { $0["type"]?.stringValue == "queue_update" })
        XCTAssertEqual(cleared["steering"]?.arrayValue?.count, 0)
    }

    func testCompactIsSentAsASlashCommandPrompt() throws {
        let adapter = adapter()
        let line = try XCTUnwrap(written(adapter.encode(command: "compact", id: "c1", payload: [:])).first)
        XCTAssertEqual(line["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "/compact")

        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "s1", payload: [:])))
        XCTAssertEqual(state["isCompacting"]?.boolValue, true)
    }

    func testAttachmentsBecomeAnthropicImageBlocks() throws {
        let adapter = adapter()
        let outbound = adapter.encode(command: "prompt", id: "p1", payload: [
            "message": .string("look"),
            "images": .array([.object([
                "type": .string("image"), "data": .string("QUJD"), "mimeType": .string("image/jpeg")
            ])])
        ])
        let content = try XCTUnwrap(written(outbound).first?["message"]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"]?.stringValue, "image")
        XCTAssertEqual(content[1]["source"]?["media_type"]?.stringValue, "image/jpeg")
        XCTAssertEqual(content[1]["source"]?["data"]?.stringValue, "QUJD")
    }

    // MARK: - Control requests

    func testAbortEncodesAnInterruptAndItsAckResolvesTheCaller() throws {
        let adapter = adapter()
        let line = try XCTUnwrap(written(adapter.encode(command: "abort", id: "a1", payload: [:])).first)
        XCTAssertEqual(line["type"]?.stringValue, "control_request")
        XCTAssertEqual(line["request_id"]?.stringValue, "a1")
        XCTAssertEqual(line["request"]?["subtype"]?.stringValue, "interrupt")

        let acked = decode(adapter, [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": "a1", "response": ["still_queued": []]]
        ])
        XCTAssertEqual(responses(acked).first?.0, "a1")
    }

    func testSetModelReportsTheAppliedModelAndARejectionIsSurfacedAsAFailure() throws {
        let adapter = adapter()
        let line = try XCTUnwrap(written(
            adapter.encode(command: "set_model", id: "m1", payload: ["modelId": .string("opus")])
        ).first)
        XCTAssertEqual(line["request"]?["subtype"]?.stringValue, "set_model")
        XCTAssertEqual(line["request"]?["model"]?.stringValue, "opus")

        let applied = responses(decode(adapter, [
            "type": "control_response", "response": ["subtype": "success", "request_id": "m1"]
        ]))
        XCTAssertEqual(applied.first?.1["data"]?["id"]?.stringValue, "opus")
        XCTAssertEqual(applied.first?.1["data"]?["provider"]?.stringValue, "anthropic")

        _ = adapter.encode(command: "set_model", id: "m2", payload: ["modelId": .string("nope")])
        let rejected = responses(decode(adapter, [
            "type": "control_response",
            "response": ["subtype": "error", "request_id": "m2", "error": "unknown model"]
        ]))
        XCTAssertEqual(rejected.first?.1["success"]?.boolValue, false)
        XCTAssertEqual(rejected.first?.1["error"]?.stringValue, "unknown model")
    }

    func testSetModeMapsToClaudesPermissionMode() throws {
        let adapter = adapter()
        _ = adapter.launchArguments(sessionPath: nil, cwd: cwd)
        let line = try XCTUnwrap(written(
            adapter.encode(command: "set_mode", id: "x1", payload: ["mode": .string("acceptEdits")])
        ).first)
        XCTAssertEqual(line["request"]?["subtype"]?.stringValue, "set_permission_mode")
        XCTAssertEqual(line["request"]?["mode"]?.stringValue, "acceptEdits")

        _ = decode(adapter, ["type": "control_response", "response": ["subtype": "success", "request_id": "x1"]])
        adapter.reset()
        let arguments = adapter.launchArguments(sessionPath: nil, cwd: cwd)
        XCTAssertTrue(arguments.contains("--permission-mode"))
        XCTAssertTrue(arguments.contains("acceptEdits"))
    }

    func testAnUncorrelatedControlResponseIsIgnored() {
        let adapter = adapter()
        let stray = decode(adapter, [
            "type": "control_response", "response": ["subtype": "success", "request_id": "never-sent"]
        ])
        XCTAssertTrue(stray.isEmpty)
    }

    // MARK: - Tool permission

    func testCanUseToolBecomesAnExtensionUIRequestAndTheAnswerBecomesAControlResponse() throws {
        let adapter = adapter()
        let asked = decode(adapter, [
            "type": "control_request", "request_id": "req-7",
            "request": [
                "subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash",
                "input": ["command": "rm -rf build"], "tool_use_id": "toolu_1",
                "description": "Delete the build directory?"
            ]
        ])
        let request = try XCTUnwrap(events(asked).first)
        XCTAssertEqual(request["type"]?.stringValue, "extension_ui_request")
        XCTAssertEqual(request["method"]?.stringValue, "confirm")
        XCTAssertEqual(request["id"]?.stringValue, "req-7")
        XCTAssertEqual(request["title"]?.stringValue, "Bash")
        XCTAssertTrue(request["message"]?.stringValue?.contains("rm -rf build") == true)

        let allow = adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string("req-7"), "confirmed": .bool(true)
        ]))
        let reply = try XCTUnwrap(allow.compactMap { try? PiJSONValue.decode($0) }.first)
        XCTAssertEqual(reply["type"]?.stringValue, "control_response")
        XCTAssertEqual(reply["response"]?["request_id"]?.stringValue, "req-7")
        XCTAssertEqual(reply["response"]?["subtype"]?.stringValue, "success")
        XCTAssertEqual(reply["response"]?["response"]?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(reply["response"]?["response"]?["updatedInput"]?["command"]?.stringValue, "rm -rf build")

        // The request is answered once; a duplicate answer writes nothing.
        XCTAssertTrue(adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string("req-7"), "confirmed": .bool(true)
        ])).isEmpty)
    }

    func testCancellingAPermissionDialogDeniesTheTool() throws {
        let adapter = adapter()
        _ = decode(adapter, [
            "type": "control_request", "request_id": "req-8",
            "request": ["subtype": "can_use_tool", "tool_name": "Write", "input": ["path": "/etc/hosts"]]
        ])
        let deny = adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string("req-8"), "cancelled": .bool(true)
        ]))
        let reply = try XCTUnwrap(deny.compactMap { try? PiJSONValue.decode($0) }.first)
        XCTAssertEqual(reply["response"]?["response"]?["behavior"]?.stringValue, "deny")
    }

    func testOverflowingPermissionRequestsAreDeniedOnTheWireRatherThanForgotten() throws {
        let adapter = adapter()
        for index in 0...ClaudeProtocolAdapter.Limit.permissions {
            _ = decode(adapter, [
                "type": "control_request", "request_id": "req-\(index)",
                "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo \(index)"]]
            ])
        }
        let drained = adapter.drainPendingWrites().compactMap { try? PiJSONValue.decode($0) }
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?["response"]?["request_id"]?.stringValue, "req-0")
        XCTAssertEqual(drained.first?["response"]?["response"]?["behavior"]?.stringValue, "deny")
        XCTAssertTrue(adapter.drainPendingWrites().isEmpty)
    }

    func testAControlCancelRequestRetiresThePendingPermission() {
        let adapter = adapter()
        _ = decode(adapter, [
            "type": "control_request", "request_id": "req-9",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": [:]]
        ])
        XCTAssertTrue(decode(adapter, ["type": "control_cancel_request", "request_id": "req-9"]).isEmpty)
        XCTAssertTrue(adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string("req-9"), "confirmed": .bool(true)
        ])).isEmpty)
    }

    // MARK: - Picker options

    func testModelAndThinkingOptionsMatchWhatTheAppCanRender() throws {
        let adapter = adapter()
        _ = decode(adapter, initLine())

        // Shaped exactly as `AvailableModel.init(json:)` reads it, asserted here without the
        // app type so the adapter's own package can cover it.
        let models = try XCTUnwrap(
            immediate(adapter.encode(command: "get_available_models", id: "1", payload: [:])))["models"]?.arrayValue
        let listed = try XCTUnwrap(models)
        XCTAssertTrue(listed.allSatisfy { $0["provider"]?.stringValue == "anthropic" })
        XCTAssertTrue(listed.allSatisfy { $0["id"]?.stringValue?.isEmpty == false })
        XCTAssertTrue(listed.contains { $0["id"]?.stringValue == "opus" })
        // The model the session actually reported is offered alongside the aliases.
        XCTAssertTrue(listed.contains { $0["id"]?.stringValue == "claude-sonnet-5" })

        let reported = try XCTUnwrap(
            immediate(adapter.encode(command: "get_available_thinking_levels", id: "2", payload: [:])))["levels"]?
            .arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(AgentThinkingLevels.supported(try XCTUnwrap(reported)), ["low", "medium", "high", "xhigh", "max"])
    }

    func testCommandsWithNoClaudeEquivalentAreReportedAsUnsupported() {
        let adapter = adapter()
        for command in ["set_session_name", "export_html", "get_fork_messages", "get_entries",
                        "cycle_model", "cycle_thinking_level", "something_new"] {
            guard case .unsupported = adapter.encode(command: command, id: "1", payload: [:]) else {
                return XCTFail("\(command) should be unsupported")
            }
        }
    }

    // MARK: - Robustness

    func testMalformedAndUnknownLinesAreDroppedWithoutCrashing() {
        let adapter = adapter()
        let junk = [
            Data("not json at all".utf8),
            Data("".utf8),
            Data("[1,2,3]".utf8),
            Data(#"{"no_type":true}"#.utf8),
            Data(#"{"type":"assistant"}"#.utf8),
            Data(#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#.utf8),
            Data(#"{"type":"system","subtype":"telemetry_from_the_future"}"#.utf8),
            Data(#"{"type":"control_request","request_id":"z","request":{"subtype":"elicitation"}}"#.utf8),
            Data(#"{"type":"user","message":{"role":"user","content":[{"type":"unknown_block"}]}}"#.utf8)
        ]
        for line in junk {
            XCTAssertTrue(eventTypes(adapter.decode(line: line)).allSatisfy {
                ["agent_start", "turn_start"].contains($0)
            })
        }
        // A well-formed line still works after the junk.
        XCTAssertEqual(
            eventTypes(decode(adapter, [
                "type": "result", "subtype": "success", "is_error": false,
                "result": "ok", "session_id": "s", "num_turns": 1, "duration_ms": 1
            ])),
            ["turn_end", "agent_settled"]
        )
    }

    func testStreamingTextIsBoundedRegardlessOfHowMuchArrives() throws {
        let adapter = adapter()
        let chunk = String(repeating: "x", count: 10_000)
        var last: PiJSONValue?
        for _ in 0..<40 {
            let emitted = decode(adapter, [
                "type": "stream_event", "session_id": "s", "uuid": "e",
                "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": chunk]]
            ])
            last = events(emitted).last ?? last
        }
        let text = try XCTUnwrap(last?["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertLessThanOrEqual(text.count, ClaudeProtocolAdapter.Limit.blockText + chunk.count)
    }

    func testResetDropsSessionStateButKeepsLaunchPreferences() throws {
        let adapter = adapter()
        _ = adapter.launchArguments(sessionPath: nil, cwd: cwd)
        _ = decode(adapter, initLine())
        _ = adapter.encode(command: "prompt", id: "p1", payload: ["message": .string("hi")])
        adapter.reset()

        let state = try XCTUnwrap(immediate(adapter.encode(command: "get_state", id: "1", payload: [:])))
        XCTAssertNil(state["sessionId"])
        XCTAssertEqual(state["isStreaming"]?.boolValue, false)
        XCTAssertEqual(state["followUpQueue"]?.arrayValue?.count, 0)
        // A stale prompt ack cannot be resolved by the next process's first replay.
        XCTAssertTrue(responses(decode(adapter, [
            "type": "user", "message": ["role": "user", "content": [["type": "text", "text": "hi"]]]
        ])).isEmpty)
        // The model chosen before the restart is still the one requested at launch.
        XCTAssertEqual(state["model"]?["id"]?.stringValue, "claude-sonnet-5")
    }
}
