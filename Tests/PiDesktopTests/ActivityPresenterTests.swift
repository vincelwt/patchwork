import Foundation
import XCTest
@testable import PiDesktop

final class ActivityPresenterTests: XCTestCase {
    func testAgentOperationsCollapseIntoOneMetadataRow() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let messages = [
            assistant(
                id: "spawn-message",
                callID: "spawn",
                name: "Agent",
                arguments: [
                    "subagent_type": .string("UI"),
                    "description": .string("Trace agent sidebar UI"),
                    "run_in_background": .bool(true)
                ],
                at: startedAt,
                model: "gpt-5.6-sol"
            ),
            result(
                id: "spawn-result",
                callID: "spawn",
                text: "Agent started in background.",
                at: startedAt.addingTimeInterval(1),
                details: .object([
                    "agentId": .string("agent-1"),
                    "subagentType": .string("UI"),
                    "modelName": .string("opus 5"),
                    "description": .string("Trace agent sidebar UI"),
                    "toolUses": .number(0),
                    "durationMs": .number(0),
                    "status": .string("background")
                ])
            ),
            assistant(
                id: "wait-message",
                callID: "wait",
                name: "get_subagent_result",
                arguments: ["agent_id": .string("agent-1"), "wait": .bool(true)],
                at: startedAt.addingTimeInterval(2),
                model: "gpt-5.6-sol"
            ),
            result(
                id: "wait-result",
                callID: "wait",
                text: """
                Agent: agent-1
                Type: UI | Status: completed | Tool uses: 46 | Duration: 179.8s
                Description: Trace agent sidebar UI
                """,
                at: startedAt.addingTimeInterval(180)
            )
        ]

        let items = ActivityPresenter().activities(from: messages)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "Trace agent sidebar UI")
        XCTAssertEqual(item.agentType, "UI")
        XCTAssertEqual(item.modelName, "opus 5")
        XCTAssertEqual(item.toolCallCount, 46)
        XCTAssertEqual(try XCTUnwrap(item.duration), 179.8, accuracy: 0.001)
        XCTAssertEqual(item.status, .succeeded)
        XCTAssertEqual(item.agentSummary(), "UI · Opus 5 · 46 calls / 3m")
    }

    func testBackgroundAgentResultStaysRunningAndRetainsResolvedModel() throws {
        let event: JSONValue = .object([
            "toolCallId": .string("spawn"),
            "toolName": .string("Agent"),
            "args": .object([
                "subagent_type": .string("Explore"),
                "description": .string("Trace runtime")
            ])
        ])
        var item = try XCTUnwrap(ActivityPresenter.activityForToolStart(event: event, modelName: "gpt-5.6-sol"))
        ActivityPresenter.applyResult(
            .object([
                "details": .object([
                    "agentId": .string("agent-2"),
                    "subagentType": .string("Explore"),
                    "modelName": .string("gpt-5.6 terra"),
                    "toolUses": .number(0),
                    "durationMs": .number(0),
                    "status": .string("background")
                ])
            ]),
            finished: true,
            endedAt: Date(),
            to: &item
        )

        XCTAssertEqual(item.title, "Trace runtime")
        XCTAssertEqual(item.agentID, "agent-2")
        XCTAssertEqual(item.agentType, "Explore")
        XCTAssertEqual(item.modelName, "gpt-5.6 terra")
        XCTAssertNil(item.toolCallCount)
        XCTAssertEqual(item.status, .running)
        XCTAssertNil(item.endedAt)
    }

    private func assistant(
        id: String,
        callID: String,
        name: String,
        arguments: [String: JSONValue],
        at date: Date,
        model: String
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            blocks: [MessageBlock(
                id: "block-\(callID)",
                kind: .toolCall(ToolCallPayload(id: callID, name: name, arguments: .object(arguments)))
            )],
            timestamp: date,
            modelName: model,
            raw: .null
        )
    }

    private func result(
        id: String,
        callID: String,
        text: String,
        at date: Date,
        details: JSONValue? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .tool,
            blocks: [MessageBlock(id: "block-\(id)", kind: .text(text))],
            timestamp: date,
            toolCallID: callID,
            details: details,
            raw: .null
        )
    }
}
