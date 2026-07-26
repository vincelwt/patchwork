import Foundation

struct QuestionnaireOption: Identifiable, Hashable, Sendable {
    let id: Int
    let label: String
    let description: String
    let preview: String?
}

struct QuestionnaireQuestion: Identifiable, Hashable, Sendable {
    let id: Int
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [QuestionnaireOption]
}

struct QuestionnaireAnswer: Equatable, Hashable, Sendable {
    var optionIndexes: Set<Int> = []
    var customText: String?

    var isValid: Bool {
        if let customText { return !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !optionIndexes.isEmpty
    }
}

struct QuestionnaireSession: Equatable, Sendable {
    let toolCallID: String
    let questions: [QuestionnaireQuestion]
    var currentIndex = 0
    var answers: [QuestionnaireAnswer?]
    var submitted = false
    var nextRPCQuestionIndex = 0
    var awaitingCustomText: String?

    init(toolCallID: String, questions: [QuestionnaireQuestion]) {
        self.toolCallID = toolCallID
        self.questions = questions
        self.answers = Array(repeating: nil, count: questions.count)
    }

    var currentQuestion: QuestionnaireQuestion? {
        questions.indices.contains(currentIndex) ? questions[currentIndex] : nil
    }

    var isLastVisibleQuestion: Bool { currentIndex == questions.count - 1 }
    var allAnswered: Bool { !answers.isEmpty && answers.allSatisfy { $0?.isValid == true } }
}

enum QuestionnaireParser {
    static func parse(toolCallID: String, arguments: JSONValue) -> QuestionnaireSession? {
        guard let rawQuestions = arguments["questions"]?.arrayValue,
              (1...4).contains(rawQuestions.count) else { return nil }
        var questions: [QuestionnaireQuestion] = []
        for (questionIndex, raw) in rawQuestions.enumerated() {
            guard let text = clean(raw["question"]?.stringValue, limit: 4_000),
                  let rawOptions = raw["options"]?.arrayValue,
                  (2...4).contains(rawOptions.count) else { return nil }
            var options: [QuestionnaireOption] = []
            for (optionIndex, option) in rawOptions.enumerated() {
                guard let label = clean(option["label"]?.stringValue, limit: 200),
                      let description = clean(option["description"]?.stringValue, limit: 2_000) else { return nil }
                options.append(QuestionnaireOption(
                    id: optionIndex,
                    label: label,
                    description: description,
                    preview: clean(option["preview"]?.stringValue, limit: 20_000)
                ))
            }
            questions.append(QuestionnaireQuestion(
                id: questionIndex,
                question: text,
                header: clean(raw["header"]?.stringValue, limit: 80) ?? "Q\(questionIndex + 1)",
                multiSelect: raw["multiSelect"]?.boolValue ?? false,
                options: options
            ))
        }
        return QuestionnaireSession(toolCallID: toolCallID, questions: questions)
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return result.count <= limit ? result : String(result.prefix(limit - 1)) + "…"
    }
}

enum QuestionnaireResponsePlan: Equatable {
    case value(String)
    case custom(sentinel: String, text: String)
}

enum QuestionnaireRPCBridge {
    static func matches(_ request: ExtensionDialogRequest, question: QuestionnaireQuestion) -> Bool {
        let title = request.title.lowercased()
        let identifiesQuestion = title.contains(question.question.lowercased())
            || title.contains(question.header.lowercased())
        guard identifiesQuestion else { return false }
        return question.multiSelect ? request.method == .input : request.method == .select
    }

    static func response(
        question: QuestionnaireQuestion,
        answer: QuestionnaireAnswer,
        request: ExtensionDialogRequest
    ) -> QuestionnaireResponsePlan? {
        guard answer.isValid else { return nil }
        if let custom = answer.customText?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            if question.multiSelect { return .value(custom) }
            let sentinelIndex = question.options.count
            guard request.options.indices.contains(sentinelIndex) else { return nil }
            return .custom(sentinel: request.options[sentinelIndex], text: custom)
        }

        let indexes = answer.optionIndexes.sorted()
        guard indexes.allSatisfy({ question.options.indices.contains($0) }) else { return nil }
        if question.multiSelect {
            return .value(indexes.map { String($0 + 1) }.joined(separator: ","))
        }
        guard indexes.count == 1, request.options.indices.contains(indexes[0]) else { return nil }
        return .value(request.options[indexes[0]])
    }
}
