import Foundation
import PatchworkKit

/// One question of an `ask_user_question` tool call, as seen by the daemon while a run streams.
///
/// The plugin drives its questionnaire over the *same* sequential `extension_ui_request` bridge
/// the app answers (`Sources/Patchwork/Questionnaire.swift`): one `select` per single-answer
/// question, one `input` per multi-select question. That wire shape alone cannot say whether a
/// dialog is a rich questionnaire step or a bare approval prompt, so the executor keeps the tool
/// call's own arguments and matches incoming dialogs against them — purely to *label* the dialog.
/// A failed match costs nothing: the request still surfaces, just without option descriptions.
struct QuestionSpec: Sendable, Equatable {
    struct Option: Sendable, Equatable {
        let label: String
        let description: String?
        let preview: String?
    }

    let index: Int
    let count: Int
    let header: String
    let question: String
    let multiSelect: Bool
    let options: [Option]
}

enum QuestionnaireSpecParser {
    static let toolName = "ask_user_question"

    /// Mirrors the app's `QuestionnaireParser` bounds exactly (1–4 questions, 2–4 options each,
    /// per-field length caps) so a payload the app would reject is not treated as richer here.
    static func parse(arguments: PiJSONValue?) -> [QuestionSpec] {
        guard let raw = arguments?["questions"]?.arrayValue, (1...4).contains(raw.count) else { return [] }
        var specs: [QuestionSpec] = []
        for (index, entry) in raw.enumerated() {
            guard let question = clean(entry["question"]?.stringValue, limit: 4_000),
                  let rawOptions = entry["options"]?.arrayValue,
                  (2...4).contains(rawOptions.count) else { return [] }
            var options: [QuestionSpec.Option] = []
            for option in rawOptions {
                guard let label = clean(option["label"]?.stringValue, limit: 200) else { return [] }
                options.append(QuestionSpec.Option(
                    label: label,
                    description: clean(option["description"]?.stringValue, limit: 2_000),
                    preview: clean(option["preview"]?.stringValue, limit: 20_000)
                ))
            }
            specs.append(QuestionSpec(
                index: index,
                count: raw.count,
                header: clean(entry["header"]?.stringValue, limit: 80) ?? "Q\(index + 1)",
                question: question,
                multiSelect: entry["multiSelect"]?.boolValue ?? false,
                options: options
            ))
        }
        return specs
    }

    /// The questions carried by one Pi event, from either shape they can arrive in.
    ///
    /// `tool_execution_start` (`toolName` + `args`) is the authoritative one and the only one the
    /// app itself reads — it fires when the tool actually runs, which is exactly when the dialogs
    /// start. The content-block form is accepted as well because a streaming update or
    /// `message_end` can carry the same call, and on some Pi versions that is what lands first.
    static func specs(inEvent event: PiJSONValue) -> [QuestionSpec] {
        if event["type"]?.stringValue == "tool_execution_start",
           event["toolName"]?.stringValue?.lowercased() == toolName {
            return parse(arguments: event["args"])
        }
        return specs(inAssistantContent: event["message"]?["content"])
    }

    /// Every `ask_user_question` call in one assistant message. A message can legitimately carry
    /// several tool calls; only this one is interesting.
    static func specs(inAssistantContent content: PiJSONValue?) -> [QuestionSpec] {
        (content?.arrayValue ?? []).flatMap { block -> [QuestionSpec] in
            guard block["type"]?.stringValue == "toolCall",
                  block["name"]?.stringValue?.lowercased() == toolName else { return [] }
            return parse(arguments: block["arguments"])
        }
    }

    /// The app's own matching rule (`QuestionnaireRPCBridge.matches`): the plugin puts the
    /// question text or its header in the dialog title, and picks the method from `multiSelect`.
    /// Both must line up, so an unrelated approval prompt is never mislabelled as a question.
    static func match(_ specs: [QuestionSpec], title: String, method: String) -> QuestionSpec? {
        let haystack = title.lowercased()
        return specs.first { spec in
            let identifies = haystack.contains(spec.question.lowercased()) || haystack.contains(spec.header.lowercased())
            return identifies && method == (spec.multiSelect ? "input" : "select")
        }
    }

    /// Turns a matched question plus Pi's raw option strings into the wire choices a client
    /// submits verbatim.
    ///
    /// - single select: the response value *is* the raw option string Pi offered, so extra
    ///   trailing options (the plugin's "Type something." sentinel) still render, unlabelled.
    /// - multi select: the plugin reads a comma-separated list of 1-based indexes typed into an
    ///   `input` dialog, so the value is the index, not the label.
    static func choices(for spec: QuestionSpec?, rawOptions: [String], multiSelect: Bool) -> [InteractionOption] {
        guard let spec else {
            return rawOptions.enumerated().map { InteractionOption(id: $0.offset, value: $0.element, label: $0.element) }
        }
        if multiSelect {
            return spec.options.enumerated().map { index, option in
                InteractionOption(
                    id: index, value: String(index + 1), label: option.label,
                    description: option.description, preview: option.preview
                )
            }
        }
        return rawOptions.enumerated().map { index, raw in
            let option = spec.options.indices.contains(index) ? spec.options[index] : nil
            return InteractionOption(
                id: index, value: raw, label: option?.label ?? raw,
                description: option?.description, preview: option?.preview
            )
        }
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return result.count <= limit ? result : String(result.prefix(limit - 1)) + "\u{2026}"
    }
}
