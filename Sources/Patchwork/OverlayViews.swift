import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Generic extension dialogs only: `ask_user_question` renders inline in the transcript (see
/// `QuestionnaireCardView`) and is filtered out of the sheet binding in `PatchworkApp.swift`.
struct ExtensionDialogView: View {
    @EnvironmentObject private var store: AppStore
    let request: ExtensionDialogRequest
    @State private var value: String

    init(request: ExtensionDialogRequest) {
        self.request = request
        _value = State(initialValue: request.prefill ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space16) {
            HStack(alignment: .top, spacing: PatchworkTheme.space10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: PatchworkIcon.large))
                    .foregroundStyle(Color.patchworkPurple)
                VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
                    Text(request.title)
                        .font(PatchworkFont.title)
                    if let message = request.message, !message.isEmpty {
                        Text(message)
                            .font(PatchworkFont.body)
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
        .padding(PatchworkTheme.space20)
        .frame(width: 460)
        .background(Color.patchworkTranscript)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var dialogContent: some View {
        switch request.method {
        case .select:
            VStack(spacing: PatchworkTheme.space6) {
                ForEach(request.options, id: \.self) { option in
                    Button {
                        store.respondToExtensionDialog(value: option)
                    } label: {
                        HStack {
                            Text(option).font(PatchworkFont.row)
                            Spacer()
                            PatchworkChevron(expanded: false)
                        }
                        .padding(.horizontal, PatchworkTheme.space10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .patchworkInset()
                }
            }
        case .confirm:
            HStack(spacing: PatchworkTheme.space8) {
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
                .font(PatchworkFont.code)
                .frame(height: 260)
                .padding(PatchworkTheme.space6)
                .patchworkInset()
        }
    }
}

/// The one questionnaire control, rendered inline in the transcript at the exact
/// `ask_user_question` tool call row — no sheet, no scrim. It is responsive: the preview pane
/// sits beside the options when the transcript is wide enough and stacks below when it is not.
struct QuestionnaireCardView: View {
    @EnvironmentObject private var store: AppStore
    let question: QuestionnaireQuestion
    let questionCount: Int
    let currentIndex: Int
    let headers: [String]

    @State private var selected: Set<Int>
    @State private var customText: String
    @State private var usesCustom: Bool
    @State private var focusedOption = 0
    @FocusState private var customFocused: Bool

    init(session: QuestionnaireSession, question: QuestionnaireQuestion) {
        self.question = question
        questionCount = session.questions.count
        currentIndex = session.currentIndex
        headers = session.questions.map(\.header)
        let savedAnswer = session.answers.indices.contains(session.currentIndex)
            ? session.answers[session.currentIndex] : nil
        _selected = State(initialValue: savedAnswer?.optionIndexes ?? [])
        _customText = State(initialValue: savedAnswer?.customText ?? "")
        _usesCustom = State(initialValue: savedAnswer?.customText != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space16) {
            headerTabs
            VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
                Text(question.question)
                    .font(PatchworkFont.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(question.multiSelect
                     ? "Choose any number of options, or continue with none selected."
                     : "Choose one option.")
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PatchworkTheme.space16) {
                    choices.frame(minWidth: PatchworkTheme.questionnaireChoicesMinWidth, maxWidth: .infinity)
                    if let preview = activePreview {
                        previewPane(preview).frame(
                            minWidth: PatchworkTheme.questionnairePreviewMinWidth,
                            maxWidth: PatchworkTheme.questionnairePreviewMaxWidth
                        )
                    }
                }
                VStack(alignment: .leading, spacing: PatchworkTheme.space12) {
                    choices
                    if let preview = activePreview { previewPane(preview) }
                }
            }

            HStack(spacing: PatchworkTheme.space8) {
                Button("Cancel", action: store.cancelQuestionnaire)
                Spacer()
                Button("Back") {
                    if answerIsValid { store.saveQuestionnaireAnswer(currentAnswer, move: -1) }
                    else { store.moveQuestionnaireBack() }
                }
                .disabled(currentIndex == 0)
                if currentIndex + 1 < questionCount {
                    Button("Next") { store.saveQuestionnaireAnswer(currentAnswer, move: 1) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!answerIsValid)
                } else {
                    Button("Submit") { store.submitQuestionnaire(currentAnswer) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!answerIsValid || !otherQuestionsAnswered)
                }
            }
        }
        .padding(PatchworkTheme.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .patchworkInset()
        // Focusable so Return/Escape/space/arrows only ever act while focus is inside this card
        // — never as window-wide default/cancel actions competing with the composer.
        .focusable()
        .onMoveCommand(perform: moveFocus)
        .onKeyPress(.space) {
            guard !customFocused else { return .ignored }
            choose(index: focusedOption)
            return .handled
        }
        .onKeyPress(.return) {
            guard !customFocused else { return .ignored }
            submitOrAdvance()
            return .handled
        }
        .onKeyPress(.escape) {
            store.cancelQuestionnaire()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questionnaire, question \(currentIndex + 1) of \(questionCount)")
    }

    /// Chips move between locally buffered questions only, so the sequential RPC bridge is never
    /// skipped ahead: forward jumps are offered once every earlier question is answered.
    private var headerTabs: some View {
        HStack(spacing: PatchworkTheme.space6) {
            ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                let reachable = store.pendingQuestionnaire?.canNavigate(to: index) ?? false
                Button { store.moveQuestionnaire(to: index, saving: currentAnswer) } label: {
                    Text(header)
                        .font(PatchworkFont.micro.weight(index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index == currentIndex ? Color.primary : Color.secondary)
                        .padding(.horizontal, PatchworkTheme.space8)
                        .frame(height: 24)
                        .contentShape(Capsule())
                        .background(index == currentIndex ? Color.patchworkInsetStrong : Color.patchworkInset, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!reachable || index == currentIndex)
                .opacity(reachable || index == currentIndex ? 1 : 0.5)
                .help(reachable ? "Go to \(header)" : "Answer the earlier questions first")
                .accessibilityLabel("\(header), question \(index + 1) of \(questionCount)")
                .accessibilityValue(index == currentIndex ? "Current" : (reachable ? "Available" : "Locked"))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions")
    }

    private var choices: some View {
        VStack(spacing: PatchworkTheme.space6) {
            ForEach(question.options) { option in
                Button { choose(index: option.id) } label: {
                    optionCard(option)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label). \(option.description)")
                .accessibilityValue(selected.contains(option.id) && !usesCustom ? "Selected" : "Not selected")
            }
            customCard
        }
    }

    /// The text field is a sibling of the activation button rather than nested inside it, so the
    /// field keeps its own focus ring, caret, and hit area.
    private var customCard: some View {
        HStack(alignment: .top, spacing: PatchworkTheme.space10) {
            Button(action: activateCustom) {
                selectionSymbol(selected: usesCustom)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type something. Custom answer")
            .accessibilityValue(usesCustom ? "Selected" : "Not selected")

            VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
                Text("Type something.")
                    .font(PatchworkFont.rowEmphasis)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: activateCustom)
                    .accessibilityHidden(true)
                TextField("Your answer", text: $customText)
                    .textFieldStyle(.plain)
                    .font(PatchworkFont.row)
                    .focused($customFocused)
                    .onSubmit { submitOrAdvance() }
                    .accessibilityLabel("Custom answer text")
            }
            Spacer(minLength: 0)
        }
        .padding(PatchworkTheme.space10)
        .background(cardBackground(selected: usesCustom, focused: focusedOption == question.options.count))
        .onChange(of: customFocused) { _, focused in
            guard focused else { return }
            usesCustom = true
            selected.removeAll()
            focusedOption = question.options.count
        }
    }

    private func activateCustom() {
        usesCustom = true
        selected.removeAll()
        focusedOption = question.options.count
        customFocused = true
    }

    private func optionCard(_ option: QuestionnaireOption) -> some View {
        HStack(alignment: .top, spacing: PatchworkTheme.space10) {
            selectionSymbol(selected: selected.contains(option.id) && !usesCustom)
            VStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                Text(option.label).font(PatchworkFont.rowEmphasis)
                Text(option.description)
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PatchworkTheme.space10)
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
            .font(.system(size: PatchworkIcon.medium))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(width: 16, height: 18)
    }

    private func cardBackground(selected: Bool, focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: PatchworkTheme.radiusMedium, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.09) : (focused ? Color.patchworkHover : Color.patchworkInset))
            .overlay {
                RoundedRectangle(cornerRadius: PatchworkTheme.radiusMedium, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.55) : Color.patchworkHairline, lineWidth: PatchworkTheme.hairline)
            }
    }

    private func previewPane(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space8) {
            Text("Preview").font(PatchworkFont.micro.weight(.semibold)).foregroundStyle(.tertiary)
            ScrollView {
                MarkdownBlockView(text: preview)
                    .padding(PatchworkTheme.space10)
            }
            .frame(maxHeight: PatchworkTheme.questionnairePreviewMaxHeight)
            .patchworkInset(strong: true)
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

    private var answerIsValid: Bool { currentAnswer.isValid(multiSelect: question.multiSelect) }

    private var otherQuestionsAnswered: Bool {
        guard let session = store.pendingQuestionnaire else { return false }
        return session.questions.indices.allSatisfy { index in
            index == currentIndex || session.isAnswerValid(at: index)
        }
    }

    private func choose(index: Int) {
        focusedOption = index
        if index == question.options.count {
            activateCustom()
            return
        }
        guard question.options.indices.contains(index) else { return }
        usesCustom = false
        customText = ""
        customFocused = false
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
        guard answerIsValid else { return }
        if currentIndex + 1 < questionCount { store.saveQuestionnaireAnswer(currentAnswer, move: 1) }
        else if otherQuestionsAnswered { store.submitQuestionnaire(currentAnswer) }
    }
}

/// A dimmed scrim plus the viewer panel, presented as the last root overlay rather than a sheet,
/// so a click outside dismisses it exactly like the ⌘K palette.
struct ImageViewerView: View {
    /// Local state, so arrowing through the group never re-presents the viewer.
    @State private var selection: ViewedImage
    @State private var zoom = 1.0
    // A root overlay does not inherit the composer's focus, so it must claim its own key events.
    @FocusState private var hasKeyboardFocus: Bool
    private let onDismiss: () -> Void

    init(selection: ViewedImage, onDismiss: @escaping () -> Void) {
        _selection = State(initialValue: selection)
        self.onDismiss = onDismiss
    }

    private var payload: ImagePayload { selection.image }

    /// At zoom 1 an image fits the viewport with its aspect ratio intact and is never upscaled
    /// past its intrinsic size; above 1 it outgrows the viewport and the scroll view takes over.
    /// Pure geometry, so the fit is testable without a window.
    static func fittedSize(for imageSize: CGSize, in viewport: CGSize, zoom: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0, zoom > 0 else { return .zero }
        let scale = min(1, viewport.width / imageSize.width, viewport.height / imageSize.height) * zoom
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            panel
                .padding(PatchworkTheme.space24)
        }
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let delta = Self.navigationDelta(for: press.key) else { return .ignored }
            step(delta)
            return .handled
        }
        .onExitCommand(perform: onDismiss)
        .transition(.opacity)
        .zIndex(30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image viewer")
    }

    static func navigationDelta(for key: KeyEquivalent) -> Int? {
        switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        default: nil
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: PatchworkTheme.space8) {
                Text(payload.fileName ?? "Conversation image")
                    .font(PatchworkFont.rowEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PatchworkTheme.space8)
                if selection.images.count > 1 {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!selection.hasPrevious)
                        .help("Previous image in this message")
                        .accessibilityLabel("Previous image")
                    Text("\(selection.index + 1) of \(selection.images.count)")
                        .font(PatchworkFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityLabel("Image \(selection.index + 1) of \(selection.images.count)")
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!selection.hasNext)
                        .help("Next image in this message")
                        .accessibilityLabel("Next image")
                }
                Button(action: save) { Image(systemName: "square.and.arrow.down") }
                    .help("Save image")
                Slider(value: $zoom, in: 0.25...3)
                    .frame(width: 110)
                    .accessibilityLabel("Image zoom")
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(PatchworkTheme.space12)
            .background(.bar)

            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    image(fitting: proxy.size)
                        .padding(PatchworkTheme.space24)
                        // Centers anything smaller than the viewport; anything larger scrolls.
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
            }
            .background(Color.black.opacity(0.88))
        }
        .frame(maxWidth: PatchworkTheme.imageViewerMaxWidth, maxHeight: PatchworkTheme.imageViewerMaxHeight)
        .background(Color.patchworkTranscript)
        .clipShape(RoundedRectangle(cornerRadius: PatchworkTheme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PatchworkTheme.panelRadius, style: .continuous)
                .stroke(Color.patchworkHairline, lineWidth: PatchworkTheme.hairline)
        }
        .shadow(color: .black.opacity(0.22), radius: PatchworkTheme.space24, y: PatchworkTheme.space10)
        // The solid panel eats its own clicks; controls and the image still get theirs first.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    @ViewBuilder
    private func image(fitting available: CGSize) -> some View {
        if let image = payload.nsImage {
            let viewport = CGSize(
                width: available.width - 2 * PatchworkTheme.space24,
                height: available.height - 2 * PatchworkTheme.space24
            )
            let size = Self.fittedSize(for: image.size, in: viewport, zoom: zoom)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        } else {
            PatchworkUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                .frame(width: 500, height: 400)
        }
    }

    /// Each image opens fitted, so zoom does not carry over from the previous one.
    private func step(_ delta: Int) {
        guard delta < 0 ? selection.hasPrevious : selection.hasNext else { return }
        if delta < 0 { selection.goToPrevious() } else { selection.goToNext() }
        zoom = 1
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

/// Presented top-center, cleared of the unified toolbar, by the root overlay in
/// `PatchworkApp.swift` — nowhere near the composer at the bottom of the window. Capped here so
/// a long message wraps into a compact pill instead of stretching edge to edge.
private let toastMaxWidth: CGFloat = 420

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: PatchworkTheme.space8) {
            Image(systemName: icon)
                .font(.system(size: PatchworkIcon.small, weight: .medium))
                .foregroundStyle(tint)
            Text(toast.text)
                .font(PatchworkFont.caption)
                .lineLimit(3)
        }
        .padding(.horizontal, PatchworkTheme.space12)
        .padding(.vertical, PatchworkTheme.space8)
        .frame(maxWidth: toastMaxWidth)
        .background(Color.patchworkTranscript, in: Capsule())
        .overlay { Capsule().stroke(Color.patchworkHairline, lineWidth: PatchworkTheme.hairline) }
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
        case .error: .patchworkRed
        }
    }
}
