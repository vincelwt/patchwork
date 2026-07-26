import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtensionDialogView: View {
    @EnvironmentObject private var store: AppStore
    let request: ExtensionDialogRequest
    @State private var value: String

    init(request: ExtensionDialogRequest) {
        self.request = request
        _value = State(initialValue: request.prefill ?? "")
    }

    @ViewBuilder var body: some View {
        if let question = store.questionnaireQuestion(for: request),
           let session = store.pendingQuestionnaire {
            QuestionnaireDialogView(
                request: request,
                question: question,
                questionCount: session.questions.count,
                currentIndex: session.currentIndex,
                headers: session.questions.map(\.header),
                savedAnswer: session.answers[session.currentIndex]
            )
            .id(question.id)
        } else {
            genericDialog
        }
    }

    private var genericDialog: some View {
        VStack(alignment: .leading, spacing: PiTheme.space16) {
            HStack(alignment: .top, spacing: PiTheme.space10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.piPurple)
                VStack(alignment: .leading, spacing: PiTheme.space4) {
                    Text(request.title)
                        .font(PiFont.title)
                    if let message = request.message, !message.isEmpty {
                        Text(message)
                            .font(PiFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            dialogContent

            HStack {
                Spacer()
                Button("Cancel") { store.respondToExtensionDialog(cancelled: true) }
                    .keyboardShortcut(.cancelAction)
                if request.method == .input || request.method == .editor {
                    Button("Submit") { store.respondToExtensionDialog(value: value) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(value.isEmpty)
                }
            }
        }
        .padding(PiTheme.space20)
        .frame(width: 460)
        .background(Color.piTranscript)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var dialogContent: some View {
        switch request.method {
        case .select:
            VStack(spacing: PiTheme.space6) {
                ForEach(request.options, id: \.self) { option in
                    Button {
                        store.respondToExtensionDialog(value: option)
                    } label: {
                        HStack {
                            Text(option).font(PiFont.row)
                            Spacer()
                            PiChevron(expanded: false)
                        }
                        .padding(.horizontal, PiTheme.space10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .piInset()
                }
            }
        case .confirm:
            HStack(spacing: PiTheme.space8) {
                Button("No") { store.respondToExtensionDialog(confirmed: false) }
                    .frame(maxWidth: .infinity)
                Button("Yes") { store.respondToExtensionDialog(confirmed: true) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
            }
        case .input:
            TextField(request.placeholder ?? "Enter a value", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !value.isEmpty { store.respondToExtensionDialog(value: value) } }
        case .editor:
            TextEditor(text: $value)
                .font(PiFont.code)
                .frame(height: 260)
                .padding(PiTheme.space6)
                .piInset()
        }
    }
}

private struct QuestionnaireDialogView: View {
    @EnvironmentObject private var store: AppStore
    let request: ExtensionDialogRequest
    let question: QuestionnaireQuestion
    let questionCount: Int
    let currentIndex: Int
    let headers: [String]

    @State private var selected: Set<Int>
    @State private var customText: String
    @State private var usesCustom: Bool
    @State private var focusedOption = 0
    @FocusState private var customFocused: Bool

    init(
        request: ExtensionDialogRequest,
        question: QuestionnaireQuestion,
        questionCount: Int,
        currentIndex: Int,
        headers: [String],
        savedAnswer: QuestionnaireAnswer?
    ) {
        self.request = request
        self.question = question
        self.questionCount = questionCount
        self.currentIndex = currentIndex
        self.headers = headers
        _selected = State(initialValue: savedAnswer?.optionIndexes ?? [])
        _customText = State(initialValue: savedAnswer?.customText ?? "")
        _usesCustom = State(initialValue: savedAnswer?.customText != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space16) {
            headerTabs
            VStack(alignment: .leading, spacing: PiTheme.space4) {
                Text(question.question)
                    .font(PiFont.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(question.multiSelect ? "Choose one or more options." : "Choose one option.")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PiTheme.space16) {
                    choices.frame(minWidth: 330, maxWidth: .infinity)
                    if let preview = activePreview { previewPane(preview).frame(minWidth: 280, maxWidth: 380) }
                }
                VStack(alignment: .leading, spacing: PiTheme.space12) {
                    choices
                    if let preview = activePreview { previewPane(preview) }
                }
            }

            HStack(spacing: PiTheme.space8) {
                Button("Cancel", action: store.cancelQuestionnaire)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Back") {
                    if currentAnswer.isValid { store.saveQuestionnaireAnswer(currentAnswer, move: -1) }
                    else { store.moveQuestionnaireBack() }
                }
                .disabled(currentIndex == 0)
                if currentIndex + 1 < questionCount {
                    Button("Next") { store.saveQuestionnaireAnswer(currentAnswer, move: 1) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!currentAnswer.isValid)
                } else {
                    Button("Submit") { store.submitQuestionnaire(currentAnswer) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!currentAnswer.isValid || !otherQuestionsAnswered)
                }
            }
        }
        .padding(PiTheme.space20)
        .frame(minWidth: 560, idealWidth: activePreview == nil ? 620 : 840, maxWidth: 920)
        .background(Color.piTranscript)
        .interactiveDismissDisabled()
        .focusable()
        .onMoveCommand(perform: moveFocus)
        .onKeyPress(.space) {
            guard !customFocused else { return .ignored }
            choose(index: focusedOption)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questionnaire, question \(currentIndex + 1) of \(questionCount)")
    }

    private var headerTabs: some View {
        HStack(spacing: PiTheme.space6) {
            ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                Text(header)
                    .font(PiFont.micro.weight(index == currentIndex ? .semibold : .regular))
                    .foregroundStyle(index == currentIndex ? Color.primary : Color.secondary)
                    .padding(.horizontal, PiTheme.space8)
                    .frame(height: 24)
                    .background(index == currentIndex ? Color.piInsetStrong : Color.piInset, in: Capsule())
                    .accessibilityLabel("\(header), question \(index + 1)\(index == currentIndex ? ", current" : "")")
            }
        }
    }

    private var choices: some View {
        VStack(spacing: PiTheme.space6) {
            ForEach(question.options) { option in
                Button { choose(index: option.id) } label: {
                    optionCard(option)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label). \(option.description)")
                .accessibilityValue(selected.contains(option.id) && !usesCustom ? "Selected" : "Not selected")
            }
            Button {
                usesCustom = true
                selected.removeAll()
                customFocused = true
                focusedOption = question.options.count
            } label: {
                HStack(alignment: .top, spacing: PiTheme.space10) {
                    selectionSymbol(selected: usesCustom)
                    VStack(alignment: .leading, spacing: PiTheme.space4) {
                        Text("Type something.").font(PiFont.rowEmphasis)
                        TextField("Your answer", text: $customText)
                            .textFieldStyle(.plain)
                            .focused($customFocused)
                            .onTapGesture { usesCustom = true; selected.removeAll() }
                            .onSubmit { submitOrAdvance() }
                    }
                    Spacer(minLength: 0)
                }
                .padding(PiTheme.space10)
                .contentShape(Rectangle())
                .background(cardBackground(selected: usesCustom, focused: focusedOption == question.options.count))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type something. Custom answer")
            .accessibilityValue(usesCustom ? "Selected" : "Not selected")
        }
    }

    private func optionCard(_ option: QuestionnaireOption) -> some View {
        HStack(alignment: .top, spacing: PiTheme.space10) {
            selectionSymbol(selected: selected.contains(option.id) && !usesCustom)
            VStack(alignment: .leading, spacing: PiTheme.space2) {
                Text(option.label).font(PiFont.rowEmphasis)
                Text(option.description)
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PiTheme.space10)
        .contentShape(Rectangle())
        .background(cardBackground(
            selected: selected.contains(option.id) && !usesCustom,
            focused: focusedOption == option.id
        ))
    }

    private func selectionSymbol(selected: Bool) -> some View {
        Image(systemName: question.multiSelect
              ? (selected ? "checkmark.square.fill" : "square")
              : (selected ? "largecircle.fill.circle" : "circle"))
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(width: 16, height: 18)
    }

    private func cardBackground(selected: Bool, focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.09) : (focused ? Color.piHover : Color.piInset))
            .overlay {
                RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.55) : Color.piHairline, lineWidth: PiTheme.hairline)
            }
    }

    private func previewPane(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: PiTheme.space8) {
            Text("Preview").font(PiFont.micro.weight(.semibold)).foregroundStyle(.tertiary)
            ScrollView {
                MarkdownBlockView(text: preview, size: PiFont.bodySize - 1)
                    .padding(PiTheme.space10)
            }
            .frame(maxHeight: 320)
            .piInset()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Option preview")
    }

    private var activePreview: String? {
        guard !usesCustom else { return nil }
        return question.options.first(where: { $0.id == focusedOption })?.preview
            ?? question.options.first(where: { selected.contains($0.id) })?.preview
            ?? question.options.compactMap(\.preview).first
    }

    private var currentAnswer: QuestionnaireAnswer {
        QuestionnaireAnswer(
            optionIndexes: usesCustom ? [] : selected,
            customText: usesCustom ? customText : nil
        )
    }

    private var otherQuestionsAnswered: Bool {
        guard let session = store.pendingQuestionnaire else { return false }
        return session.answers.enumerated().allSatisfy { index, answer in
            index == currentIndex || answer?.isValid == true
        }
    }

    private func choose(index: Int) {
        focusedOption = index
        if index == question.options.count {
            usesCustom = true
            selected.removeAll()
            customFocused = true
            return
        }
        guard question.options.indices.contains(index) else { return }
        usesCustom = false
        customText = ""
        if question.multiSelect {
            if selected.contains(index) { selected.remove(index) }
            else { selected.insert(index) }
        } else {
            selected = [index]
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let count = question.options.count + 1
        switch direction {
        case .up, .left: focusedOption = (focusedOption - 1 + count) % count
        case .down, .right: focusedOption = (focusedOption + 1) % count
        default: break
        }
    }

    private func submitOrAdvance() {
        guard currentAnswer.isValid else { return }
        if currentIndex + 1 < questionCount { store.saveQuestionnaireAnswer(currentAnswer, move: 1) }
        else if otherQuestionsAnswered { store.submitQuestionnaire(currentAnswer) }
    }
}

struct ImageViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: ImagePayload
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(payload.fileName ?? "Conversation image")
                    .font(PiFont.rowEmphasis)
                Spacer()
                Button(action: save) { Image(systemName: "square.and.arrow.down") }
                    .help("Save image")
                Slider(value: $zoom, in: 0.25...3)
                    .frame(width: 110)
                    .accessibilityLabel("Image zoom")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.bar)

            ScrollView([.horizontal, .vertical]) {
                if let image = payload.nsImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            width: max(300, image.size.width * zoom),
                            height: max(240, image.size.height * zoom)
                        )
                        .padding(24)
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .frame(width: 500, height: 400)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.88))
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = payload.fileName ?? "Pi image.\(fileExtension)"
        panel.allowedContentTypes = [UTType(mimeType: payload.mimeType) ?? .png]
        if panel.runModal() == .OK, let url = panel.url {
            try? payload.data.write(to: url, options: .atomic)
        }
    }

    private var fileExtension: String {
        UTType(mimeType: payload.mimeType)?.preferredFilenameExtension ?? "png"
    }
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(toast.text)
                .font(PiFont.caption)
                .lineLimit(3)
        }
        .padding(.horizontal, PiTheme.space12)
        .padding(.vertical, PiTheme.space8)
        .background(Color.piTranscript, in: Capsule())
        .overlay { Capsule().stroke(Color.piHairline, lineWidth: PiTheme.hairline) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .accessibilityLabel(toast.text)
    }

    private var icon: String {
        switch toast.style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .info: .accentColor
        case .warning: .orange
        case .error: .piRed
        }
    }
}
