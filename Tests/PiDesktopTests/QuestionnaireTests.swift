import Foundation
import XCTest
@testable import PiDesktop

final class QuestionnaireParserTests: XCTestCase {
    func testParserRetainsPreviewsAndMultiSelectWithoutRawFallback() throws {
        let session = try XCTUnwrap(QuestionnaireParser.parse(toolCallID: "call-1", arguments: questionnaireArguments))
        XCTAssertEqual(session.questions.count, 2)
        XCTAssertEqual(session.questions[0].header, "Scope")
        XCTAssertEqual(session.questions[0].options[0].preview, "**Small** preview")
        XCTAssertTrue(session.questions[1].multiSelect)
        XCTAssertEqual(session.answers.count, 2)
    }

    func testResponseEncodingMatchesPluginContract() throws {
        let session = try XCTUnwrap(QuestionnaireParser.parse(toolCallID: "call-1", arguments: questionnaireArguments))
        let select = request(
            id: "select-1",
            method: .select,
            title: "[Scope] Which scope?",
            options: ["1. Small — Fast", "2. Large — Complete", "3. Type something."]
        )
        XCTAssertEqual(
            QuestionnaireRPCBridge.response(
                question: session.questions[0],
                answer: QuestionnaireAnswer(optionIndexes: [1]),
                request: select
            ),
            .value("2. Large — Complete")
        )
        XCTAssertEqual(
            QuestionnaireRPCBridge.response(
                question: session.questions[0],
                answer: QuestionnaireAnswer(customText: "A custom scope"),
                request: select
            ),
            .custom(sentinel: "3. Type something.", text: "A custom scope")
        )

        let multi = request(id: "multi-1", method: .input, title: "[Files] Which files?")
        XCTAssertEqual(
            QuestionnaireRPCBridge.response(
                question: session.questions[1],
                answer: QuestionnaireAnswer(optionIndexes: [0, 1]),
                request: multi
            ),
            .value("1,2")
        )
        XCTAssertEqual(
            QuestionnaireRPCBridge.response(
                question: session.questions[1],
                answer: QuestionnaireAnswer(customText: "Only docs"),
                request: multi
            ),
            .value("Only docs")
        )
    }

    func testMalformedQuestionnaireIsRejectedDeterministically() {
        XCTAssertNil(QuestionnaireParser.parse(toolCallID: "x", arguments: .object(["questions": .array([])])))
        XCTAssertNil(QuestionnaireParser.parse(toolCallID: "x", arguments: .object([
            "questions": .array([.object([
                "question": .string("Missing options"),
                "options": .array([.object(["label": .string("One"), "description": .string("Only one")])])
            ])])
        ])))
    }

    private var questionnaireArguments: JSONValue {
        .object(["questions": .array([
            .object([
                "question": .string("Which scope?"),
                "header": .string("Scope"),
                "options": .array([
                    .object(["label": .string("Small"), "description": .string("Fast"), "preview": .string("**Small** preview")]),
                    .object(["label": .string("Large"), "description": .string("Complete")])
                ])
            ]),
            .object([
                "question": .string("Which files?"),
                "header": .string("Files"),
                "multiSelect": .bool(true),
                "options": .array([
                    .object(["label": .string("Sources"), "description": .string("App code")]),
                    .object(["label": .string("Tests"), "description": .string("Test code")])
                ])
            ])
        ])])
    }

    private func request(
        id: String,
        method: ExtensionDialogRequest.Method,
        title: String,
        options: [String] = []
    ) -> ExtensionDialogRequest {
        ExtensionDialogRequest(id: id, method: method, title: title, options: options, raw: .null)
    }
}

private final class QuestionnaireRuntime: PiRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionPath = ""
    var responses: [JSONValue] = []

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }
    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        let data: JSONValue
        switch type {
        case "get_state":
            data = .object([
                "sessionFile": .string(sessionPath),
                "sessionId": .string("session"),
                "model": .object(["provider": .string("p"), "id": .string("m"), "name": .string("Model")]),
                "thinkingLevel": .string("off")
            ])
        case "get_available_models": data = .object(["models": .array([])])
        case "get_available_thinking_levels": data = .object(["levels": .array([.string("off")])])
        case "get_messages": data = .object(["messages": .array([])])
        case "get_session_stats": data = .object([:])
        default: data = .object([:])
        }
        completion?(.success(.object(["success": .bool(true), "data": data])))
    }
    func sendUncorrelated(_ value: JSONValue) { responses.append(value) }
    func emit(_ value: JSONValue) { onEvent?(value) }
}

private struct QuestionnaireRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp")
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation { SessionConversation(messages: [], leafID: nil, rawEntryCount: 0) }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary { throw CancellationError() }
}

private struct QuestionnaireGit: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

@MainActor
final class QuestionnaireStateMachineTests: XCTestCase {
    func testBufferedQuestionsBridgeSequentialRequestsAndPreserveFIFO() throws {
        let (store, runtime, _) = makeStore()
        runtime.emit(toolStart(arguments: twoQuestions))
        runtime.emit(selectRequest(id: "q1"))
        XCTAssertNotNil(store.questionnaireQuestion(for: try XCTUnwrap(store.activeDialog)))

        store.saveQuestionnaireAnswer(QuestionnaireAnswer(optionIndexes: [0]), move: 1)
        store.submitQuestionnaire(QuestionnaireAnswer(optionIndexes: [0, 1]))
        XCTAssertEqual(runtime.responses.last?["value"]?.stringValue, "1. Small — Fast")
        XCTAssertNil(store.activeDialog)

        runtime.emit(multiRequest(id: "q2"))
        XCTAssertEqual(runtime.responses.last?["id"]?.stringValue, "q2")
        XCTAssertEqual(runtime.responses.last?["value"]?.stringValue, "1,2")
        XCTAssertNil(store.pendingQuestionnaire)
    }

    func testCustomSingleSelectionAutomaticallyAnswersFollowUpInput() throws {
        let (store, runtime, _) = makeStore()
        runtime.emit(toolStart(arguments: oneQuestion))
        runtime.emit(selectRequest(id: "q1"))
        store.submitQuestionnaire(QuestionnaireAnswer(customText: "Something else"))
        XCTAssertEqual(runtime.responses.last?["value"]?.stringValue, "3. Type something.")
        XCTAssertNotNil(store.pendingQuestionnaire)

        runtime.emit(.object([
            "type": .string("extension_ui_request"), "method": .string("input"),
            "id": .string("custom"), "title": .string("Custom answer")
        ]))
        XCTAssertEqual(runtime.responses.last?["id"]?.stringValue, "custom")
        XCTAssertEqual(runtime.responses.last?["value"]?.stringValue, "Something else")
        XCTAssertNil(store.pendingQuestionnaire)
        XCTAssertNil(store.activeDialog)
    }

    func testCancellationSendsCancelledAndClearsNativeState() throws {
        let (store, runtime, _) = makeStore()
        runtime.emit(toolStart(arguments: oneQuestion))
        runtime.emit(selectRequest(id: "q1"))
        store.cancelQuestionnaire()
        XCTAssertEqual(runtime.responses.last?["cancelled"]?.boolValue, true)
        XCTAssertNil(store.pendingQuestionnaire)
        XCTAssertNil(store.activeDialog)
    }

    private func makeStore() -> (AppStore, QuestionnaireRuntime, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Questionnaire-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        let runtime = QuestionnaireRuntime()
        runtime.sessionPath = file.path
        let store = AppStore(
            repository: QuestionnaireRepository(),
            gitService: QuestionnaireGit(),
            runtime: runtime,
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter()
        )
        var summary = SessionSummary(
            id: "session", fileURL: file, cwd: directory, createdAt: Date(), modifiedAt: Date(),
            name: "Session", preview: "", messageCount: 0, metrics: TokenMetrics()
        )
        summary.prepareSearchKey()
        store.sessions = [summary]
        store.route = .session(summary.id)
        store.prepareComposerOptions()
        return (store, runtime, directory)
    }

    private var oneQuestion: JSONValue {
        .object(["questions": .array([questionOne])])
    }

    private var twoQuestions: JSONValue {
        .object(["questions": .array([questionOne, .object([
            "question": .string("Which files?"), "header": .string("Files"), "multiSelect": .bool(true),
            "options": .array([
                .object(["label": .string("Sources"), "description": .string("App code")]),
                .object(["label": .string("Tests"), "description": .string("Test code")])
            ])
        ])])])
    }

    private var questionOne: JSONValue {
        .object([
            "question": .string("Which scope?"), "header": .string("Scope"),
            "options": .array([
                .object(["label": .string("Small"), "description": .string("Fast")]),
                .object(["label": .string("Large"), "description": .string("Complete")])
            ])
        ])
    }

    private func toolStart(arguments: JSONValue) -> JSONValue {
        .object([
            "type": .string("tool_execution_start"), "toolCallId": .string("ask-1"),
            "toolName": .string("ask_user_question"), "args": arguments
        ])
    }

    private func selectRequest(id: String) -> JSONValue {
        .object([
            "type": .string("extension_ui_request"), "method": .string("select"), "id": .string(id),
            "title": .string("[Scope] Which scope?"),
            "options": .array([
                .string("1. Small — Fast"), .string("2. Large — Complete"), .string("3. Type something.")
            ])
        ])
    }

    private func multiRequest(id: String) -> JSONValue {
        .object([
            "type": .string("extension_ui_request"), "method": .string("input"), "id": .string(id),
            "title": .string("[Files] Which files?\n1. Sources\n2. Tests"), "placeholder": .string("1,3")
        ])
    }
}
