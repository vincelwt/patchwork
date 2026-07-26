import Foundation
import XCTest
@testable import PiDesktop

final class TranscriptPresenterTests: XCTestCase {
    func testConsecutiveCallsAndResultsRollUpUntilAssistantProse() throws {
        let messages = [
            assistant(id: "a1", blocks: [text("I’ll inspect it."), call("c1", "read", ["path": .string("A.swift")])]),
            result(id: "r1", callID: "c1", text: "contents"),
            assistant(id: "a2", blocks: [call("c2", "grep", ["pattern": .string("TODO")])]),
            result(id: "r2", callID: "c2", text: "A.swift:2"),
            assistant(id: "a3", blocks: [text("Here is the answer.")])
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        XCTAssertEqual(items.count, 3, "prose, one rollup, and final prose should remain")
        guard case let .activity(group) = items[1] else { return XCTFail("Expected a rollup") }
        XCTAssertEqual(group.steps.map(\.id), ["c1", "c2"])
        XCTAssertEqual(group.summary, "Read files")
        XCTAssertFalse(group.isActive)
        XCTAssertEqual(group.completedCount, 2)
    }

    func testLiveRollupCombinesUniqueKindsAndReportsCurrentStep() throws {
        let messages = [
            assistant(id: "a", blocks: [
                call("c1", "bash", ["command": .string("swift test")]),
                call("c2", "chrome_js", ["title": .string("Inspect")])
            ]),
            result(id: "r", callID: "c1", text: "ok")
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: assistant(id: "stream", blocks: []))
        guard case let .activity(group) = items.first else { return XCTFail("Expected a rollup") }
        XCTAssertEqual(group.kinds, [.commands, .browser])
        XCTAssertEqual(group.summary, "Ran commands and Used browser")
        XCTAssertTrue(group.isActive)
        XCTAssertEqual(group.currentStep?.id, "c2")
        XCTAssertEqual(group.progressText, "Step 2 of 2")
    }

    func testFailedResultRemainsVisibleInCollapsedGroupData() throws {
        let messages = [
            assistant(id: "a", blocks: [call("c", "edit", ["path": .string("A.swift")])]),
            result(id: "r", callID: "c", text: "permission denied", failed: true),
            assistant(id: "done", blocks: [text("I could not edit it.")])
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .activity(group) = items.first else { return XCTFail("Expected a rollup") }
        XCTAssertTrue(group.hasFailure)
        XCTAssertFalse(group.shouldStartExpanded, "A completed turn stays collapsed even when its summary reports failure")
        XCTAssertEqual(group.steps.first?.result?.textContent, "permission denied")

        var liveFailure = group
        liveFailure.isActive = true
        XCTAssertFalse(liveFailure.shouldStartExpanded, "Live failures remain high-level until the user expands them")
    }

    func testEveryDocumentedToolKindHasAReadableMapping() {
        let cases: [(String, ToolActivityKind)] = [
            ("bash", .commands), ("read", .filesRead), ("grep", .filesRead), ("find", .filesRead), ("ls", .filesRead),
            ("edit", .filesEdited), ("write", .filesEdited), ("web_search", .web), ("fetch_content", .web),
            ("get_search_content", .web), ("source_check", .web), ("chrome_js", .browser), ("chrome_tabs", .browser),
            ("computer_js", .computer), ("observe_ui", .computer), ("act_ui", .computer), ("find_roots", .computer),
            ("Agent", .agents), ("get_subagent_result", .agents), ("steer_subagent", .agents), ("subagent_wait", .agents),
            ("process", .processes), ("imagegen", .image), ("ask_user_question", .question), ("future_tool", .tool)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(ToolActivityKind.classify(toolName: name), expected, name)
        }
    }

    private func assistant(id: String, blocks: [MessageBlock]) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, blocks: blocks, timestamp: nil, raw: .null)
    }

    private func text(_ value: String) -> MessageBlock {
        MessageBlock(id: UUID().uuidString, kind: .text(value))
    }

    private func call(_ id: String, _ name: String, _ arguments: [String: JSONValue]) -> MessageBlock {
        MessageBlock(id: "block-\(id)", kind: .toolCall(ToolCallPayload(id: id, name: name, arguments: .object(arguments))))
    }

    private func result(id: String, callID: String, text value: String, failed: Bool = false) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .tool,
            blocks: [text(value)],
            timestamp: nil,
            toolCallID: callID,
            isError: failed,
            raw: .null
        )
    }
}

final class RuntimePickerStateTests: XCTestCase {
    func testModelsParseDeduplicateAndKeepRPCOrder() {
        let value: JSONValue = .array([
            .object(["provider": .string("openai"), "id": .string("gpt-5"), "name": .string("GPT-5"), "reasoning": .bool(true)]),
            .object(["provider": .string("anthropic"), "id": .string("sonnet"), "name": .string("Sonnet")]),
            .object(["provider": .string("openai"), "id": .string("gpt-5"), "name": .string("duplicate")]),
            .object(["id": .string("missing-provider")])
        ])
        let models = AvailableModel.parse(value)
        XCTAssertEqual(models.map(\.id), ["openai/gpt-5", "anthropic/sonnet"])
        XCTAssertTrue(models[0].reasoning)
        XCTAssertEqual(RuntimePickerState.selectedModel(in: models, provider: "anthropic", modelID: "sonnet")?.name, "Sonnet")
    }

    func testThinkingLevelsFollowRPCSupportAndNormalizeSelection() {
        let levels = RuntimePickerState.thinkingLevels(from: .array([.string("high"), .string("off"), .string("xhigh"), .string("future")]))
        XCTAssertEqual(levels, ["off", "high", "xhigh"])
        XCTAssertEqual(RuntimePickerState.selectedThinkingLevel(in: levels, current: "high"), "high")
        XCTAssertEqual(RuntimePickerState.selectedThinkingLevel(in: levels, current: "max"), "off")
        XCTAssertEqual(RuntimePickerState.thinkingLevels(from: .array([])), ["off"])
    }

    func testPickerPresentationPrefersExactChoicesAndFallsBackToCycle() {
        let models = [AvailableModel(provider: "openai", modelID: "gpt-5", name: "GPT-5")]

        // Detached: the label stays visible but inert, in the composer and the status bar alike.
        XCTAssertEqual(RuntimePickerPresentation.model(attached: false, models: models, loading: false), .disabled)
        XCTAssertEqual(RuntimePickerPresentation.thinking(attached: false, levels: ["off", "high"], loading: false), .disabled)

        // Attached with loaded lists: explicit menus.
        XCTAssertEqual(RuntimePickerPresentation.model(attached: true, models: models, loading: false), .menu)
        XCTAssertEqual(RuntimePickerPresentation.thinking(attached: true, levels: ["off", "high"], loading: false), .menu)

        // Attached but the query-only RPCs returned nothing: cycle is the honest fallback.
        XCTAssertEqual(RuntimePickerPresentation.model(attached: true, models: [], loading: false), .cycle)
        XCTAssertEqual(RuntimePickerPresentation.thinking(attached: true, levels: ["off"], loading: false), .cycle)

        // Still loading: never offer a control that would be wrong a moment later.
        XCTAssertEqual(RuntimePickerPresentation.model(attached: true, models: [], loading: true), .disabled)
        XCTAssertEqual(RuntimePickerPresentation.thinking(attached: true, levels: ["off"], loading: true), .disabled)
    }
}

final class CapabilityPresenterTests: XCTestCase {
    func testBrowserCapabilityFindsNestedURLAndTitle() throws {
        let arguments: JSONValue = .object([
            "title": .string("Check account settings"),
            "request": .object(["url": .string("https://example.com/settings")])
        ])
        let capability = try XCTUnwrap(CapabilityPresenter.capability(toolName: "chrome_js", callID: "browser-1", arguments: arguments))
        XCTAssertEqual(capability.kind, .browser)
        XCTAssertEqual(capability.title, "Check account settings")
        XCTAssertEqual(capability.target, "https://example.com/settings")
    }

    func testComputerCapabilityFindsAppAndFutureBrowserNamesDegradeWell() throws {
        let computer = try XCTUnwrap(CapabilityPresenter.capability(
            toolName: "computer_js",
            callID: "computer-1",
            arguments: .object(["input": .object(["app": .string("Xcode"), "selector": .string("Build")])])
        ))
        XCTAssertEqual(computer.kind, .computer)
        XCTAssertEqual(computer.target, "Xcode")

        let future = try XCTUnwrap(CapabilityPresenter.capability(
            toolName: "chrome_navigate",
            callID: "browser-2",
            arguments: .object(["selector": .string("#submit")])
        ))
        XCTAssertEqual(future.kind, .browser)
        XCTAssertEqual(future.target, "#submit")
        XCTAssertNil(CapabilityPresenter.capability(toolName: "read", callID: "read-1", arguments: .object([:])))
    }
}
