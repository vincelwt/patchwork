import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// The daemon labels an incoming dialog by matching it against the `ask_user_question` tool call
/// it saw earlier in the same run. These bounds and rules are deliberately identical to the app's
/// `QuestionnaireParser`/`QuestionnaireRPCBridge`, so the two surfaces agree on what counts as a
/// questionnaire step and what is just an approval prompt.
final class QuestionnaireSpecTests: XCTestCase {
    private func toolCall(_ argumentsJSON: String, name: String = "ask_user_question") -> PiJSONValue {
        let json = #"[{"type":"toolCall","name":"\#(name)","arguments":\#(argumentsJSON)}]"#
        return (try? PiJSONValue.decode(Data(json.utf8))) ?? .null
    }

    private static let twoQuestions = """
    {"questions":[
      {"header":"Auth","question":"Which auth method?","options":[
        {"label":"OAuth","description":"Delegate to the provider","preview":"code here"},
        {"label":"Password","description":"Store a hash"}]},
      {"header":"Extras","question":"Which extras?","multiSelect":true,"options":[
        {"label":"Logging","description":"Structured logs"},
        {"label":"Metrics","description":"Counters"},
        {"label":"Tracing","description":"Spans"}]}
    ]}
    """

    func testParsesQuestionsWithLabelsDescriptionsAndPreviews() {
        let specs = QuestionnaireSpecParser.specs(inAssistantContent: toolCall(Self.twoQuestions))
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].header, "Auth")
        XCTAssertEqual(specs[0].count, 2)
        XCTAssertFalse(specs[0].multiSelect)
        XCTAssertEqual(specs[0].options.map(\.label), ["OAuth", "Password"])
        XCTAssertEqual(specs[0].options[0].preview, "code here")
        XCTAssertTrue(specs[1].multiSelect)
        XCTAssertEqual(specs[1].index, 1)
    }

    func testAnyOtherToolCallIsIgnored() {
        XCTAssertTrue(QuestionnaireSpecParser.specs(inAssistantContent: toolCall(Self.twoQuestions, name: "Bash")).isEmpty)
        XCTAssertTrue(QuestionnaireSpecParser.specs(inAssistantContent: nil).isEmpty)
        XCTAssertTrue(QuestionnaireSpecParser.specs(inAssistantContent: .string("plain text")).isEmpty)
    }

    func testPayloadsTheAppWouldRejectAreNotTreatedAsRicherHere() {
        // Too few options, too many questions, and a missing label each fail the whole parse
        // rather than producing a half-labelled dialog.
        XCTAssertTrue(QuestionnaireSpecParser.parse(arguments: try? PiJSONValue.decode(Data(
            #"{"questions":[{"question":"Q","options":[{"label":"only one"}]}]}"#.utf8
        ))).isEmpty)
        XCTAssertTrue(QuestionnaireSpecParser.parse(arguments: try? PiJSONValue.decode(Data(
            #"{"questions":[{"question":"Q","options":[{"description":"no label"},{"label":"b"}]}]}"#.utf8
        ))).isEmpty)
        XCTAssertTrue(QuestionnaireSpecParser.parse(arguments: nil).isEmpty)
    }

    func testMatchingNeedsBothTheTitleAndTheRightMethod() {
        let specs = QuestionnaireSpecParser.specs(inAssistantContent: toolCall(Self.twoQuestions))

        let single = QuestionnaireSpecParser.match(specs, title: "Which auth method?", method: "select")
        XCTAssertEqual(single?.header, "Auth")

        let byHeader = QuestionnaireSpecParser.match(specs, title: "Auth", method: "select")
        XCTAssertEqual(byHeader?.header, "Auth")

        // A multi-select question arrives as `input`, never `select`.
        XCTAssertNil(QuestionnaireSpecParser.match(specs, title: "Which extras?", method: "select"))
        XCTAssertEqual(QuestionnaireSpecParser.match(specs, title: "Which extras?", method: "input")?.header, "Extras")

        // An unrelated approval prompt must never be mislabelled as a question.
        XCTAssertNil(QuestionnaireSpecParser.match(specs, title: "Allow Pi to run rm -rf?", method: "select"))
    }

    func testSingleSelectChoicesCarryPisExactOptionStringsAsValues() {
        let specs = QuestionnaireSpecParser.specs(inAssistantContent: toolCall(Self.twoQuestions))
        let spec = QuestionnaireSpecParser.match(specs, title: "Which auth method?", method: "select")
        let raw = ["OAuth (Recommended)", "Password", "Type something."]

        let choices = QuestionnaireSpecParser.choices(for: spec, rawOptions: raw, multiSelect: false)
        XCTAssertEqual(choices.map(\.value), raw, "a response must be one of Pi's own strings")
        XCTAssertEqual(choices[0].label, "OAuth")
        XCTAssertEqual(choices[0].description, "Delegate to the provider")
        XCTAssertEqual(choices[2].label, "Type something.", "the sentinel row has no spec entry and keeps its raw text")
    }

    func testMultiSelectChoicesCarryTheOneBasedIndexEncodingThePluginReads() {
        let specs = QuestionnaireSpecParser.specs(inAssistantContent: toolCall(Self.twoQuestions))
        let spec = QuestionnaireSpecParser.match(specs, title: "Which extras?", method: "input")

        let choices = QuestionnaireSpecParser.choices(for: spec, rawOptions: [], multiSelect: true)
        XCTAssertEqual(choices.map(\.value), ["1", "2", "3"])
        XCTAssertEqual(choices.map(\.label), ["Logging", "Metrics", "Tracing"])
    }

    func testWithoutAMatchTheRawOptionsStillRenderAsPlainChoices() {
        let choices = QuestionnaireSpecParser.choices(for: nil, rawOptions: ["Allow", "Deny"], multiSelect: false)
        XCTAssertEqual(choices.map(\.value), ["Allow", "Deny"])
        XCTAssertEqual(choices.map(\.label), ["Allow", "Deny"])
        XCTAssertNil(choices[0].description)
    }
}
