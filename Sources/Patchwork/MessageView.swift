import SwiftUI

private extension MessageBlock {
    var imagePayload: ImagePayload? {
        guard case let .image(image) = kind else { return nil }
        return image
    }
}

private extension ChatMessage {
    func imageRun(startingAt index: Int) -> [ImagePayload] {
        blocks[index...].prefix { $0.imagePayload != nil }.compactMap(\.imagePayload)
    }

    func isRenderEquivalent(to other: ChatMessage) -> Bool {
        guard id == other.id, role == other.role, timestamp == other.timestamp,
              toolCallID == other.toolCallID, toolName == other.toolName,
              isError == other.isError, customType == other.customType,
              details == other.details, raw == other.raw,
              blocks.count == other.blocks.count else { return false }
        return zip(blocks, other.blocks).allSatisfy { lhs, rhs in
            guard lhs.id == rhs.id else { return false }
            switch (lhs.kind, rhs.kind) {
            case let (.image(a), .image(b)):
                // Session entries are append-only; a stable image id/size cannot change bytes.
                return a.id == b.id && a.data.count == b.data.count
                    && a.mimeType == b.mimeType && a.fileName == b.fileName
            default:
                return lhs.kind == rhs.kind
            }
        }
    }
}

private extension TranscriptActivityStep {
    func isRenderEquivalent(to other: TranscriptActivityStep) -> Bool {
        guard id == other.id, name == other.name, kind == other.kind,
              arguments == other.arguments else { return false }
        switch (result, other.result) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isRenderEquivalent(to: rhs)
        default: return false
        }
    }
}

private extension TranscriptWorkEntry {
    func isRenderEquivalent(to other: TranscriptWorkEntry) -> Bool {
        switch (self, other) {
        case let (.thinking(a), .thinking(b)):
            return a == b
        case let (.note(a), .note(b)):
            return a.isRenderEquivalent(to: b)
        case let (.activity(a), .activity(b)):
            return a.id == b.id && a.isActive == b.isActive
                && a.steps.count == b.steps.count
                && zip(a.steps, b.steps).allSatisfy { $0.isRenderEquivalent(to: $1) }
        default:
            return false
        }
    }
}

private extension TranscriptWorkBlock {
    func isRenderEquivalent(to other: TranscriptWorkBlock) -> Bool {
        id == other.id && isActive == other.isActive
            && startedAt == other.startedAt && endedAt == other.endedAt
            && answerFailed == other.answerFailed
            && entries.count == other.entries.count
            && zip(entries, other.entries).allSatisfy { $0.isRenderEquivalent(to: $1) }
    }
}

struct MessageView: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    /// Clicked image plus the images of the message it came from, so the viewer can arrow within
    /// that group.
    let onImage: (ImagePayload, [ImagePayload]) -> Void
    /// Answers get a hover action row; the same view reused inside a work log does not.
    var showsActions = false
    /// Set only for the conversation's most recent user message, this reveals the hover "edit
    /// and resubmit" affordance next to the existing copy action on answers.
    var onEdit: (() -> Void)? = nil
    @State private var hovering = false
    /// Reported by selectable AppKit text, which owns the pointer while it is over prose.
    @State private var textHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message.isRenderEquivalent(to: rhs.message)
            && lhs.isStreaming == rhs.isStreaming
            && lhs.showsActions == rhs.showsActions
            && (lhs.onEdit != nil) == (rhs.onEdit != nil)
        // `onImage`/`onEdit` always target the same AppStore for this route; ignoring fresh
        // function wrappers lets SwiftUI keep an unchanged realized row intact.
    }

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
        VStack(alignment: .trailing, spacing: PatchworkTheme.space4) {
            HStack {
                Spacer(minLength: PatchworkTheme.space32 * 2)
                VStack(alignment: .leading, spacing: PatchworkTheme.transcriptBlockSpacing) { blockList(showThinking: false, fillWidth: false) }
                    .padding(.horizontal, PatchworkTheme.space16)
                    .padding(.vertical, PatchworkTheme.space10)
                    .background(Color.patchworkUserBubble, in: RoundedRectangle(cornerRadius: PatchworkTheme.userBubbleRadius, style: .continuous))
            }
            if showsActions, let onEdit {
                UserMessageActionRow(onEdit: onEdit)
                    .opacity(hovering || textHovering ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
        // `.contain` keeps the role announcement while leaving image and disclosure controls
        // inside the bubble individually reachable by VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from you")
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.transcriptBlockSpacing) {
            if message.isError {
                PatchworkGridRow(symbol: "exclamationmark.circle.fill", tint: Color.patchworkRed, symbolWeight: .medium) {
                    Text("Agent error").font(PatchworkFont.caption).foregroundStyle(Color.patchworkRed)
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
        .accessibilityLabel("Message from agent")
    }

    @ViewBuilder
    private func blockList(showThinking: Bool, fillWidth: Bool = true, isAnswer: Bool = false) -> some View {
        ForEach(Array(message.blocks.enumerated()), id: \.element.id) { index, block in
            switch block.kind {
            case let .text(text):
                if !text.isEmpty {
                    // Settled answers and user messages use one AppKit-backed selectable run so
                    // a drag can cross paragraph/list/code boundaries. Streaming and work-log
                    // text keep the per-block SwiftUI renderer.
                    if !isStreaming, isAnswer || message.role == .user {
                        MarkdownAnswerText(
                            text: text,
                            fillWidth: fillWidth,
                            accessibilityLabel: isAnswer ? "Answer" : "Your message",
                            onHoverChange: { textHovering = $0 }
                        )
                    } else {
                        MarkdownBlockView(text: text, streaming: isStreaming, fillWidth: fillWidth)
                    }
                }
            case .image:
                if index == 0 || message.blocks[index - 1].imagePayload == nil {
                    ConversationImageStrip(
                        images: message.imageRun(startingAt: index),
                        onOpen: { onImage($0, message.images) }
                    )
                }
            case let .thinking(text):
                if showThinking, !text.isEmpty {
                    ThinkingBlockView(text: text, streaming: isStreaming)
                }
            case let .toolCall(call):
                ToolCallRow(call: call)
            case let .note(note):
                DisclosureRow(
                    symbol: note.symbol,
                    title: note.summary.isEmpty ? note.title : "\(note.title) · \(note.summary)"
                ) {
                    if note.body.isEmpty {
                        EmptyView()
                    } else {
                        CodeBlockView(language: nil, code: note.body)
                    }
                }
            case let .unknown(type, raw):
                DisclosureRow(symbol: "questionmark.square.dashed", title: "Unsupported content · \(type)") {
                    CodeBlockView(language: nil, code: raw.prettyPrinted(maxLength: PatchworkTheme.unknownPayloadLimit))
                }
            }
        }
    }

    private var timestampHelp: String {
        guard let date = message.timestamp else { return message.role == .user ? "You" : "Agent" }
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
        PatchworkGridRow(symbol: "ellipsis.bubble") {
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

struct WorkDisclosureState: Equatable {
    var userChoice: Bool?

    func isOpen(default defaultOpen: Bool) -> Bool { userChoice ?? defaultOpen }

    mutating func toggle(default defaultOpen: Bool) {
        userChoice = !isOpen(default: defaultOpen)
    }

    mutating func transition(from wasActive: Bool, to isActive: Bool) {
        if wasActive, !isActive { userChoice = false }
    }
}

/// One turn's work: live reasoning stays collapsed behind its latest thought unless the user
/// opens it; settled details become one quiet “Worked for …” line while prominent output remains.
struct TranscriptWorkView: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let block: TranscriptWorkBlock
    let onImage: (ImagePayload, [ImagePayload]) -> Void
    /// Busts the equatable transcript-row cache when a live questionnaire appears, moves, or ends.
    let questionnaireKey: String?

    /// `nil` until the user decides; the run's own state owns it until then.
    @State private var disclosure = WorkDisclosureState()
    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block.isRenderEquivalent(to: rhs.block)
            && lhs.questionnaireKey == rhs.questionnaireKey
    }

    private var isOpen: Bool { disclosure.isOpen(default: block.shouldStartExpanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.transcriptEntrySpacing) {
            if block.entries.isEmpty {
                header(showsDisclosure: false)
            } else {
                Button { disclosure.toggle(default: block.shouldStartExpanded) } label: {
                    header(showsDisclosure: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            }

            if isOpen, !block.entries.isEmpty {
                VStack(alignment: .leading, spacing: PatchworkTheme.transcriptEntrySpacing) {
                    ForEach(Array(block.entries.enumerated()), id: \.element.id) { index, entry in
                        Group {
                            switch entry {
                            case let .thinking(value):
                                ThinkingBlockView(text: value.text, streaming: value.streaming)
                            case let .activity(group):
                                TranscriptActivityGroupView(group: group)
                            case let .note(message):
                                WorkNoteView(message: message, onImage: onImage)
                            }
                        }
                        .opacity(entryOpacity(at: index))
                        .transition(.opacity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            ForEach(block.prominentSteps) { step in
                if step.kind == .question {
                    InlineQuestionnaire(
                        toolCallID: step.id,
                        arguments: step.arguments,
                        showsSummaryWhenInactive: false
                    )
                }
                if step.id == block.firstProminentImageStepID {
                    ConversationImageStrip(
                        images: block.prominentImages,
                        onOpen: { onImage($0, block.prominentImages) }
                    )
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: block.entries.count)
        .animation(reduceMotion || reduceTransparency ? nil : .easeOut(duration: 0.18), value: block.latestStatusText)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
        .onChange(of: block.isActive) { wasActive, isActive in
            disclosure.transition(from: wasActive, to: isActive)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.isActive ? "Agent is working" : block.title)
        .accessibilityValue(block.entries.isEmpty ? "" : (isOpen ? "work details expanded" : "work details collapsed"))
    }

    private func header(showsDisclosure: Bool) -> some View {
        HStack(spacing: PatchworkTheme.gridGutter) {
            // The icon column is always reserved while live or settled, so the headline
            // starts at the same origin as every row inside the log below it.
            Group {
                if block.isActive { StatusDot(color: .patchworkGreen, pulsing: true) }
            }
            .frame(width: PatchworkTheme.gridIconColumn, alignment: .center)
            headline
            if block.answerFailed, !isOpen {
                Text("· failed").font(PatchworkFont.caption).foregroundStyle(Color.patchworkRed)
            }
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: PatchworkIcon.micro, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(hovering || isOpen ? 1 : 0.4)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
    }

    private func entryOpacity(at index: Int) -> Double {
        guard block.isActive, !reduceTransparency else { return 1 }
        return max(0.45, 1 - 0.15 * Double(block.entries.count - index - 1))
    }

    private var showsStatusHeadline: Bool {
        block.isActive || block.answerFailed || block.endsWithCompaction
    }

    private var headline: some View {
        HStack(spacing: PatchworkTheme.space6) {
            Text(block.isActive ? (block.latestStatusText ?? "Thinking")
                : (showsStatusHeadline ? (block.latestStatusText ?? block.title) : block.title))
                .font(PatchworkFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            if block.isActive {
                ActiveWorkElapsedView(block: block)
            } else if showsStatusHeadline, let duration = block.duration {
                Text("· \(NumberFormatting.duration(duration))")
                    .font(PatchworkFont.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }
}

/// A leaf timeline updates the clock without publishing a per-second AppStore change or
/// invalidating the surrounding transcript and its AppKit text selections.
private struct ActiveWorkElapsedView: View {
    let block: TranscriptWorkBlock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let elapsed = block.elapsed(at: context.date) {
                Text("· \(NumberFormatting.duration(elapsed))")
                    .font(PatchworkFont.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }
}

/// Mid-turn narration reads as log, while exceptional messages keep their distinct treatment.
private struct WorkNoteView: View {
    let message: ChatMessage
    let onImage: (ImagePayload, [ImagePayload]) -> Void

    var body: some View {
        if let compaction = TranscriptCompaction(message: message) {
            CompactionRowView(note: compaction)
        } else if message.role == .assistant, !message.isError {
            PatchworkGridRow(symbol: "text.bubble") {
                MarkdownBlockView(text: message.textContent)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Agent narration")
        } else {
            MessageView(
                message: message,
                isStreaming: false,
                onImage: onImage
            )
            .equatable()
        }
    }
}

/// Compaction stays recognizable inside the turn's collapsed work log and reveals its summary
/// only on demand.
struct CompactionRowView: View {
    let note: TranscriptCompaction
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.transcriptRowSpacing) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PatchworkTheme.space8) {
                    HStack(spacing: PatchworkTheme.space4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: PatchworkIcon.micro, weight: .medium))
                        Text(note.title)
                            .font(PatchworkFont.caption)
                        if !note.summary.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: PatchworkIcon.micro, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .opacity(hovering || expanded ? 1 : 0.4)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(note.summary.isEmpty)

            if expanded, !note.summary.isEmpty {
                MarkdownBlockView(text: note.summary)
                    .foregroundStyle(.secondary)
                    .padding(PatchworkTheme.space10)
                    .patchworkInset()
            }
        }
        .padding(.vertical, PatchworkTheme.space4)
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
        HStack(spacing: PatchworkTheme.space8) {
            Spacer(minLength: 0)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: PatchworkIcon.small, weight: .medium))
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
        HStack(spacing: PatchworkTheme.space8) {
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
                    .font(.system(size: PatchworkIcon.small, weight: .medium))
                    .foregroundStyle(copied ? Color.patchworkGreen : Color.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy message")
            .accessibilityLabel("Copy message")

            if let timestamp = message.timestamp {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(PatchworkFont.micro)
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
    /// Held open regardless of the user's own toggle, for a row the user must be able to act on
    /// right now (an unanswered question). Normal behaviour resumes once it goes false.
    var forceExpanded = false
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
        forceExpanded: Bool = false,
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
        self.forceExpanded = forceExpanded
        self.detail = detail
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var isOpen: Bool { forceExpanded || expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.transcriptRowSpacing) {
            Button { expanded = !isOpen } label: {
                HStack(alignment: .firstTextBaseline, spacing: PatchworkTheme.gridGutter) {
                    Group {
                        if showsProgress { StatusDot(color: .patchworkGreen, pulsing: true) }
                        else {
                            Image(systemName: symbol)
                                .font(.system(size: PatchworkIcon.small, weight: .regular))
                                .foregroundStyle(symbolTint)
                        }
                    }
                    .frame(width: PatchworkTheme.gridIconColumn, alignment: .center)

                    Text(title)
                        .font(PatchworkFont.caption)
                        .foregroundStyle(titleTint)
                        .lineLimit(1)
                    if let favicon {
                        FaviconView(url: favicon, size: 12)
                    }
                    if let trailing {
                        Text(trailing)
                            .font(PatchworkFont.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: PatchworkTheme.space4)
                    PatchworkChevron(expanded: isOpen)
                        .opacity(hovering || isOpen ? 1 : 0.35)
                }
                .frame(minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isOpen {
                detail()
                    .padding(.leading, PatchworkTheme.gridTextInset)
            }
        }
        .onChange(of: collapseSignal) { _, shouldCollapse in
            if shouldCollapse { expanded = false }
        }
    }
}

/// Expanded tool call/result payload: plain monospaced text sitting directly in the flow at the
/// shared text origin. Earlier this reused `CodeBlockView`, which put every argument/result on a
/// recessed `patchworkInset` card — fine for a fenced code block in an answer, but it made routine tool
/// detail read like a block quote nested inside the already-indented disclosure row. This has no
/// card, no tint, and wraps instead of scrolling, so it just sits there. Content itself is still
/// bounded/truncated upstream (`prettyPrinted(maxLength:)`, `SessionParser`'s own caps), which is
/// unchanged by this view.
private struct ToolDetailText: View {
    let code: String

    var body: some View {
        Text(code)
            .font(PatchworkFont.code)
            .foregroundStyle(.secondary)
            .lineSpacing(PatchworkFont.codeLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Activity rollup

struct TranscriptActivityGroupView: View {
    let group: TranscriptActivityGroup

    var body: some View {
        DisclosureRow(
            symbol: group.kinds.first?.symbol ?? ToolActivityKind.tool.symbol,
            title: group.summary,
            titleTint: group.hasFailure ? Color.patchworkRed : .secondary,
            trailing: group.progressText,
            symbolTint: group.hasFailure ? Color.patchworkRed : .secondary,
            // The canonical live indicator lives on the work headline.
            showsProgress: false,
            initiallyExpanded: group.shouldStartExpanded,
            collapseSignal: !group.isActive
        ) {
            VStack(alignment: .leading, spacing: PatchworkTheme.transcriptRowSpacing) {
                ForEach(group.steps) { step in
                    ToolActivityStepRow(
                        step: step,
                        isLive: group.isActive
                    )
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
    @EnvironmentObject private var store: AppStore
    let step: TranscriptActivityStep
    /// A step left unfinished by a killed run must not spin forever in a historical transcript.
    let isLive: Bool

    var body: some View {
        DisclosureRow(
            symbol: step.failed ? "xmark.circle" : (step.complete ? "checkmark.circle" : step.kind.symbol),
            title: step.displayName,
            trailing: step.failed ? "failed" : (step.complete ? nil : (isLive ? "running" : "no result")),
            symbolTint: step.failed ? Color.patchworkRed : .secondary,
            showsProgress: !step.complete && isLive,
            favicon: WebActivityLink.url(for: step),
            initiallyExpanded: step.failed
        ) {
            VStack(alignment: .leading, spacing: PatchworkTheme.space8) {
                if step.kind == .question {
                    if store.activeQuestionnaire(for: step.id) == nil {
                        QuestionnaireCallSummary(arguments: step.arguments)
                    }
                } else if step.arguments != .object([:]) {
                    Text("Arguments").font(PatchworkFont.micro).foregroundStyle(.tertiary)
                    ToolDetailText(code: step.arguments.prettyPrinted(maxLength: 8_000))
                }
                if !step.resultTextBlocks.isEmpty {
                    Text("Result").font(PatchworkFont.micro).foregroundStyle(.tertiary)
                    ForEach(step.resultTextBlocks) { block in
                        if case let .text(text) = block.kind { ToolDetailText(code: text) }
                    }
                }
            }
        }
        .accessibilityLabel("\(step.displayName), \(step.failed ? "failed" : (step.complete ? "completed" : "running"))")
    }
}

// MARK: - Rows

/// Multiple previews share one bounded-height strip instead of making image-heavy turns grow by
/// one full preview height per image.
private struct ConversationImageStrip: View {
    let images: [ImagePayload]
    let onOpen: (ImagePayload) -> Void

    @ViewBuilder var body: some View {
        if images.count == 1, let image = images.first {
            ConversationImage(image: image, onOpen: { onOpen(image) })
        } else if !images.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: PatchworkTheme.transcriptBlockSpacing) {
                    ForEach(images) { image in
                        ConversationImage(image: image, onOpen: { onOpen(image) })
                    }
                }
            }
        }
    }
}

/// Renders the bounded thumbnail, never the full bitmap: a cache hit draws synchronously, a
/// miss reserves the image's exact final frame (header-only size read) and decodes off the main
/// thread, so realizing an image-heavy row while scrolling costs no decode on the main thread
/// and never shifts layout when the bitmap lands.
private struct ConversationImage: View {
    let image: ImagePayload
    let onOpen: () -> Void
    @State private var decoded: NSImage?
    @State private var decodeFailed = false

    var body: some View {
        Button(action: onOpen) {
            Group {
                if let thumbnail = decoded ?? ImageThumbnailer.cachedThumbnail(for: image) {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else if decodeFailed {
                    PatchworkUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: PatchworkTheme.transcriptImageMaxWidth, maxHeight: PatchworkTheme.transcriptImageMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: PatchworkTheme.radiusMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open image")
        .accessibilityLabel(image.fileName.map { "Image \($0)" } ?? "Conversation image")
        .accessibilityHint("Opens the image viewer")
        .task(id: image.id) {
            guard decoded == nil, ImageThumbnailer.cachedThumbnail(for: image) == nil else { return }
            let payload = image
            let thumbnail = await Task.detached(priority: .userInitiated) {
                ImageThumbnailer.thumbnail(for: payload)
            }.value
            guard !Task.isCancelled, payload.id == image.id else { return }
            if let thumbnail { decoded = thumbnail } else { decodeFailed = true }
        }
    }

    /// The exact frame the thumbnail will occupy, so the swap is invisible to layout. Unknown
    /// dimensions fall back to a modest fixed panel rather than a zero-size flash.
    private var placeholder: some View {
        let size = placeholderSize
        return Color.patchworkInset
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }

    private var placeholderSize: CGSize {
        guard let points = ImageThumbnailer.layoutPointSize(of: image), points.width > 0, points.height > 0 else {
            return CGSize(width: PatchworkTheme.transcriptImageMaxWidth / 2, height: PatchworkTheme.transcriptImageMaxHeight / 2)
        }
        let scale = min(
            PatchworkTheme.transcriptImageMaxWidth / points.width,
            PatchworkTheme.transcriptImageMaxHeight / points.height,
            1
        )
        return CGSize(width: points.width * scale, height: points.height * scale)
    }
}

private struct ToolCallRow: View {
    @EnvironmentObject private var store: AppStore
    let call: ToolCallPayload

    var body: some View {
        DisclosureRow(
            symbol: ToolSymbol.forName(call.name),
            title: displayName,
            trailing: nil,
            forceExpanded: store.activeQuestionnaire(for: call.id) != nil
        ) {
            if call.name.lowercased() == "ask_user_question" {
                InlineQuestionnaire(toolCallID: call.id, arguments: call.arguments)
            } else {
                ToolDetailText(code: call.arguments.prettyPrinted(maxLength: 8_000))
            }
        }
    }

    private var displayName: String {
        call.name.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord
    }
}

/// The `ask_user_question` row reads live state; `TranscriptWorkView.questionnaireKey` also
/// invalidates its equatable parent when this otherwise-empty control must appear or disappear.
private struct InlineQuestionnaire: View {
    @EnvironmentObject private var store: AppStore
    let toolCallID: String
    let arguments: JSONValue
    var showsSummaryWhenInactive = true

    var body: some View {
        if let session = store.activeQuestionnaire(for: toolCallID),
           let question = session.currentQuestion {
            QuestionnaireCardView(session: session, question: question)
                .id("\(session.toolCallID):\(question.id)")
        } else if showsSummaryWhenInactive {
            QuestionnaireCallSummary(arguments: arguments)
        }
    }
}

/// A settled question: the transcript lists what was asked instead of dumping the tool's raw
/// JSON arguments.
private struct QuestionnaireCallSummary: View {
    let arguments: JSONValue

    private var questions: [QuestionnaireQuestion] {
        QuestionnaireParser.parse(toolCallID: "transcript", arguments: arguments)?.questions ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
            if questions.isEmpty {
                Text("Asked inline in this conversation")
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(questions) { question in
                    HStack(alignment: .firstTextBaseline, spacing: PatchworkTheme.space6) {
                        Text(question.header)
                            .font(PatchworkFont.micro.weight(.medium))
                            .foregroundStyle(.tertiary)
                        Text(question.question)
                            .font(PatchworkFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions asked inline in this conversation")
    }
}

private struct ToolResultRow: View {
    let message: ChatMessage
    let onImage: (ImagePayload, [ImagePayload]) -> Void

    var body: some View {
        DisclosureRow(
            symbol: message.isError ? "xmark.circle" : "checkmark.circle",
            title: title,
            trailing: message.isError ? "failed" : nil,
            symbolTint: message.isError ? Color.patchworkRed : .secondary
        ) {
            VStack(alignment: .leading, spacing: PatchworkTheme.space8) {
                ForEach(Array(message.blocks.enumerated()), id: \.element.id) { index, block in
                    switch block.kind {
                    case let .text(text):
                        if !text.isEmpty { ToolDetailText(code: text) }
                    case .image:
                        if index == 0 || message.blocks[index - 1].imagePayload == nil {
                            ConversationImageStrip(
                                images: message.imageRun(startingAt: index),
                                onOpen: { onImage($0, message.images) }
                            )
                        }
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
    let onImage: (ImagePayload, [ImagePayload]) -> Void

    var body: some View {
        DisclosureRow(
            symbol: "puzzlepiece.extension",
            title: title,
            symbolTint: Color.patchworkPurple
        ) {
            VStack(alignment: .leading, spacing: PatchworkTheme.space8) {
                if !message.textContent.isEmpty {
                    MarkdownBlockView(text: message.textContent)
                        .foregroundStyle(.secondary)
                }
                ConversationImageStrip(images: message.images, onOpen: { onImage($0, message.images) })
            }
        }
    }

    private var title: String {
        if message.customType == "ad-process:update" { return "Background process update" }
        return message.customType?.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord ?? "Extension"
    }
}

private struct SystemMessageRow: View {
    let message: ChatMessage

    var body: some View {
        DisclosureRow(symbol: "text.append", title: title) {
            Text(detail)
                .font(PatchworkFont.body)
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
        DisclosureRow(symbol: "sparkles", title: "New agent entry") {
            CodeBlockView(language: nil, code: message.raw.prettyPrinted(maxLength: PatchworkTheme.unknownPayloadLimit))
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
