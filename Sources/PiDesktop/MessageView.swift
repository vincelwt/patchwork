import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onImage: (ImagePayload) -> Void

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
        HStack {
            Spacer(minLength: PiTheme.space32 * 2)
            VStack(alignment: .leading, spacing: PiTheme.space8) { blockList(showThinking: false, fillWidth: false) }
                .padding(.horizontal, PiTheme.space12)
                .padding(.vertical, PiTheme.space8)
                .background(Color.piUserBubble, in: RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous))
        }
        // `.contain` keeps the role announcement while leaving image and disclosure controls
        // inside the bubble individually reachable by VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from you")
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: PiTheme.space8) {
            if message.isError {
                PiGridRow(symbol: "exclamationmark.circle.fill", tint: Color.piRed, symbolWeight: .medium) {
                    Text("Pi error").font(PiFont.caption).foregroundStyle(Color.piRed)
                }
            }
            blockList(showThinking: true)
            if isStreaming {
                PiGridProgressRow {
                    Text("Pi is working").font(PiFont.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from Pi")
    }

    @ViewBuilder
    private func blockList(showThinking: Bool, fillWidth: Bool = true) -> some View {
        ForEach(message.blocks) { block in
            switch block.kind {
            case let .text(text):
                if !text.isEmpty { MarkdownBlockView(text: text, streaming: isStreaming, fillWidth: fillWidth) }
            case let .image(image):
                ConversationImage(image: image, onOpen: { onImage(image) })
            case let .thinking(text):
                if showThinking, !text.isEmpty {
                    DisclosureRow(symbol: "sparkle", title: "Thinking") {
                        Text(MarkdownInline.plain(text, size: PiFont.bodySize - 1))
                            .lineSpacing(PiFont.bodyLineSpacing)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
        initiallyExpanded: Bool = false,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.symbol = symbol
        self.title = title
        self.titleTint = titleTint
        self.trailing = trailing
        self.symbolTint = symbolTint
        self.showsProgress = showsProgress
        self.detail = detail
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: PiTheme.gridGutter) {
                    Group {
                        if showsProgress { ProgressView().controlSize(.mini) }
                        else {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(symbolTint)
                        }
                    }
                    .frame(width: PiTheme.gridIconColumn, alignment: .center)

                    Text(title)
                        .font(PiFont.caption)
                        .foregroundStyle(titleTint)
                        .lineLimit(1)
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
            showsProgress: group.isActive && !group.hasFailure,
            initiallyExpanded: group.hasFailure
        ) {
            VStack(alignment: .leading, spacing: PiTheme.space8) {
                ForEach(group.steps) { step in
                    ToolActivityStepRow(step: step, onImage: onImage)
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
    let onImage: (ImagePayload) -> Void

    var body: some View {
        DisclosureRow(
            symbol: step.failed ? "xmark.circle" : (step.complete ? "checkmark.circle" : step.kind.symbol),
            title: step.displayName,
            trailing: step.failed ? "failed" : (step.complete ? nil : "running"),
            symbolTint: step.failed ? Color.piRed : .secondary,
            showsProgress: !step.complete,
            initiallyExpanded: step.failed
        ) {
            VStack(alignment: .leading, spacing: PiTheme.space8) {
                if step.kind == .question {
                    Text("Answered in the native questionnaire")
                        .font(PiFont.caption)
                        .foregroundStyle(.secondary)
                } else if step.arguments != .object([:]) {
                    Text("Arguments").font(PiFont.micro).foregroundStyle(.tertiary)
                    CodeBlockView(language: nil, code: step.arguments.prettyPrinted(maxLength: 8_000))
                }
                if let result = step.result {
                    Text("Result").font(PiFont.micro).foregroundStyle(.tertiary)
                    ForEach(result.blocks) { block in
                        switch block.kind {
                        case let .text(text):
                            if !text.isEmpty { CodeBlockView(language: nil, code: text) }
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
                else { ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark") }
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
            CodeBlockView(language: nil, code: call.arguments.prettyPrinted(maxLength: 8_000))
        }
    }

    private var displayName: String {
        call.name.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord
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
                        if !text.isEmpty { CodeBlockView(language: nil, code: text) }
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
                    MarkdownBlockView(text: message.textContent, size: PiFont.bodySize - 1)
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
                .font(PiFont.caption)
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
