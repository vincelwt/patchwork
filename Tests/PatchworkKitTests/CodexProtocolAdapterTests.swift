import Foundation
import XCTest
@testable import PatchworkKit

/// Drives `CodexProtocolAdapter` directly with app-server protocol lines. Nothing here spawns a
/// process or reaches a provider: every byte in and out is a literal.
final class CodexProtocolAdapterTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/tmp/patchwork-codex", isDirectory: true)

    // MARK: - Handshake

    func testStartupSendsInitializeAndDefersEverythingElseUntilItIsAnswered() throws {
        let adapter = CodexProtocolAdapter()
        let startup = adapter.launchArguments(sessionPath: nil, cwd: cwd)
        XCTAssertEqual(startup, ["app-server", "--stdio"])

        let lines = adapter.startupLines(sessionPath: nil, cwd: cwd)
        XCTAssertEqual(lines.count, 1)
        let initialize = try object(lines[0])
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        XCTAssertEqual(initialize["params"]?["clientInfo"]?["name"]?.stringValue, "patchwork")
        XCTAssertNotNil(initialize["id"])
        // Nothing else may reach the wire before Codex answers.
        XCTAssertTrue(adapter.drainPendingWrites().isEmpty)

        XCTAssertTrue(adapter.decode(line: response(id: 1, result: [:])).isEmpty)
        let afterInitialize = try adapter.drainPendingWrites().map(object)
        XCTAssertEqual(afterInitialize.map { $0["method"]?.stringValue }, ["initialized", "thread/start", "model/list"])
        XCTAssertNil(afterInitialize[0]["id"], "initialized is a notification and must carry no id")
        XCTAssertEqual(afterInitialize[1]["params"]?["cwd"]?.stringValue, cwd.path)
    }

    func testRolloutPathResumesByThreadIdInsteadOfStartingANewThread() throws {
        let threadID = "0199c0de-1111-7222-8333-444455556666"
        let session = URL(fileURLWithPath: "/tmp/sessions/rollout-2026-07-31T00-11-22-\(threadID).jsonl")
        XCTAssertEqual(CodexProtocolAdapter.threadID(fromRolloutPath: session), threadID)

        let adapter = CodexProtocolAdapter()
        _ = adapter.startupLines(sessionPath: session, cwd: cwd)
        _ = adapter.decode(line: response(id: 1, result: [:]))
        let sent = try adapter.drainPendingWrites().map(object)
        XCTAssertEqual(sent[1]["method"]?.stringValue, "thread/resume")
        XCTAssertEqual(sent[1]["params"]?["threadId"]?.stringValue, threadID)
    }

    func testCommandsArrivingBeforeTheThreadExistsAreQueuedAndFlushed() throws {
        let adapter = CodexProtocolAdapter()
        _ = adapter.startupLines(sessionPath: nil, cwd: cwd)
        _ = adapter.decode(line: response(id: 1, result: [:]))
        _ = adapter.drainPendingWrites()

        // Queued: the correlation id is reserved but no request is on the wire yet.
        guard case .deferred = adapter.encode(
            command: "prompt", id: "cmd-1", payload: ["message": .string("hello")]
        ) else { return XCTFail("prompt should reserve a correlation id") }
        XCTAssertTrue(adapter.drainPendingWrites().isEmpty)

        _ = adapter.decode(line: threadStartResponse(id: 2))
        let flushed = try adapter.drainPendingWrites().map(object)
        XCTAssertEqual(flushed.map { $0["method"]?.stringValue }, ["turn/start"])
        XCTAssertEqual(flushed[0]["params"]?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(flushed[0]["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, "hello")
    }

    func testTheQueueIsBoundedAndSaysSoInsteadOfGrowing() {
        let adapter = CodexProtocolAdapter()
        _ = adapter.startupLines(sessionPath: nil, cwd: cwd)
        for index in 0..<32 {
            guard case .deferred = adapter.encode(
                command: "prompt", id: "cmd-\(index)", payload: ["message": .string("x")]
            ) else { return XCTFail("the first 32 commands should queue") }
        }
        guard case let .unsupported(reason) = adapter.encode(
            command: "prompt", id: "cmd-overflow", payload: ["message": .string("x")]
        ) else { return XCTFail("an overflowing queue must fail loudly, not silently drop") }
        XCTAssertTrue(reason.contains("starting"))
    }

    // MARK: - Turn lifecycle

    func testTurnLifecycleSettlesExactlyOnce() throws {
        let adapter = try started()
        let started = adapter.decode(line: notification("turn/started", [
            "threadId": "thread-1", "turn": ["id": "turn-1", "status": "inProgress", "items": []]
        ]))
        XCTAssertEqual(eventTypes(started), ["agent_start", "turn_start"])
        // A duplicate start for the same turn must not restart the composer state.
        XCTAssertTrue(adapter.decode(line: notification("turn/started", [
            "threadId": "thread-1", "turn": ["id": "turn-1", "status": "inProgress", "items": []]
        ])).isEmpty)

        let completed = adapter.decode(line: notification("turn/completed", [
            "threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed", "items": []]
        ]))
        XCTAssertEqual(eventTypes(completed), ["turn_end", "agent_settled"])

        let repeated = adapter.decode(line: notification("turn/completed", [
            "threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed", "items": []]
        ]))
        XCTAssertTrue(repeated.isEmpty, "agent_settled must fire exactly once per turn")
    }

    func testFailedTurnReportsTheErrorAndStillSettles() throws {
        let adapter = try started()
        _ = adapter.decode(line: notification("turn/started", [
            "turn": ["id": "turn-9", "status": "inProgress", "items": []]
        ]))
        let events = adapter.decode(line: notification("turn/completed", [
            "turn": [
                "id": "turn-9", "status": "failed", "items": [],
                "error": ["message": "the model stream broke"]
            ]
        ])).compactMap(event)
        XCTAssertEqual(events.map { $0["type"]?.stringValue }, ["message_end", "turn_end", "agent_settled"])
        XCTAssertEqual(events[0]["message"]?["stopReason"]?.stringValue, "error")
        XCTAssertEqual(
            events[0]["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "the model stream broke"
        )
    }

    func testInterruptedTurnClosesItsOpenToolRow() throws {
        let adapter = try started()
        _ = adapter.decode(line: notification("turn/started", [
            "turn": ["id": "turn-3", "status": "inProgress", "items": []]
        ]))
        _ = adapter.decode(line: notification("item/started", [
            "threadId": "thread-1", "turnId": "turn-3", "startedAtMs": 1,
            "item": ["type": "commandExecution", "id": "item-3", "command": "sleep 300", "cwd": "/tmp", "status": "inProgress"]
        ]))
        let events = adapter.decode(line: notification("turn/completed", [
            "turn": ["id": "turn-3", "status": "interrupted", "items": []]
        ])).compactMap(event)
        XCTAssertEqual(events.map { $0["type"]?.stringValue }, ["tool_execution_end", "turn_end", "agent_settled"])
        XCTAssertEqual(events[0]["toolCallId"]?.stringValue, "item-3")
        XCTAssertEqual(events[0]["isError"]?.boolValue, true)
    }

    // MARK: - Streaming

    func testAgentMessageDeltasAccumulateAndCompleteAsOneMessage() throws {
        let adapter = try started()
        let start = adapter.decode(line: notification("item/started", [
            "threadId": "thread-1", "turnId": "turn-1", "startedAtMs": 1,
            "item": ["type": "agentMessage", "id": "msg-1", "text": ""]
        ]))
        XCTAssertEqual(eventTypes(start), ["message_start"])

        let first = adapter.decode(line: notification("item/agentMessage/delta", [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "msg-1", "delta": "Hello"
        ])).compactMap(event)
        XCTAssertEqual(first.first?["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "Hello")

        let second = adapter.decode(line: notification("item/agentMessage/delta", [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "msg-1", "delta": " there"
        ])).compactMap(event)
        XCTAssertEqual(second.first?["type"]?.stringValue, "message_update")
        XCTAssertEqual(
            second.first?["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "Hello there"
        )

        let end = adapter.decode(line: notification("item/completed", [
            "threadId": "thread-1", "turnId": "turn-1", "completedAtMs": 2,
            "item": ["type": "agentMessage", "id": "msg-1", "text": "Hello there."]
        ])).compactMap(event)
        XCTAssertEqual(end.map { $0["type"]?.stringValue }, ["message_end"])
        XCTAssertEqual(end[0]["message"]?["role"]?.stringValue, "assistant")
        XCTAssertEqual(end[0]["message"]?["stopReason"]?.stringValue, "stop")
        XCTAssertEqual(end[0]["message"]?["provider"]?.stringValue, "openai")
        XCTAssertEqual(
            end[0]["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "Hello there."
        )
    }

    func testReasoningDeltasBecomeThinkingBlocks() throws {
        let adapter = try started()
        _ = adapter.decode(line: notification("item/started", [
            "threadId": "thread-1", "turnId": "turn-1", "startedAtMs": 1,
            "item": ["type": "reasoning", "id": "think-1"]
        ]))
        let update = adapter.decode(line: notification("item/reasoning/summaryTextDelta", [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "think-1", "summaryIndex": 0, "delta": "Considering"
        ])).compactMap(event)
        let block = try XCTUnwrap(update.first?["message"]?["content"]?.arrayValue?.first)
        XCTAssertEqual(block["type"]?.stringValue, "thinking")
        XCTAssertEqual(block["thinking"]?.stringValue, "Considering")

        let end = adapter.decode(line: notification("item/completed", [
            "threadId": "thread-1", "turnId": "turn-1", "completedAtMs": 2,
            "item": ["type": "reasoning", "id": "think-1", "summary": ["Considering the options"], "content": []]
        ])).compactMap(event)
        XCTAssertEqual(end.map { $0["type"]?.stringValue }, ["message_end"])
        XCTAssertEqual(
            end[0]["message"]?["content"]?.arrayValue?.first?["thinking"]?.stringValue,
            "Considering the options"
        )
    }

    func testCommandExecutionProducesStartUpdateAndEndToolEvents() throws {
        let adapter = try started()
        let start = adapter.decode(line: notification("item/started", [
            "threadId": "thread-1", "turnId": "turn-1", "startedAtMs": 1,
            "item": [
                "type": "commandExecution", "id": "exec-1",
                "command": "swift test", "cwd": "/tmp/pi", "status": "inProgress"
            ]
        ])).compactMap(event)
        XCTAssertEqual(start.map { $0["type"]?.stringValue }, ["tool_execution_start"])
        XCTAssertEqual(start[0]["toolCallId"]?.stringValue, "exec-1")
        XCTAssertEqual(start[0]["toolName"]?.stringValue, "bash")
        XCTAssertEqual(start[0]["args"]?["command"]?.stringValue, "swift test")
        XCTAssertEqual(start[0]["args"]?["cwd"]?.stringValue, "/tmp/pi")

        let update = adapter.decode(line: notification("item/commandExecution/outputDelta", [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "exec-1", "delta": "Compiling"
        ])).compactMap(event)
        XCTAssertEqual(update.map { $0["type"]?.stringValue }, ["tool_execution_update"])
        XCTAssertEqual(
            update[0]["partialResult"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "Compiling"
        )

        let end = adapter.decode(line: notification("item/completed", [
            "threadId": "thread-1", "turnId": "turn-1", "completedAtMs": 2,
            "item": [
                "type": "commandExecution", "id": "exec-1", "command": "swift test", "cwd": "/tmp/pi",
                "status": "failed", "exitCode": 1, "aggregatedOutput": "1 test failed"
            ]
        ])).compactMap(event)
        XCTAssertEqual(end.map { $0["type"]?.stringValue }, ["tool_execution_end"])
        XCTAssertEqual(end[0]["isError"]?.boolValue, true)
        XCTAssertEqual(
            end[0]["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
            "1 test failed"
        )
        // The row is closed, so the next turn end must not report it as interrupted.
        let settled = adapter.decode(line: notification("turn/completed", [
            "turn": ["id": "turn-1", "status": "completed", "items": []]
        ]))
        XCTAssertEqual(eventTypes(settled), ["turn_end", "agent_settled"])
    }

    // MARK: - Models and thinking levels

    func testModelListMapsVisibleModelsOnly() throws {
        let adapter = try started()
        _ = adapter.decode(line: response(id: 3, result: ["data": [
            [
                "id": "gpt-5.1-codex", "model": "gpt-5.1-codex", "displayName": "GPT-5.1 Codex",
                "description": "", "hidden": false, "isDefault": true, "defaultReasoningEffort": "medium",
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": ""],
                    ["reasoningEffort": "medium", "description": ""],
                    ["reasoningEffort": "high", "description": ""]
                ]
            ],
            [
                "id": "internal-preview", "model": "internal-preview", "displayName": "Internal",
                "description": "", "hidden": true, "isDefault": false, "defaultReasoningEffort": "low",
                "supportedReasoningEfforts": []
            ]
        ]]))

        guard case let .immediate(models) = adapter.encode(command: "get_available_models", id: "m", payload: [:])
        else { return XCTFail("a cached model list should answer without a round trip") }
        XCTAssertEqual(models["models"]?.arrayValue?.count, 1)
        let model = try XCTUnwrap(models["models"]?.arrayValue?.first)
        XCTAssertEqual(model["provider"]?.stringValue, "openai")
        XCTAssertEqual(model["id"]?.stringValue, "gpt-5.1-codex")
        XCTAssertEqual(model["name"]?.stringValue, "GPT-5.1 Codex")
        XCTAssertEqual(model["reasoning"]?.boolValue, true)

        guard case let .immediate(levels) = adapter.encode(
            command: "get_available_thinking_levels", id: "l", payload: [:]
        ) else { return XCTFail("thinking levels come from the selected model") }
        XCTAssertEqual(levels["levels"]?.arrayValue?.compactMap(\.stringValue), ["low", "medium", "high"])

        guard case let .immediate(selected) = adapter.encode(
            command: "set_model", id: "s", payload: ["provider": .string("openai"), "modelId": .string("gpt-5.1-codex")]
        ) else { return XCTFail("set_model applies to the next turn and answers immediately") }
        XCTAssertEqual(selected["id"]?.stringValue, "gpt-5.1-codex")
        XCTAssertEqual(selected["name"]?.stringValue, "GPT-5.1 Codex")

        guard case let .immediate(state) = adapter.encode(command: "get_state", id: "g", payload: [:])
        else { return XCTFail("get_state is answered from adapter state") }
        XCTAssertEqual(state["sessionId"]?.stringValue, "thread-1")
        XCTAssertEqual(state["model"]?["id"]?.stringValue, "gpt-5.1-codex")
        XCTAssertEqual(state["isStreaming"]?.boolValue, false)
    }

    func testThinkingLevelRoundTripsThroughCodexEffortNames() throws {
        let adapter = try started()
        guard case .immediate = adapter.encode(
            command: "set_thinking_level", id: "t", payload: ["level": .string("high")]
        ) else { return XCTFail("set_thinking_level is applied on the next turn") }

        guard case let .write(lines) = adapter.encode(
            command: "prompt", id: "p", payload: ["message": .string("go")]
        ) else { return XCTFail("prompt starts a turn") }
        XCTAssertEqual(try object(lines[0])["params"]?["effort"]?.stringValue, "high")
        XCTAssertEqual(CodexProtocolAdapter.thinkingLevel(forEffort: "none"), "off")
        XCTAssertEqual(CodexProtocolAdapter.codexEffort(forLevel: "off"), "none")
    }

    // MARK: - Prompt routing

    func testPromptStartsATurnAndSteersOneAlreadyInFlight() throws {
        let adapter = try started()
        guard case let .write(startLines) = adapter.encode(
            command: "prompt", id: "p1", payload: ["message": .string("first")]
        ) else { return XCTFail("with no turn in flight a prompt starts one") }
        let start = try object(startLines[0])
        XCTAssertEqual(start["method"]?.stringValue, "turn/start")
        XCTAssertEqual(start["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, "first")

        _ = adapter.decode(line: notification("turn/started", [
            "turn": ["id": "turn-7", "status": "inProgress", "items": []]
        ]))

        guard case let .write(steerLines) = adapter.encode(
            command: "prompt", id: "p2", payload: ["message": .string("actually, this")]
        ) else { return XCTFail("a prompt mid-turn steers it") }
        let steer = try object(steerLines[0])
        XCTAssertEqual(steer["method"]?.stringValue, "turn/steer")
        XCTAssertEqual(steer["params"]?["expectedTurnId"]?.stringValue, "turn-7")
        XCTAssertEqual(steer["params"]?["threadId"]?.stringValue, "thread-1")

        guard case let .write(abortLines) = adapter.encode(command: "abort", id: "a1", payload: [:])
        else { return XCTFail("abort interrupts the live turn") }
        let interrupt = try object(abortLines[0])
        XCTAssertEqual(interrupt["method"]?.stringValue, "turn/interrupt")
        XCTAssertEqual(interrupt["params"]?["turnId"]?.stringValue, "turn-7")

        _ = adapter.decode(line: notification("turn/completed", [
            "turn": ["id": "turn-7", "status": "interrupted", "items": []]
        ]))
        guard case .immediate = adapter.encode(command: "abort", id: "a2", payload: [:])
        else { return XCTFail("aborting an idle session is a no-op, not an error") }
    }

    func testPromptImagesBecomeCodexImageInput() throws {
        let adapter = try started()
        guard case let .write(lines) = adapter.encode(command: "prompt", id: "p", payload: [
            "message": .string("look"),
            "images": .array([.object([
                "type": .string("image"), "data": .string("AAAA"), "mimeType": .string("image/png")
            ])])
        ]) else { return XCTFail("prompt with an attachment starts a turn") }
        let input = try XCTUnwrap(object(lines[0])["params"]?["input"]?.arrayValue)
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[1]["type"]?.stringValue, "image")
        XCTAssertEqual(input[1]["url"]?.stringValue, "data:image/png;base64,AAAA")
    }

    // MARK: - Approvals

    func testCommandApprovalBecomesADialogAndTheAnswerIsEncodedBack() throws {
        let adapter = try started()
        let events = adapter.decode(line: serverRequest(id: 41, method: "item/commandExecution/requestApproval", params: [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "exec-2", "startedAtMs": 1,
            "command": "rm -rf build", "cwd": "/tmp/pi"
        ])).compactMap(event)
        XCTAssertEqual(events.map { $0["type"]?.stringValue }, ["extension_ui_request"])
        let dialog = events[0]
        XCTAssertEqual(dialog["method"]?.stringValue, "select")
        XCTAssertEqual(dialog["options"]?.arrayValue?.count, 3)
        XCTAssertTrue(dialog["message"]?.stringValue?.contains("rm -rf build") == true)
        let dialogID = try XCTUnwrap(dialog["id"]?.stringValue)

        let approve = adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"),
            "id": .string(dialogID),
            "value": .string(try XCTUnwrap(dialog["options"]?.arrayValue?.first?.stringValue))
        ]))
        XCTAssertEqual(approve.count, 1)
        let reply = try object(approve[0])
        XCTAssertEqual(reply["id"]?.intValue, 41)
        XCTAssertEqual(reply["result"]?["decision"]?.stringValue, "accept")

        // The dialog is consumed: a second answer for the same id writes nothing.
        XCTAssertTrue(adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string(dialogID), "value": .string("Approve")
        ])).isEmpty)
    }

    func testDeclinedFileChangeApprovalIsEncodedAsADecline() throws {
        let adapter = try started()
        let events = adapter.decode(line: serverRequest(id: 42, method: "item/fileChange/requestApproval", params: [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "patch-1", "startedAtMs": 1,
            "reason": "writes outside the workspace"
        ])).compactMap(event)
        let dialogID = try XCTUnwrap(events.first?["id"]?.stringValue)
        let reply = try object(adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string(dialogID), "value": .string("Decline")
        ]))[0])
        XCTAssertEqual(reply["result"]?["decision"]?.stringValue, "decline")

        let cancelled = adapter.decode(line: serverRequest(id: 43, method: "applyPatchApproval", params: [
            "callId": "call-1", "conversationId": "thread-1", "fileChanges": ["/tmp/pi/main.swift": [:]]
        ])).compactMap(event)
        let legacyID = try XCTUnwrap(cancelled.first?["id"]?.stringValue)
        let legacyReply = try object(adapter.encodeUncorrelated(.object([
            "type": .string("extension_ui_response"), "id": .string(legacyID), "cancelled": .bool(true)
        ]))[0])
        XCTAssertEqual(legacyReply["result"]?["decision"]?.stringValue, "abort")
    }

    // MARK: - Retries, compaction, naming, usage

    func testRetryableErrorOpensAndClosesARetryWindow() throws {
        let adapter = try started()
        let retry = adapter.decode(line: notification("error", [
            "threadId": "thread-1", "turnId": "turn-1",
            "error": ["message": "stream disconnected"], "willRetry": true
        ])).compactMap(event)
        XCTAssertEqual(retry.map { $0["type"]?.stringValue }, ["auto_retry_start"])
        XCTAssertEqual(retry[0]["attempt"]?.intValue, 1)
        XCTAssertEqual(retry[0]["errorMessage"]?.stringValue, "stream disconnected")

        let resumed = adapter.decode(line: notification("item/started", [
            "threadId": "thread-1", "turnId": "turn-1", "startedAtMs": 1,
            "item": ["type": "agentMessage", "id": "msg-2", "text": ""]
        ])).compactMap(event)
        XCTAssertEqual(resumed.map { $0["type"]?.stringValue }, ["auto_retry_end", "message_start"])
        XCTAssertEqual(resumed[0]["success"]?.boolValue, true)
    }

    func testCompactionAndRenameAndUsageAreProjectedIntoAppShapes() throws {
        let adapter = try started()
        guard case let .write(lines) = adapter.encode(command: "compact", id: "c1", payload: [:])
        else { return XCTFail("compact is a real request") }
        XCTAssertEqual(try object(lines[0])["method"]?.stringValue, "thread/compact/start")

        let accepted = adapter.decode(line: response(id: 4, result: [:]))
        XCTAssertEqual(eventTypes(accepted), ["compaction_start"])
        XCTAssertEqual(responseIDs(accepted), ["c1"])

        let compacted = adapter.decode(line: notification("thread/compacted", [
            "threadId": "thread-1", "turnId": "turn-1"
        ]))
        XCTAssertEqual(eventTypes(compacted), ["compaction_end"])

        let renamed = adapter.decode(line: notification("thread/name/updated", [
            "threadId": "thread-1", "threadName": "Codex adapter"
        ])).compactMap(event)
        XCTAssertEqual(renamed.map { $0["type"]?.stringValue }, ["session_info_changed"])
        XCTAssertEqual(renamed[0]["name"]?.stringValue, "Codex adapter")

        _ = adapter.decode(line: notification("thread/tokenUsage/updated", [
            "threadId": "thread-1", "turnId": "turn-1",
            "tokenUsage": [
                "last": [
                    "inputTokens": 1_200, "cachedInputTokens": 200, "outputTokens": 50,
                    "reasoningOutputTokens": 10, "totalTokens": 1_250
                ],
                "total": [
                    "inputTokens": 2_400, "cachedInputTokens": 400, "outputTokens": 100,
                    "reasoningOutputTokens": 20, "totalTokens": 2_500
                ],
                "modelContextWindow": 10_000
            ]
        ]))
        guard case let .immediate(stats) = adapter.encode(command: "get_session_stats", id: "st", payload: [:])
        else { return XCTFail("stats come from the tracked usage") }
        XCTAssertEqual(stats["tokens"]?["input"]?.intValue, 2_000)
        XCTAssertEqual(stats["tokens"]?["cacheRead"]?.intValue, 400)
        XCTAssertEqual(stats["tokens"]?["output"]?.intValue, 100)
        XCTAssertEqual(stats["contextUsage"]?["contextWindow"]?.intValue, 10_000)
        XCTAssertEqual(stats["contextUsage"]?["percent"]?.intValue, 25)
    }

    func testSkillsBecomeCommands() throws {
        let adapter = try started()
        guard case let .write(lines) = adapter.encode(command: "get_commands", id: "cmds", payload: [:])
        else { return XCTFail("get_commands asks Codex for its skills") }
        XCTAssertEqual(try object(lines[0])["method"]?.stringValue, "skills/list")

        let inbound = adapter.decode(line: response(id: 4, result: ["data": [[
            "cwd": "/tmp/pi", "errors": [],
            "skills": [["name": "ponytail", "description": "Be lazy", "path": "/skills/ponytail", "enabled": true, "scope": "user"]]
        ]]]))
        let data = try XCTUnwrap(inbound.compactMap(responseValue).first)
        XCTAssertEqual(data["data"]?["commands"]?.arrayValue?.count, 1)
        XCTAssertEqual(data["data"]?["commands"]?.arrayValue?.first?["name"]?.stringValue, "ponytail")
    }

    // MARK: - Degradation

    func testMalformedAndUnknownInputIsIgnored() throws {
        let adapter = try started()
        XCTAssertTrue(adapter.decode(line: Data("not json at all".utf8)).isEmpty)
        XCTAssertTrue(adapter.decode(line: Data("[1,2,3]".utf8)).isEmpty)
        XCTAssertTrue(adapter.decode(line: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(adapter.decode(line: notification("thread/realtime/sdp", ["sdp": "v=0"])).isEmpty)
        XCTAssertTrue(adapter.decode(line: notification("item/started", [
            "item": ["type": "somethingNewCodexAdded", "id": "x"]
        ])).isEmpty)
        XCTAssertTrue(adapter.decode(line: serverRequest(id: 99, method: "attestation/generate", params: [:])).isEmpty)
        XCTAssertTrue(adapter.decode(line: response(id: 4_242, result: [:])).isEmpty)
        XCTAssertTrue(adapter.encodeUncorrelated(.object(["type": .string("nonsense")])).isEmpty)

        guard case let .unsupported(reason) = adapter.encode(command: "export_html", id: "e", payload: [:])
        else { return XCTFail("Codex has no HTML export") }
        XCTAssertTrue(reason.contains("HTML"))
        guard case .unsupported = adapter.encode(command: "get_fork_messages", id: "f", payload: [:])
        else { return XCTFail("Codex has no fork-point listing over this protocol") }
    }

    func testResetDropsPerSessionState() throws {
        let adapter = try started()
        adapter.reset()
        guard case .deferred = adapter.encode(
            command: "prompt", id: "after-reset", payload: ["message": .string("hi")]
        ) else { return XCTFail("after a reset the thread is gone and commands queue again") }
        XCTAssertTrue(adapter.drainPendingWrites().isEmpty)
    }

    // MARK: - Harness

    /// Runs the handshake and leaves the adapter with a live thread (`thread-1`).
    private func started() throws -> CodexProtocolAdapter {
        let adapter = CodexProtocolAdapter()
        _ = adapter.startupLines(sessionPath: nil, cwd: cwd)
        _ = adapter.decode(line: response(id: 1, result: [:]))
        _ = adapter.drainPendingWrites()
        _ = adapter.decode(line: threadStartResponse(id: 2))
        _ = adapter.drainPendingWrites()
        return adapter
    }

    private func threadStartResponse(id: Int) -> Data {
        response(id: id, result: [
            "thread": [
                "id": "thread-1", "sessionId": "session-1", "path": "/tmp/sessions/rollout-x-thread-1.jsonl",
                "cwd": cwd.path, "createdAt": 0, "updatedAt": 0, "cliVersion": "1.0",
                "ephemeral": false, "modelProvider": "openai", "preview": "", "source": "cli",
                "status": "idle", "turns": []
            ],
            "model": "gpt-5.1-codex",
            "modelProvider": "openai",
            "sandbox": "workspace-write",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "cwd": cwd.path
        ])
    }

    private func response(id: Int, result: [String: Any]) -> Data {
        line(["id": id, "result": result])
    }

    private func notification(_ method: String, _ params: [String: Any]) -> Data {
        line(["method": method, "params": params])
    }

    private func serverRequest(id: Int, method: String, params: [String: Any]) -> Data {
        line(["id": id, "method": method, "params": params])
    }

    private func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func object(_ data: Data) throws -> PiJSONValue {
        try PiJSONValue.decode(data)
    }

    private func event(_ inbound: AdapterInbound) -> PiJSONValue? {
        guard case let .event(value) = inbound else { return nil }
        return value
    }

    private func responseValue(_ inbound: AdapterInbound) -> PiJSONValue? {
        guard case let .response(_, value) = inbound else { return nil }
        return value
    }

    private func eventTypes(_ inbound: [AdapterInbound]) -> [String] {
        inbound.compactMap(event).compactMap { $0["type"]?.stringValue }
    }

    private func responseIDs(_ inbound: [AdapterInbound]) -> [String] {
        inbound.compactMap { entry in
            guard case let .response(id, _) = entry else { return nil }
            return id
        }
    }
}

/// Pinned against the real `codex app-server` protocol as observed from the installed binary,
/// so a shape change in Codex shows up here rather than as an empty picker.
final class CodexRealProtocolShapeTests: XCTestCase {
    /// `model/list` reports efforts as objects, not bare strings, and its strongest level is
    /// `ultra` — which the shared picker vocabulary has to accept or it is filtered away.
    func testEveryEffortCodexReportsSurvivesIntoThePicker() {
        let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
        for effort in efforts {
            XCTAssertTrue(
                AgentThinkingLevels.all.contains(
                    CodexProtocolAdapter.thinkingLevel(forEffort: effort)
                ),
                "\(effort) must survive the shared level vocabulary"
            )
        }
        XCTAssertEqual(AgentThinkingLevels.supported(efforts).count, efforts.count)
    }

    func testCodexNoneEffortIsPresentedAsOffAndRoundTrips() {
        XCTAssertEqual(CodexProtocolAdapter.thinkingLevel(forEffort: "none"), "off")
        XCTAssertEqual(CodexProtocolAdapter.thinkingLevel(forEffort: nil), "off")
        XCTAssertEqual(CodexProtocolAdapter.codexEffort(forLevel: "off"), "none")
        for effort in ["low", "medium", "high", "xhigh", "max", "ultra"] {
            XCTAssertEqual(
                CodexProtocolAdapter.codexEffort(forLevel: CodexProtocolAdapter.thinkingLevel(forEffort: effort)),
                effort
            )
        }
    }

    /// Pi's own reported levels must be unaffected by widening the shared vocabulary.
    func testPiLevelsAreUnchangedByTheWiderVocabulary() {
        XCTAssertEqual(
            AgentThinkingLevels.supported(["off", "low", "medium", "high"]),
            ["off", "low", "medium", "high"]
        )
    }
}

/// Both of these were found by driving the real `codex app-server`, not by fixtures: the adapter
/// answered a session query before it had a session, and the answer never reached a caller
/// waiting the ordinary way.
final class CodexHandshakeOrderingTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/tmp/project")

    private func responses(_ inbound: [AdapterInbound]) -> [(String, PiJSONValue)] {
        inbound.compactMap { if case let .response(id, value) = $0 { (id, value) } else { nil } }
    }

    private func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object.merging(["jsonrpc": "2.0"]) { a, _ in a })) ?? Data()
    }

    /// Runs `initialize` -> `initialized` -> `thread/start` using the ids the adapter actually
    /// generated, read back off the wire rather than guessed.
    @discardableResult
    private func completeHandshake(
        _ adapter: CodexProtocolAdapter, thread: [String: Any] = ["id": "thread-9", "path": "/tmp/r.jsonl"],
        result extra: [String: Any] = ["model": "gpt-5.6-sol", "reasoningEffort": "high"]
    ) -> [AdapterInbound] {
        let initializeID = requestID(in: adapter.startupLines(sessionPath: nil, cwd: cwd).first ?? Data())
        _ = adapter.decode(line: line(["id": initializeID as Any, "result": [String: Any]()]))
        let startID = requestID(forMethod: "thread/start", in: adapter.drainPendingWrites())
        return adapter.decode(line: line([
            "id": startID as Any, "result": extra.merging(["thread": thread]) { a, _ in a }
        ]))
    }

    private func requestID(in data: Data) -> Any? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"]
    }

    /// The handshake emits `initialized`, `thread/start`, and `model/list` together, so the id
    /// has to be picked by method rather than by position.
    private func requestID(forMethod method: String, in lines: [Data]) -> Any? {
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["method"] as? String == method else { continue }
            return object["id"]
        }
        return nil
    }

    /// `get_state` before the handshake used to answer immediately from empty state, so the
    /// caller learned the thread had no id and never corrected itself.
    func testSessionQueriesWaitForTheThreadInsteadOfAnsweringEmpty() throws {
        let adapter = CodexProtocolAdapter()
        let initializeID = requestID(in: adapter.startupLines(sessionPath: nil, cwd: cwd).first ?? Data())

        for command in CodexProtocolAdapter.answeredFromAdapterState {
            guard case .deferred = adapter.encode(command: command, id: "q-\(command)", payload: [:]) else {
                return XCTFail("\(command) must wait for the thread rather than answer empty")
            }
        }

        // Complete the handshake; every held query is answered from the state it produced.
        _ = adapter.decode(line: line(["id": initializeID as Any, "result": [String: Any]()]))
        let startID = requestID(forMethod: "thread/start", in: adapter.drainPendingWrites())
        let inbound = adapter.decode(line: line([
            "id": startID as Any,
            "result": [
                "thread": ["id": "thread-9", "path": "/tmp/r.jsonl"],
                "model": "gpt-5.6-sol", "reasoningEffort": "high"
            ]
        ]))

        let answered = responses(inbound)
        XCTAssertEqual(
            Set(answered.map(\.0)),
            Set(CodexProtocolAdapter.answeredFromAdapterState.map { "q-\($0)" }),
            "every held query must be answered exactly once"
        )
        let state = try XCTUnwrap(answered.first { $0.0 == "q-get_state" }?.1)
        XCTAssertEqual(state["data"]?["sessionId"]?.stringValue, "thread-9")
        XCTAssertEqual(state["data"]?["model"]?["id"]?.stringValue, "gpt-5.6-sol")
        XCTAssertEqual(state["data"]?["thinkingLevel"]?.stringValue, "high")
    }

    /// Once the thread exists the same query is answered without a round trip.
    func testSessionQueriesAnswerImmediatelyOnceTheThreadExists() throws {
        let adapter = CodexProtocolAdapter()
        completeHandshake(adapter, thread: ["id": "t", "path": "/tmp/r.jsonl"], result: ["model": "m"])

        guard case let .immediate(value) = adapter.encode(command: "get_state", id: "s", payload: [:]) else {
            return XCTFail("an established session answers without waiting")
        }
        XCTAssertEqual(value["sessionId"]?.stringValue, "t")
    }

    /// A queued command that turns out to be unsupported must still complete its caller.
    func testAHeldCommandWithNoEquivalentIsAnsweredNotStranded() {
        let adapter = CodexProtocolAdapter()
        let initializeID = requestID(in: adapter.startupLines(sessionPath: nil, cwd: cwd).first ?? Data())
        guard case .deferred = adapter.encode(command: "export_html", id: "x", payload: [:]) else {
            // `export_html` is refused up front, which is also a complete answer.
            return
        }
        _ = adapter.decode(line: line(["id": initializeID as Any, "result": [String: Any]()]))
        let startID = requestID(forMethod: "thread/start", in: adapter.drainPendingWrites())
        let inbound = adapter.decode(line: line([
            "id": startID as Any, "result": ["thread": ["id": "t"], "model": "m"]
        ]))
        XCTAssertTrue(responses(inbound).contains { $0.0 == "x" }, "a held command must always complete")
    }
}
