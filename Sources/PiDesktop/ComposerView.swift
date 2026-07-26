import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var text: String
    @Binding var attachments: [ImageAttachment]
    var isStreaming: Bool
    var placeholder = "Ask Pi anything…"
    var onSend: () -> Void
    var onSteer: (() -> Void)?
    var onFollowUp: (() -> Void)?
    var onAbort: (() -> Void)?

    @State private var bridge = ComposerBridge()
    @State private var editorHeight: CGFloat = PiTheme.composerMinEditorHeight

    private var content: Binding<ComposerContent> {
        Binding(
            get: { ComposerContent(text: text, attachments: attachments) },
            set: { value in
                if text != value.text { text = value.text }
                if attachments != value.attachments { attachments = value.attachments }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                NativeComposerTextView(
                    content: content,
                    bridge: bridge,
                    onSubmit: onSend,
                    admitImages: { store.admitAttachments($0, existing: $1) },
                    onHeightChange: { editorHeight = $0 }
                )
                .frame(height: clampedHeight)
                .padding(.horizontal, PiTheme.space10)
                .padding(.top, PiTheme.space8)

                if text.isEmpty, attachments.isEmpty {
                    Text(placeholder)
                        .font(PiFont.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, PiTheme.space12)
                        .padding(.top, PiTheme.space10)
                        .allowsHitTesting(false)
                }
            }

            ComposerToolbar(
                isStreaming: isStreaming,
                canSend: canSend,
                onAttach: chooseImages,
                onSend: onSend,
                onSteer: onSteer,
                onFollowUp: onFollowUp,
                onAbort: onAbort
            )
        }
        .background(Color.piTranscript, in: RoundedRectangle(cornerRadius: PiTheme.composerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PiTheme.composerRadius, style: .continuous)
                .stroke(Color.piHairline, lineWidth: PiTheme.hairline)
        }
    }

    private var canSend: Bool {
        !AppStore.sanitizedMessage(text).isEmpty || !attachments.isEmpty
    }

    private var clampedHeight: CGFloat {
        min(PiTheme.composerMaxEditorHeight, max(PiTheme.composerMinEditorHeight, editorHeight))
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        // Routed through the text view so the + button previews inline at the caret too.
        bridge.insertImages?(ImageImportService.attachments(from: panel.urls))
        bridge.focus?()
    }
}

private struct ComposerToolbar: View {
    @EnvironmentObject private var store: AppStore
    let isStreaming: Bool
    let canSend: Bool
    let onAttach: () -> Void
    let onSend: () -> Void
    let onSteer: (() -> Void)?
    let onFollowUp: (() -> Void)?
    let onAbort: (() -> Void)?

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            IconButton(symbol: "plus", help: "Attach images", action: onAttach)
                .accessibilityLabel("Attach images")

            ComposerRuntimeLabel()

            if store.runtimeState.queueCount > 0, store.isSelectedRuntime {
                QueueMenu()
            }

            Spacer(minLength: PiTheme.space8)

            ComposerMetricsMenu()

            Button(action: store.cycleThinkingLevel) {
                Text(thinkingLabel)
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSelectedRuntime)
            .help("Thinking level")

            Button(action: store.cycleModel) {
                Text(modelLabel)
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSelectedRuntime)
            .help(modelHelp)

            if isStreaming, let onAbort {
                IconButton(symbol: "stop.fill", help: "Stop Pi (⌘.)", action: onAbort)
            }

            if isStreaming, let onSteer, let onFollowUp {
                Menu {
                    Button("Steer current run", action: onSteer)
                    Button("Queue as follow-up", action: onFollowUp)
                    Divider()
                    QueueModeControls()
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .help("Choose delivery mode")
            }

            Button(action: onSend) {
                Image(systemName: isStreaming ? "arrow.turn.up.right" : "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canSend ? Color(nsColor: .textBackgroundColor) : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(canSend ? Color.primary : Color.piInsetStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(isStreaming ? "Steer current run" : "Send")
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.bottom, PiTheme.space8)
        .padding(.top, PiTheme.space4)
    }

    private var thinkingLabel: String {
        store.isSelectedRuntime
            ? (store.runtimeState.thinkingLevel ?? "off")
            : (store.selectedSession?.thinkingLevel ?? "off")
    }
    private var modelLabel: String {
        if store.isSelectedRuntime { return store.runtimeState.modelName ?? store.runtimeState.modelID ?? "Model" }
        return store.selectedSession?.model ?? "Model"
    }
    private var modelHelp: String {
        let provider = store.isSelectedRuntime ? store.runtimeState.provider : store.selectedSession?.provider
        return provider.map { "\($0) · \(modelLabel)" } ?? modelLabel
    }
}

/// The single hover/pressed treatment used by every borderless icon control.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(
                    hovering ? Color.piHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: PiTheme.radiusSmall, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ComposerRuntimeLabel: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Group {
            if store.isSelectedRuntime, store.runtimeState.isCompacting {
                Label("Compacting", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Color.piPurple)
            } else if store.isSelectedRuntime, store.runtimeState.isRetrying {
                Label("Retry \(store.runtimeState.retryAttempt ?? 1)", systemImage: "arrow.clockwise")
                    .foregroundStyle(Color.piOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isStreaming {
                HStack(spacing: PiTheme.space4) {
                    ProgressView().controlSize(.mini)
                    Text("Working")
                }
                .foregroundStyle(.secondary)
            } else if store.isSelectedRuntime, store.runtimeState.isConnected {
                Text("Ready").foregroundStyle(.secondary)
            } else {
                Text("Pi starts on send").foregroundStyle(.tertiary)
            }
        }
        .font(PiFont.caption)
        .lineLimit(1)
    }
}

private struct ComposerMetricsMenu: View {
    @EnvironmentObject private var store: AppStore
    private var metrics: TokenMetrics { store.selectedMetrics }

    var body: some View {
        Menu {
            Text("Input  \(NumberFormatting.tokens(metrics.input))")
            Text("Output  \(NumberFormatting.tokens(metrics.output))")
            Text("Cache read  \(NumberFormatting.tokens(metrics.cacheRead))")
            Text("Cache write  \(NumberFormatting.tokens(metrics.cacheWrite))")
            if let hit = metrics.latestCacheHitPercent { Text("Latest cache hit  \(Int(hit.rounded()))%") }
            Divider()
            if let tokens = metrics.contextTokens, let window = metrics.contextWindow {
                Text("Context  \(NumberFormatting.tokens(tokens)) / \(NumberFormatting.tokens(window))")
            }
            if let percent = metrics.contextPercent { Text("Context usage  \(Int(percent.rounded()))%") }
            Text("Cost  \(NumberFormatting.cost(metrics.cost))")
        } label: {
            HStack(spacing: PiTheme.space4) {
                if let percent = metrics.contextPercent { Text("\(Int(percent.rounded()))%") }
                Text(NumberFormatting.cost(metrics.cost))
            }
            .font(PiFont.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Session tokens, cache, context, and cost")
    }
}

private struct QueueMenu: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Menu {
            if !store.runtimeState.steeringQueue.isEmpty {
                Text("Steering · \(store.runtimeState.steeringMode)")
                ForEach(Array(store.runtimeState.steeringQueue.enumerated()), id: \.offset) { index, text in
                    Text("\(index + 1). \(text)")
                }
            }
            if !store.runtimeState.followUpQueue.isEmpty {
                if !store.runtimeState.steeringQueue.isEmpty { Divider() }
                Text("Follow-ups · \(store.runtimeState.followUpMode)")
                ForEach(Array(store.runtimeState.followUpQueue.enumerated()), id: \.offset) { index, text in
                    Text("\(index + 1). \(text)")
                }
            }
            Divider()
            QueueModeControls()
        } label: {
            Label("\(store.runtimeState.queueCount)", systemImage: "text.line.last.and.arrowtriangle.forward")
                .font(PiFont.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Queued steering and follow-up messages")
    }
}

struct QueueModeControls: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Menu("Steering mode") {
            Button("All") { store.setQueueMode(steering: true, mode: "all") }
            Button("One at a time") { store.setQueueMode(steering: true, mode: "one-at-a-time") }
        }
        Menu("Follow-up mode") {
            Button("All") { store.setQueueMode(steering: false, mode: "all") }
            Button("One at a time") { store.setQueueMode(steering: false, mode: "one-at-a-time") }
        }
    }
}
