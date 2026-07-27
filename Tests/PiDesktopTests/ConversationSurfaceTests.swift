import Foundation
import XCTest
@testable import PiDesktop

final class ConversationScrollMetricsTests: XCTestCase {
    func testPinningUsesViewportGeometry() {
        XCTAssertTrue(ConversationScrollMetrics(
            originY: 920, viewportHeight: 500, documentHeight: 1_500, direction: .down
        ).isNearBottom)
        XCTAssertFalse(ConversationScrollMetrics(
            originY: 700, viewportHeight: 500, documentHeight: 1_500, direction: .up
        ).isNearBottom)
        XCTAssertTrue(ConversationScrollMetrics(
            originY: PiTheme.transcriptScrollEdgeThreshold, viewportHeight: 500,
            documentHeight: 1_500, direction: .up
        ).isNearTop)
    }
}

final class TranscriptPresenterTests: XCTestCase {
    func testTurnCollapsesNarrationAndToolsIntoOneWorkBlock() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let messages = [
            user(id: "u", text: "Inspect it", at: start),
            assistant(id: "a1", blocks: [text("I’ll inspect it."), call("c1", "read", ["path": .string("A.swift")])]),
            result(id: "r1", callID: "c1", text: "contents"),
            assistant(id: "a2", blocks: [call("c2", "grep", ["pattern": .string("TODO")])]),
            result(id: "r2", callID: "c2", text: "A.swift:2"),
            assistant(id: "a3", blocks: [text("Here is the answer.")], at: start.addingTimeInterval(61))
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        XCTAssertEqual(items.count, 3, "user message, one work block, and the answer")
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        XCTAssertFalse(block.isActive, "A settled turn collapses")
        XCTAssertEqual(block.title, "Worked for 1m 1s")

        // Narration keeps its position above the tools it introduced.
        guard case let .note(narration) = block.entries.first else { return XCTFail("Expected narration first") }
        XCTAssertEqual(narration.textContent, "I’ll inspect it.")
        guard case let .activity(group) = block.entries.last else { return XCTFail("Expected a rollup") }
        XCTAssertEqual(group.steps.map(\.id), ["c1", "c2"])
        XCTAssertEqual(group.summary, "Read files")
        XCTAssertEqual(group.completedCount, 2)

        guard case let .message(answer, _) = items[2] else { return XCTFail("Expected the answer") }
        XCTAssertEqual(answer.textContent, "Here is the answer.")
    }

    func testReasoningSplitsTheLogAndStaysInOrder() throws {
        let messages = [
            user(id: "u", text: "Go", at: nil),
            assistant(id: "a1", blocks: [thinking("Checking the build"), call("c1", "bash", ["command": .string("swift build")])]),
            result(id: "r1", callID: "c1", text: "ok"),
            assistant(id: "a2", blocks: [thinking("Now the tests"), call("c2", "bash", ["command": .string("swift test")])]),
            result(id: "r2", callID: "c2", text: "passed"),
            assistant(id: "a3", blocks: [text("Green.")])
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        let shape = block.entries.map { entry -> String in
            switch entry {
            case .thinking: "thinking"
            case .activity: "activity"
            case .note: "note"
            }
        }
        XCTAssertEqual(shape, ["thinking", "activity", "thinking", "activity"])
        XCTAssertEqual(block.stepCount, 2)
    }

    func testLiveTurnStaysOpenAndReportsProgress() throws {
        let messages = [
            user(id: "u", text: "Run it", at: Date(timeIntervalSince1970: 10)),
            assistant(id: "a", blocks: [
                call("c1", "bash", ["command": .string("swift test")]),
                call("c2", "chrome_js", ["title": .string("Inspect")])
            ]),
            result(id: "r", callID: "c1", text: "ok")
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: assistant(id: "stream", blocks: []))
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        XCTAssertTrue(block.isActive, "A turn in flight stays open")
        guard case let .activity(group) = block.entries.last else { return XCTFail("Expected a rollup") }
        XCTAssertEqual(group.kinds, [.commands, .browser])
        XCTAssertEqual(group.summary, "Ran commands and Used browser")
        XCTAssertTrue(group.isActive)
        XCTAssertEqual(group.progressText, "Step 2 of 2")
    }

    func testLiveWorkCollapsesAsAnswerStartsStreaming() throws {
        let messages = [
            user(id: "u", text: "Run it", at: nil),
            assistant(id: "a", blocks: [call("c", "bash", ["command": .string("swift test")])]),
            result(id: "r", callID: "c", text: "ok")
        ]

        let items = TranscriptPresenter.items(
            messages: messages,
            streaming: assistant(id: "stream", blocks: [text("Everything passes.")])
        )

        XCTAssertEqual(items.count, 3)
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        XCTAssertFalse(block.isActive, "The work log collapses when the answer starts")
        guard case let .message(answer, streaming) = items[2] else { return XCTFail("Expected the streaming answer") }
        XCTAssertTrue(streaming)
        XCTAssertEqual(answer.textContent, "Everything passes.")
    }

    func testFailedResultRemainsVisibleInCollapsedGroupData() throws {
        let messages = [
            assistant(id: "a", blocks: [call("c", "edit", ["path": .string("A.swift")])]),
            result(id: "r", callID: "c", text: "permission denied", failed: true),
            assistant(id: "done", blocks: [text("I could not edit it.")])
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .work(block) = items.first else { return XCTFail("Expected a work block") }
        XCTAssertTrue(block.hasFailure)
        guard case let .activity(group) = block.entries.first else { return XCTFail("Expected a rollup") }
        XCTAssertFalse(group.shouldStartExpanded, "A completed turn stays collapsed even when its summary reports failure")
        XCTAssertEqual(group.steps.first?.result?.textContent, "permission denied")
    }

    func testWorkBlockIdentifiesImagesAndQuestionnairesForTurnLevelPresentation() throws {
        let image = ImagePayload(id: "generated-image", data: Data([0]), mimeType: "image/png", fileName: nil)
        let imageResult = ChatMessage(
            id: "image-result",
            role: .tool,
            blocks: [MessageBlock(id: "image-block", kind: .image(image))],
            timestamp: nil,
            toolCallID: "image-call",
            raw: .null
        )
        let messages = [
            assistant(id: "a1", blocks: [call("read-call", "read", [:])]),
            result(id: "read-result", callID: "read-call", text: "plain text"),
            assistant(id: "a2", blocks: [call("image-call", "computer_js", [:])]),
            imageResult,
            assistant(id: "a3", blocks: [call("question-call", "ask_user_question", [:])]),
            result(id: "question-result", callID: "question-call", text: "answered"),
            assistant(id: "done", blocks: [text("Done.")])
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .work(block) = items.first else { return XCTFail("Expected a work block") }
        XCTAssertFalse(block.isActive)
        XCTAssertEqual(block.prominentSteps.map(\.id), ["image-call", "question-call"])
        XCTAssertEqual(block.prominentSteps.first?.result?.images.map(\.id), ["generated-image"])
        XCTAssertTrue(block.prominentSteps.first?.resultTextBlocks.isEmpty == true,
                      "The nested tool detail must not render a second copy of the image")
    }

    // MARK: - "failed" reflects the turn's answer, not any one step

    func testHeaderHidesFailedWhenOnlyAToolStepFailedButTheAnswerSucceeded() throws {
        let messages = [
            user(id: "u", text: "try", at: nil),
            assistant(id: "a1", blocks: [call("c1", "grep", ["pattern": .string("TODO")])]),
            result(id: "r1", callID: "c1", text: "no matches", failed: true),
            assistant(id: "a2", blocks: [text("Nothing found, but that's fine.")])
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        XCTAssertTrue(block.hasFailure, "A failed step is still tracked for the in-log red styling")
        XCTAssertFalse(block.answerFailed, "A successful answer must not flag the collapsed header failed")
    }

    func testHeaderShowsFailedWhenTheFinalAnswerErrored() throws {
        var errorMessage = assistant(id: "a2", blocks: [text("Something went wrong.")])
        errorMessage.isError = true
        let messages = [
            user(id: "u", text: "try", at: nil),
            assistant(id: "a1", blocks: [call("c1", "bash", ["command": .string("swift build")])]),
            result(id: "r1", callID: "c1", text: "ok"),
            errorMessage
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        XCTAssertFalse(block.hasFailure, "No individual step failed")
        XCTAssertTrue(block.answerFailed, "The turn's own answer failed")
    }

    func testEarlierErrorThatPiRecoveredFromDoesNotFlagTheSettledTurn() throws {
        // A turn where an assistant message errored but a *later* assistant message in the same
        // turn (e.g. after an internal retry) went on to answer normally must not be flagged.
        var recovered = assistant(id: "a1", blocks: [text("transient hiccup")])
        recovered.isError = true
        let messages = [
            user(id: "u", text: "try", at: nil),
            recovered,
            assistant(id: "a2", blocks: [call("c1", "bash", ["command": .string("swift build")])]),
            result(id: "r1", callID: "c1", text: "ok"),
            assistant(id: "a3", blocks: [text("All good now.")])
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        XCTAssertFalse(block.answerFailed, "The turn's final answer is what matters, not an earlier retried error")
    }

    // MARK: - The answer is never buried in the work log

    func testProcessUpdateAfterTheAnswerDoesNotCollapseTheAnswerIntoTheWorkLog() throws {
        // Real sessions end a turn with `custom_message` entries (background process updates,
        // model changes) written *after* Pi's answer. Those must not demote the answer.
        let update = ChatMessage(
            id: "custom-1",
            role: .custom,
            blocks: [text("Process 'tests' completed successfully (14s)")],
            timestamp: nil,
            customType: "ad-process:update",
            raw: .null
        )
        let messages = [
            user(id: "u", text: "Run the tests", at: nil),
            assistant(id: "a1", blocks: [call("c1", "bash", ["command": .string("swift test")])]),
            result(id: "r1", callID: "c1", text: "ok"),
            assistant(id: "a2", blocks: [text("All 44 tests pass.")]),
            update
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .message(answer, _) = items[2] else {
            return XCTFail("The answer must stay a visible transcript message, not work-log detail")
        }
        XCTAssertEqual(answer.textContent, "All 44 tests pass.")
        guard case let .work(block) = items[1] else { return XCTFail("Expected the turn's work block above it") }
        XCTAssertFalse(
            block.entries.contains { if case .note = $0 { return true } else { return false } },
            "Nothing prose-like from the answer may be demoted into the collapsed log"
        )
    }

    func testFollowOnToolCallAfterTheAnswerOpensANewTurnInsteadOfBuryingIt() throws {
        let messages = [
            user(id: "u", text: "Go", at: nil),
            assistant(id: "a1", blocks: [thinking("plan"), call("c1", "read", [:]), text("Here is the answer.")]),
            result(id: "r1", callID: "c1", text: "contents"),
            assistant(id: "a2", blocks: [call("c2", "write", [:])]),
            result(id: "r2", callID: "c2", text: "written"),
            assistant(id: "a3", blocks: [text("And now it is saved.")])
        ]

        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        let shape = items.map { item -> String in
            switch item {
            case .message: "message"
            case .work: "work"
            case .compaction: "compaction"
            }
        }
        XCTAssertEqual(shape, ["message", "work", "message", "work", "message"])
        guard case let .message(first, _) = items[2] else { return XCTFail("Expected the first answer") }
        XCTAssertEqual(first.textContent, "Here is the answer.", "Prose written after tool calls is the answer")
        guard case let .message(second, _) = items[4] else { return XCTFail("Expected the second answer") }
        XCTAssertEqual(second.textContent, "And now it is saved.")
    }

    func testOrphanToolResultAfterTheAnswerStillShowsWithoutHidingTheAnswer() throws {
        let messages = [
            assistant(id: "a1", blocks: [call("c1", "bash", [:])]),
            result(id: "r1", callID: "c1", text: "ok"),
            assistant(id: "a2", blocks: [text("Done.")]),
            result(id: "r2", callID: "missing-call", text: "late output")
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        guard case let .message(answer, _) = items[1] else { return XCTFail("The answer stays visible") }
        XCTAssertEqual(answer.textContent, "Done.")
        guard case let .work(orphanTurn) = items[2] else { return XCTFail("The orphan result opens its own work block") }
        XCTAssertEqual(orphanTurn.activities.flatMap(\.steps).map(\.id), ["missing-call"])
    }

    func testNarrationBeforeToolsIsStillDemotedIntoTheWorkLog() throws {
        // The other half of the rule: prose that *precedes* the work it introduces is narration,
        // even when it arrives as its own assistant message.
        let messages = [
            user(id: "u", text: "Go", at: nil),
            assistant(id: "a1", blocks: [text("Let me look.")]),
            assistant(id: "a2", blocks: [call("c1", "read", [:])]),
            result(id: "r1", callID: "c1", text: "contents"),
            assistant(id: "a3", blocks: [text("Found it.")])
        ]
        let items = TranscriptPresenter.items(messages: messages, streaming: nil)
        XCTAssertEqual(items.count, 3, "user message, one work block, one answer")
        guard case let .work(block) = items[1] else { return XCTFail("Expected a work block") }
        guard case let .note(narration) = block.entries.first else { return XCTFail("Expected the narration demoted") }
        XCTAssertEqual(narration.textContent, "Let me look.")
    }

    // MARK: - Identity

    func testItemIdentityIsUnchangedByPrependingEarlierHistory() throws {
        let turn = [
            user(id: "u2", text: "Second", at: nil),
            assistant(id: "a2", blocks: [call("c2", "read", [:])]),
            result(id: "r2", callID: "c2", text: "ok"),
            assistant(id: "a3", blocks: [text("Answer.")])
        ]
        let earlier = [
            user(id: "u1", text: "First", at: nil),
            assistant(id: "a0", blocks: [call("c1", "bash", [:])]),
            result(id: "r1", callID: "c1", text: "ok"),
            assistant(id: "a1", blocks: [text("Earlier answer.")])
        ]

        let tailOnly = TranscriptPresenter.items(messages: turn, streaming: nil).map(\.id)
        let withHistory = TranscriptPresenter.items(messages: earlier + turn, streaming: nil).map(\.id)
        XCTAssertEqual(Array(withHistory.suffix(tailOnly.count)), tailOnly,
                       "Backfilling earlier history must not renumber the rows already on screen")
        XCTAssertEqual(Set(withHistory).count, withHistory.count, "identities stay unique")
    }

    func testAnAnswerKeepsItsIdentityWhenItSettlesOutOfStreaming() throws {
        let history = [
            user(id: "u", text: "Go", at: nil),
            assistant(id: "a1", blocks: [call("c1", "bash", [:])]),
            result(id: "r1", callID: "c1", text: "ok")
        ]
        let answerBlock = text("Everything passes.")
        let live = ChatMessage(id: "a2", role: .assistant, blocks: [answerBlock], timestamp: nil, raw: .null)

        let streamingIDs = TranscriptPresenter.items(messages: history, streaming: live).map(\.id)
        let settledIDs = TranscriptPresenter.items(messages: history + [live], streaming: nil).map(\.id)
        XCTAssertEqual(streamingIDs, settledIDs, "Settling must reuse the row the answer streamed into")

        // And the transcript never renders the live copy twice while both are held.
        let both = TranscriptPresenter.items(messages: history + [live], streaming: live).map(\.id)
        XCTAssertEqual(both, settledIDs)
    }

    func testCompactionIsShownAsItsOwnTranscriptEvent() throws {
        let compaction = ChatMessage(
            id: "compaction-1",
            role: .system,
            blocks: [text("Context compacted"), text("Summarized the first 40 turns.")],
            timestamp: nil,
            raw: .null
        )
        let items = TranscriptPresenter.items(
            messages: [user(id: "u", text: "hi", at: nil), compaction, assistant(id: "a", blocks: [text("done")])],
            streaming: nil
        )
        guard case let .compaction(note) = items[1] else { return XCTFail("Expected a compaction marker") }
        XCTAssertEqual(note.title, "Context compacted")
        XCTAssertEqual(note.summary, "Summarized the first 40 turns.")
    }

    func testWorkBlockFallsBackToStepCountsWithoutUsableTimestamps() {
        let block = TranscriptWorkBlock(
            id: "w",
            entries: [.activity(TranscriptActivityGroup(
                id: "g",
                steps: [TranscriptActivityStep(id: "s", name: "bash", kind: .commands, arguments: .object([:]), result: nil)],
                isActive: false
            ))],
            isActive: false,
            startedAt: nil,
            endedAt: nil
        )
        XCTAssertEqual(block.title, "Worked · 1 step")
        XCTAssertEqual(NumberFormatting.duration(0), "0s")
        XCTAssertEqual(NumberFormatting.duration(61), "1m 1s")
        XCTAssertEqual(NumberFormatting.duration(3_725), "1h 2m")
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

    private func user(id: String, text value: String, at date: Date?) -> ChatMessage {
        ChatMessage(id: id, role: .user, blocks: [text(value)], timestamp: date, raw: .null)
    }

    private func assistant(id: String, blocks: [MessageBlock], at date: Date? = nil) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, blocks: blocks, timestamp: date, raw: .null)
    }

    private func text(_ value: String) -> MessageBlock {
        MessageBlock(id: UUID().uuidString, kind: .text(value))
    }

    private func thinking(_ value: String) -> MessageBlock {
        MessageBlock(id: UUID().uuidString, kind: .thinking(value))
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

final class LimitsReportTests: XCTestCase {
    func testParsesEveryAccountWindowAndKeepsUnknownLines() throws {
        let report = LimitsReportParser.parse("""
        ChatGPT
          Email: someone@example.com
          Plan: pro
          primary: 62% remaining · 38% used · 300 min window · resets Jul 27, 10:00
          secondary: 8% remaining · 92% used · resets Aug 1, 09:00
          Banked resets: 2 available

        Claude
          Email: other@example.com
          Five hour: 90% remaining
        """)

        XCTAssertEqual(report.accounts.map(\.name), ["ChatGPT", "Claude"])
        let chatGPT = try XCTUnwrap(report.accounts.first)
        XCTAssertEqual(chatGPT.email, "someone@example.com")
        XCTAssertEqual(chatGPT.plan, "pro")
        XCTAssertEqual(chatGPT.windows.map(\.remainingPercent), [62, 8])
        XCTAssertEqual(chatGPT.windows.first?.resets, "Jul 27, 10:00")
        XCTAssertEqual(chatGPT.tightest?.remainingPercent, 8)
        XCTAssertEqual(chatGPT.notes, ["Banked resets: 2 available"])
        XCTAssertEqual(report.accounts.last?.windows.first?.label, "Five hour")
    }

    func testUnreachableAccountReportsItsErrorInsteadOfDisappearing() throws {
        let report = LimitsReportParser.parse("""
        Claude
          Unable to load limits: not signed in with OAuth
        """)
        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertEqual(account.error, "not signed in with OAuth")
        XCTAssertTrue(account.windows.isEmpty)
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

final class LimitsBridgeTests: XCTestCase {
    @MainActor
    func testOnlyTheLimitsEditorDialogIsConsumedNatively() {
        XCTAssertTrue(AppStore.isLimitsDialog(method: "editor", title: "AI usage limits (Esc to close)"))
        XCTAssertFalse(AppStore.isLimitsDialog(method: "editor", title: "Edit commit message"))
        XCTAssertFalse(AppStore.isLimitsDialog(method: "input", title: "AI usage limits (Esc to close)"))
        XCTAssertFalse(AppStore.isLimitsDialog(method: "editor", title: nil))
    }

    @MainActor
    func testAppliedReportReplacesTheCacheAndAnEmptyOneKeepsIt() {
        let store = LimitsReportStore.shared
        store.apply(text: "ChatGPT\n  5h: 40% remaining")
        XCTAssertEqual(store.report?.accounts.first?.windows.first?.remainingPercent, 40)

        // A blank report must never wipe a good one out from under the popover.
        store.apply(text: "")
        XCTAssertEqual(store.report?.accounts.first?.windows.first?.remainingPercent, 40)
        XCTAssertNotNil(store.lastError)
    }
}
