import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onImage: (ImagePayload) -> Void
    /// Answers get a hover action row; the same view reused inside a work log does not.
    var showsActions = false
    /// Set only for the conversation's most recent user message, this reveals the hover "edit
    /// and resubmit" affordance next to the existing copy action on answers.
    var onEdit: (() -> Void)? = nil
    @State private var hovering = false
    /// Reported by the answer's AppKit text view, which owns the pointer while it is over prose.
    @State private var textHovering = false

    var body: some View {
        Group {
            switch message.role {
            case .user: userMessage
            case .assistant: assistantMessage
            case .tool, .bash: ToolResultRow(message: message, onImage: onImage)
            case .custom: CustomMessageRow(message: message, onImage: onImage)
            case .system: SystemMessageRow(message: message)
            case .unknown: UnknownMessageRow(message: message)
            }
        }
        .help(timestampHelp)
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: PiTheme.space4) {
            HStack {
                Spacer(minLength: PiTheme.space32 * 2)
                VStack(alignment: .leading, spacing: PiTheme.transcriptBlockSpacing) { blockList(showThinking: false, fillWidth: false) }
                    .padding(.horizontal, PiTheme.space16)
                    .padding(.vertical, PiTheme.space10)
                    .background(Color.piUserBubble, in: RoundedRectangle(cornerRadius: PiTheme.userBubbleRadius, style: .continuous))
            }
            if showsActions, let onEdit {
                UserMessageActionRow(onEdit: onEdit)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
        // `.contain` keeps the role announcement while leaving image and disclosure controls
        // inside the bubble individually reachable by VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from you")
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: PiTheme.transcriptBlockSpacing) {
            if message.isError {
                PiGridRow(symbol: "exclamationmark.circle.fill", tint: Color.piRed, symbolWeight: .medium) {
                    Text("Pi error").font(PiFont.caption).foregroundStyle(Color.piRed)
                }
            }
            blockList(showThinking: true, isAnswer: true)
            if showsActions, !isStreaming, !message.textContent.isEmpty {
                MessageActionRow(message: message)
                    .opacity(hovering || textHovering ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from Pi")
    }

    @ViewBuilder
    private func blockList(showThinking: Bool, fillWidth: Bool = true, isAnswer: Bool = false) -> some View {
        ForEach(message.blocks) { block in
            switch block.kind {
            case let .text(text):
                if !text.isEmpty {
                    // The settled answer renders as one continuous, AppKit-backed selectable run
                    // (see SelectableAnswerText.swift) so a drag can cross paragraph/list/code
                    // boundaries; every other text use (user bubble, narration, streaming) keeps
                    // the existing per-block SwiftUI renderer.
                    if isAnswer, !isStreaming {
                        MarkdownAnswerText(text: text, onHoverChange: { textHovering = $0 })
                    } else {
                        MarkdownBlockView(text: text, streaming: isStreaming, fillWidth: fillWidth)
                    }
                }
            case let .image(image):
                ConversationImage(image: image, onOpen: { onImage(image) })
            case let .thinking(text):
                if showThinking, !text.isEmpty {
                    ThinkingBlockView(text: text, streaming: isStreaming)
                }
            case let .toolCall(call):
                ToolCallRow(call: call)
            case let .unknown(type, raw):
                DisclosureRow(symbol: "questionmark.square.dashed", title: "Unsupported content · \(type)") {
                    CodeBlockView(language: nil, code: raw.prettyPrinted(maxLength: PiTheme.unknownPayloadLimit))
                }
            }
        }
    }

    private var timestampHelp: String {
        guard let date = message.timestamp else { return message.role == .user ? "You" : "Pi" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

/// Pi's terminal renders thinking as visible muted Markdown unless the user explicitly hides it.
/// Desktop follows that default instead of reducing the reasoning to an empty disclosure label.
/// It still gets the shared grid treatment — an icon in the same column every other row uses —
/// so reasoning lines up with tool calls and narration instead of sitting flush at the margin.
struct ThinkingBlockView: View {
    let text: String
    let streaming: Bool

    var body: some View {
        PiGridRow(symbol: "ellipsis.bubble") {
            MarkdownBlockView(
                text: text,
                streaming: streaming,
                fillWidth: true
            )
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thinking")
    }
}

// MARK: - Turn work log

/// One turn's work: live and open while Pi is working, one quiet “Worked for …” line with a
/// separator once it has answered. This is the transcript's only rhythm marker between turns.
struct TranscriptWorkView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let block: TranscriptWorkBlock
    let onImage: (ImagePayload) -> Void

    /// `nil` until the user decides; the run's own state owns it until then.
    @State private var userExpanded: Bool?
    @State private var hovering = false

    private var isOpen: Bool { userExpanded ?? block.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.transcriptEntrySpacing) {
            Button { userExpanded = !isOpen } label: {
                HStack(spacing: PiTheme.gridGutter) {
                    // The icon column is always reserved — spinner while live, empty once
                    // settled — so the headline's text starts at the exact same origin as every
                    // row inside the log below it, active or not.
                    Group {
                        if block.isActive { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: PiTheme.gridIconColumn, alignment: .center)
                    headline
                    if block.answerFailed, !isOpen {
                        Text("· failed").font(PiFont.caption).foregroundStyle(Color.piRed)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: PiIcon.micro, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .opacity(hovering || isOpen ? 1 : 0.4)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            PiHairline()

            if isOpen {
                HStack(alignment: .top, spacing: PiTheme.space12) {
                    // A quiet rail separates the log from the answer without indenting the
                    // answer itself.
                    Rectangle()
                        .fill(Color.piHairline)
                        .frame(width: PiTheme.hairline)
                    VStack(alignment: .leading, spacing: PiTheme.transcriptEntrySpacing) {
                        ForEach(Array(block.entries.enumerated()), id: \.element.id) { index, entry in
                            Group {
                                switch entry {
                                case let .thinking(value):
                                    ThinkingBlockView(text: value.text, streaming: value.streaming)
                                case let .activity(group):
                                    TranscriptActivityGroupView(group: group, onImage: onImage)
                                case let .note(message):
                                    WorkNoteView(message: message, onImage: onImage)
                                }
                            }
                            .opacity(entryOpacity(at: index))
                            .transition(.opacity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: block.entries.count)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
        // A turn that starts working again owns its own disclosure once more, so a stale
        // collapse can never hide live work.
        .onChange(of: block.isActive) { _, active in
            if active { userExpanded = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.isActive ? "Pi is working" : block.title)
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
    }

    private func entryOpacity(at index: Int) -> Double {
        guard block.isActive, !reduceTransparency else { return 1 }
        return max(0.45, 1 - 0.15 * Double(block.entries.count - index - 1))
    }

    @ViewBuilder
    private var headline: some View {
        if block.isActive, let startedAt = block.startedAt {
            // One timer, and only while a turn is actually in flight.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Working for \(NumberFormatting.duration(context.date.timeIntervalSince(startedAt)))")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            Text(block.isActive ? "Working" : block.title)
                .font(PiFont.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Mid-turn narration reads as log, not as the answer, so it stays quiet inside the work block.
private struct WorkNoteView: View {
    let message: ChatMessage
    let onImage: (ImagePayload) -> Void

    var body: some View {
        if message.role == .assistant {
            PiGridRow(symbol: "text.bubble") {
                MarkdownBlockView(text: message.textContent)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Pi narration")
        } else {
            MessageView(message: message, isStreaming: false, onImage: onImage)
        }
    }
}

/// Compaction is a real event in the session, so it gets its own visible marker instead of
/// hiding inside a generic system row.
struct CompactionRowView: View {
    let note: TranscriptCompaction
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.transcriptRowSpacing) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PiTheme.space8) {
                    PiHairline()
                    HStack(spacing: PiTheme.space4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: PiIcon.micro, weight: .medium))
                        Text(note.title)
                            .font(PiFont.caption)
                        if !note.summary.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: PiIcon.micro, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .opacity(hovering || expanded ? 1 : 0.4)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    PiHairline()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(note.summary.isEmpty)

            if expanded, !note.summary.isEmpty {
                MarkdownBlockView(text: note.summary)
                    .foregroundStyle(.secondary)
                    .padding(PiTheme.space10)
                    .piInset()
            }
        }
        .padding(.vertical, PiTheme.space4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title)
    }
}

/// The last user message's hover action: loads its text (and images) back into the composer for
/// editing and resubmission, mirroring the answer's copy action one-for-one in placement and
/// visual weight.
private struct UserMessageActionRow: View {
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Spacer(minLength: 0)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: PiIcon.small, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit and resubmit")
            .accessibilityLabel("Edit and resubmit this message")
        }
    }
}

/// Copy and timestamp, revealed on hover so a settled answer stays clean.
private struct MessageActionRow: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.textContent, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: PiIcon.small, weight: .medium))
                    .foregroundStyle(copied ? Color.piGreen : Color.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy message")
            .accessibilityLabel("Copy message")

            if let timestamp = message.timestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(PiFont.micro)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared disclosure row

/// The single collapsed-row treatment for thinking, tool calls, tool results, custom, system, and
/// unknown entries. One icon column, one text origin, one chevron: every transcript row lines up.
private struct DisclosureRow<Detail: View>: View {
    let symbol: String
    let title: String
    var titleTint: Color = .secondary
    var trailing: String?
    var symbolTint: Color = .secondary
    var showsProgress = false
    /// A web/browser step's target site, shown as a small favicon right after the title — the
    /// same treatment Codex gives a link reference. `nil` for every non-web row.
    var favicon: URL?
    /// When this flips true, a disclosure that opened while work was live settles closed.
    var collapseSignal = false
    @ViewBuilder var detail: () -> Detail

    @State private var expanded: Bool
    @State private var hovering = false

    init(
        symbol: String,
        title: String,
        titleTint: Color = .secondary,
        trailing: String? = nil,
        symbolTint: Color = .secondary,
        showsProgress: Bool = false,
        favicon: URL? = nil,
        initiallyExpanded: Bool = false,
        collapseSignal: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.symbol = symbol
        self.title = title
        self.titleTint = titleTint
        self.trailing = trailing
        self.symbolTint = symbolTint
        self.showsProgress = showsProgress
        self.favicon = favicon
        self.collapseSignal = collapseSignal
        self.detail = detail
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.transcriptRowSpacing) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: PiTheme.gridGutter) {
                    Group {
                        if showsProgress { ProgressView().controlSize(.mini) }
                        else {
                            Image(systemName: symbol)
                                .font(.system(size: PiIcon.small, weight: .regular))
                                .foregroundStyle(symbolTint)
                        }
                    }
                    .frame(width: PiTheme.gridIconColumn, alignment: .center)

                    Text(title)
                        .font(PiFont.caption)
                        .foregroundStyle(titleTint)
                        .lineLimit(1)
                    if let favicon {
                        FaviconView(url: favicon, size: 12)
                    }
                    if let trailing {
                        Text(trailing)
                            .font(PiFont.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: PiTheme.space4)
                    PiChevron(expanded: expanded)
                        .opacity(hovering || expanded ? 1 : 0.35)
                }
                .frame(minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                detail()
                    .padding(.leading, PiTheme.gridTextInset)
            }
        }
        .onChange(of: collapseSignal) { _, shouldCollapse in
            if shouldCollapse { expanded = false }
        }
    }
}

/// Expanded tool call/result payload: plain monospaced text sitting directly in the flow at the
/// shared text origin. Earlier this reused `CodeBlockView`, which put every argument/result on a
/// recessed `piInset` card — fine for a fenced code block in an answer, but it made routine tool
/// detail read like a block quote nested inside the already-indented disclosure row. This has no
/// card, no tint, and wraps instead of scrolling, so it just sits there. Content itself is still
/// bounded/truncated upstream (`prettyPrinted(maxLength:)`, `SessionParser`'s own caps), which is
/// unchanged by this view.
private struct ToolDetailText: View {
    let code: String

    var body: some View {
        Text(code)
            .font(PiFont.code)
            .foregroundStyle(.secondary)
            .lineSpacing(PiFont.codeLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Activity rollup

struct TranscriptActivityGroupView: View {
    let group: TranscriptActivityGroup
    let onImage: (ImagePayload) -> Void

    var body: some View {
        DisclosureRow(
            symbol: group.kinds.first?.symbol ?? ToolActivityKind.tool.symbol,
            title: group.summary,
            titleTint: group.hasFailure ? Color.piRed : .secondary,
            trailing: group.progressText,
            symbolTint: group.hasFailure ? Color.piRed : .secondary,
            // The one canonical live spinner is always the last transcript row.
            showsProgress: false,
            initiallyExpanded: group.shouldStartExpanded,
            collapseSignal: !group.isActive
        ) {
            VStack(alignment: .leading, spacing: PiTheme.transcriptRowSpacing) {
                ForEach(group.steps) { step in
                    ToolActivityStepRow(step: step, isLive: group.isActive, onImage: onImage)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let status = group.hasFailure ? "failed" : (group.isActive ? "in progress" : "completed")
        return "Activity, \(group.summary), \(group.steps.count) steps, \(status)"
    }
}

private struct ToolActivityStepRow: View {
    let step: TranscriptActivityStep
    /// A step left unfinished by a killed run must not spin forever in a historical transcript.
    let isLive: Bool
    let onImage: (ImagePayload) -> Void

    var body: some View {
        DisclosureRow(
            symbol: step.failed ? "xmark.circle" : (step.complete ? "checkmark.circle" : step.kind.symbol),
            title: step.displayName,
            trailing: step.failed ? "failed" : (step.complete ? nil : (isLive ? "running" : "no result")),
            symbolTint: step.failed ? Color.piRed : .secondary,
            showsProgress: !step.complete && isLive,
            favicon: WebActivityLink.url(for: step),
            initiallyExpanded: step.failed
        ) {
            VStack(alignment: .leading, spacing: PiTheme.space8) {
                if step.kind == .question {
                    QuestionnaireCallSummary(arguments: step.arguments)
                } else if step.arguments != .object([:]) {
                    Text("Arguments").font(PiFont.micro).foregroundStyle(.tertiary)
                    ToolDetailText(code: step.arguments.prettyPrinted(maxLength: 8_000))
                }
                if let result = step.result {
                    Text("Result").font(PiFont.micro).foregroundStyle(.tertiary)
                    ForEach(result.blocks) { block in
                        switch block.kind {
                        case let .text(text):
                            if !text.isEmpty { ToolDetailText(code: text) }
                        case let .image(image):
                            ConversationImage(image: image, onOpen: { onImage(image) })
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .accessibilityLabel("\(step.displayName), \(step.failed ? "failed" : (step.complete ? "completed" : "running"))")
    }
}

// MARK: - Rows

private struct ConversationImage: View {
    let image: ImagePayload
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            Group {
                if let nsImage = image.nsImage { Image(nsImage: nsImage).resizable().scaledToFit() }
                else { PiUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark") }
            }
            .frame(maxWidth: PiTheme.transcriptImageMaxWidth, maxHeight: PiTheme.transcriptImageMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open image")
        .accessibilityLabel(image.fileName.map { "Image \($0)" } ?? "Conversation image")
        .accessibilityHint("Opens the image viewer")
    }
}

private struct ToolCallRow: View {
    let call: ToolCallPayload
    var body: some View {
        DisclosureRow(symbol: ToolSymbol.forName(call.name), title: displayName, trailing: nil) {
            if call.name == "ask_user_question" {
                QuestionnaireCallSummary(arguments: call.arguments)
            } else {
                ToolDetailText(code: call.arguments.prettyPrinted(maxLength: 8_000))
            }
        }
    }

    private var displayName: String {
        call.name.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord
    }
}

/// `ask_user_question` is answered in the native sheet, so the transcript lists the questions
/// that were asked instead of dumping the tool's raw JSON arguments.
private struct QuestionnaireCallSummary: View {
    let arguments: JSONValue

    private var questions: [QuestionnaireQuestion] {
        QuestionnaireParser.parse(toolCallID: "transcript", arguments: arguments)?.questions ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space4) {
            if questions.isEmpty {
                Text("Asked in the native questionnaire")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(questions) { question in
                    HStack(alignment: .firstTextBaseline, spacing: PiTheme.space6) {
                        Text(question.header)
                            .font(PiFont.micro.weight(.medium))
                            .foregroundStyle(.tertiary)
                        Text(question.question)
                            .font(PiFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions asked in the native questionnaire")
    }
}

private struct ToolResultRow: View {
    let message: ChatMessage
    let onImage: (ImagePayload) -> Void

    var body: some View {
        DisclosureRow(
            symbol: message.isError ? "xmark.circle" : "checkmark.circle",
            title: title,
            trailing: message.isError ? "failed" : nil,
            symbolTint: message.isError ? Color.piRed : .secondary
        ) {
            VStack(alignment: .leading, spacing: PiTheme.space8) {
                ForEach(message.blocks) { block in
                    switch block.kind {
                    case let .text(text):
                        if !text.isEmpty { ToolDetailText(code: text) }
                    case let .image(image):
                        ConversationImage(image: image, onOpen: { onImage(image) })
                    default: EmptyView()
                    }
                }
            }
        }
    }

    private var title: String {
        if let name = message.toolName { return name.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord }
        return message.role == .bash ? "Shell command" : "Tool result"
    }
}

private struct CustomMessageRow: View {
    let message: ChatMessage
    let onImage: (ImagePayload) -> Void

    var body: some View {
        DisclosureRow(
            symbol: "puzzlepiece.extension",
            title: message.customType?.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord ?? "Extension",
            symbolTint: Color.piPurple
        ) {
            VStack(alignment: .leading, spacing: PiTheme.space8) {
                if !message.textContent.isEmpty {
                    MarkdownBlockView(text: message.textContent)
                        .foregroundStyle(.secondary)
                }
                ForEach(message.images) { image in
                    ConversationImage(image: image, onOpen: { onImage(image) })
                }
            }
        }
    }
}

private struct SystemMessageRow: View {
    let message: ChatMessage

    var body: some View {
        DisclosureRow(symbol: "text.append", title: title) {
            Text(detail)
                .font(PiFont.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String { text(from: message.blocks.first) ?? "Session context" }
    private var detail: String { message.blocks.dropFirst().compactMap(text(from:)).joined(separator: "\n") }
    private func text(from block: MessageBlock?) -> String? {
        guard let block, case let .text(value) = block.kind else { return nil }
        return value
    }
}

private struct UnknownMessageRow: View {
    let message: ChatMessage
    var body: some View {
        DisclosureRow(symbol: "sparkles", title: "New Pi entry") {
            CodeBlockView(language: nil, code: message.raw.prettyPrinted(maxLength: PiTheme.unknownPayloadLimit))
        }
    }
}

// MARK: - Symbols

enum ToolSymbol {
    static func forName(_ name: String) -> String {
        ToolActivityKind.classify(toolName: name).symbol
    }
}

extension String {
    /// Sentence case for tool and custom-type names: "Web search", not "Web Search".
    var capitalizedFirstWord: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
