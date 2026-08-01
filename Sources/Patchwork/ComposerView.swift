import AppKit
import PatchworkKit
import SwiftUI
import UniformTypeIdentifiers

/// Steering reaches Pi immediately so it can be applied at the next model/tool boundary. A
/// follow-up stays editable in the outbox until the active turn settles. An armed
/// edit-and-resubmit (`isEditingLastMessage`) always goes direct regardless of streaming state:
/// it replaces the turn in place rather than queuing alongside it.
enum ComposerSubmitRoute: Equatable {
    case direct
    case queue(OutboxEntry.Delivery)

    static func decide(
        intent: OutboxEntry.Delivery,
        isStreaming: Bool,
        isEditingLastMessage: Bool,
        canSend: Bool
    ) -> ComposerSubmitRoute {
        guard canSend, isStreaming, !isEditingLastMessage, intent == .followUp else { return .direct }
        return .queue(.followUp)
    }
}

struct ComposerView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: ComposerModel
    var isStreaming: Bool
    var placeholder = "Ask Pi anything…"
    var autofocus = false
    /// Bumped by the parent whenever content is programmatically loaded into the composer (the
    /// edit-and-resubmit affordance) so focus follows it back to the text view.
    var focusSignal = 0
    var onSend: () -> Void
    var onSteer: (() -> Void)?
    var onFollowUp: (() -> Void)?
    var onAbort: (() -> Void)?

    @State private var bridge = ComposerBridge()
    @State private var editorHeight: CGFloat = PatchworkTheme.composerMinEditorHeight
    /// Starting Pi is a first-edit side effect, not work every repeated key should perform.
    @State private var preparedRuntimeRouteID: String?
    @State private var paletteSelection = 0
    /// Escape closes the palette without touching the draft; it stays closed until the draft
    /// stops being a bare `/token`.
    @State private var paletteDismissed = false

    private var content: Binding<ComposerContent> {
        Binding(
            get: { model.content },
            set: { value in
                guard model.content != value else { return }
                model.content = value
                if paletteDismissed, SlashCommandPalette.query(in: value) == nil { paletteDismissed = false }
                let routeID = runtimeRouteID
                if preparedRuntimeRouteID != routeID {
                    preparedRuntimeRouteID = routeID
                    store.composerContentDidChange()
                }
            }
        )
    }

    private var text: String { model.content.text }
    private var attachments: [ImageAttachment] { model.content.attachments }
    private var runtimeRouteID: String {
        switch store.route {
        case let .session(path): return "session:\(path)"
        case .newChat: return "new-chat:\(store.selectedFolder?.path ?? "")"
        }
    }

    /// Non-nil only while the draft is a bare `/token` and the agent can enumerate commands.
    private var paletteQuery: String? {
        guard !paletteDismissed, store.activeCapabilities.listsCommands else { return nil }
        return SlashCommandPalette.query(in: model.content)
    }

    private var paletteMatches: [AgentCommand] {
        // Another conversation's runtime must never lend its commands to a composer that is not
        // attached to it; until this route answers, `isLoadingCommands` keeps the box honest.
        guard let paletteQuery, store.isCurrentRouteRuntime else { return [] }
        return SlashCommandPalette.filter(
            store.availableCommands,
            query: paletteQuery,
            limit: PatchworkTheme.commandPaletteResultLimit
        )
    }

    var body: some View {
        VStack(spacing: PatchworkTheme.space6) {
            if let paletteQuery {
                SlashCommandPaletteView(
                    query: paletteQuery,
                    matches: paletteMatches,
                    agent: store.activeAgent,
                    isLoading: store.isLoadingCommands,
                    selection: $paletteSelection,
                    run: runCommand
                )
                // Idempotent: the same query-only prewarm the first edit already performs, so a
                // palette opened after a failed or skipped prepare still fills itself.
                .onAppear { store.prepareComposerOptions() }
            }
            editor
        }
        .onChange(of: paletteQuery) { _, _ in paletteSelection = 0 }
        // A conversation switch swaps the draft without passing through the editor, so the
        // dismissal has to be forgotten here or the next `/` would open nothing.
        .onChange(of: store.route) { _, _ in
            paletteDismissed = false
            paletteSelection = 0
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            OutboxStrip()

            NativeComposerTextView(
                content: content,
                bridge: bridge,
                placeholder: placeholder,
                autofocus: autofocus,
                onSubmit: handleSend,
                onEscape: { store.stopFromEscape(fully: $0) },
                onPaletteKey: handlePaletteKey,
                admitImages: { store.admitAttachments($0, existing: $1) },
                onHeightChange: { editorHeight = $0 }
            )
            .frame(height: clampedHeight)
            .padding(.horizontal, PatchworkTheme.space10)
            .padding(.top, PatchworkTheme.space8)

            ComposerToolbar(
                isStreaming: isStreaming,
                canSend: canSend,
                onAttach: chooseImages,
                onSend: handleSend,
                onSteer: onSteer.map { _ in handleSteer },
                onFollowUp: onFollowUp.map { _ in handleFollowUp },
                onAbort: onAbort
            )
        }
        .background(Color.patchworkTranscript, in: RoundedRectangle(cornerRadius: PatchworkTheme.composerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PatchworkTheme.composerRadius, style: .continuous)
                .stroke(Color.patchworkHairline, lineWidth: PatchworkTheme.hairline)
        }
        .onChange(of: focusSignal) { _, _ in
            bridge.resetEscapeSequence?()
            bridge.focus?()
        }
    }

    private var canSend: Bool {
        !AppStore.sanitizedMessage(text).isEmpty || !attachments.isEmpty
    }

    // MARK: - Slash commands

    /// The palette gets first refusal on Up/Down/Return/Escape. Returning false hands the key
    /// straight back to the text view, so send, Shift+Return, caret movement, and the
    /// single/double Escape sequence are untouched whenever the palette is closed or empty.
    private func handlePaletteKey(_ key: ComposerPaletteKey) -> Bool {
        guard paletteQuery != nil else { return false }
        switch SlashCommandPalette.outcome(
            for: key,
            selection: paletteSelection,
            matchCount: paletteMatches.count
        ) {
        case .ignored:
            return false
        case let .move(index):
            paletteSelection = index
            return true
        case let .run(index):
            guard paletteMatches.indices.contains(index) else { return false }
            runCommand(paletteMatches[index])
            return true
        case .dismiss:
            paletteDismissed = true
            return true
        }
    }

    /// Runs through the store's single command path; the agent's own output is the feedback.
    private func runCommand(_ command: AgentCommand) {
        model.content = .empty
        paletteSelection = 0
        paletteDismissed = false
        store.runExtensionCommand(command.prompt)
    }

    private var clampedHeight: CGFloat {
        min(PatchworkTheme.composerMaxEditorHeight, max(PatchworkTheme.composerMinEditorHeight, editorHeight))
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

    // MARK: - Outbox routing

    /// The round "send" affordance always means "steer" once a turn is in progress, matching the
    /// delivery `submitDraft(delivery: .automatic)` already picks.
    private func handleSend() { route(intent: .steer, direct: onSend) }

    private func handleSteer() {
        guard let onSteer else { return }
        route(intent: .steer, direct: onSteer)
    }

    private func handleFollowUp() {
        guard let onFollowUp else { return }
        route(intent: .followUp, direct: onFollowUp)
    }

    /// Follow-ups stay editable until settlement; steering goes straight to Pi. See `Outbox.swift`.
    private func route(intent: OutboxEntry.Delivery, direct: () -> Void) {
        switch ComposerSubmitRoute.decide(
            intent: intent,
            isStreaming: isStreaming,
            isEditingLastMessage: store.isEditingLastMessage,
            canSend: canSend
        ) {
        case .direct:
            direct()
        case let .queue(delivery):
            if store.enqueueOutbox(text: text, delivery: delivery, attachments: attachments) {
                model.content = .empty
            }
        }
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
        HStack(spacing: PatchworkTheme.space8) {
            IconButton(symbol: "plus", help: "Attach images", action: onAttach)
                .accessibilityLabel("Attach images")

            ComposerRuntimeLabel()

            if store.runtimeState.queueCount > 0, store.isSelectedRuntime {
                QueueMenu()
            }

            Spacer(minLength: PatchworkTheme.space8)

            if store.canStopCurrentThread, let onAbort {
                IconButton(symbol: "stop.fill", help: "Stop Thread (⌘.)", action: onAbort)
                    .accessibilityLabel("Stop Thread")
            }

            if isStreaming, let onSteer, let onFollowUp {
                Menu {
                    Button("Steer current run", action: onSteer)
                    Button("Queue as follow-up", action: onFollowUp)
                    Divider()
                    QueueModeControls()
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: PatchworkIcon.small, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .help("Choose delivery mode")
                .accessibilityLabel("Delivery mode")
            }

            Button(action: onSend) {
                Image(systemName: isStreaming ? "arrow.turn.up.right" : "arrow.up")
                    .font(.system(size: PatchworkIcon.small, weight: .semibold))
                    .foregroundStyle(canSend ? Color(nsColor: .textBackgroundColor) : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(canSend ? Color.primary : Color.patchworkInsetStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(isStreaming ? "Steer current run" : "Send")
            .accessibilityLabel(isStreaming ? "Steer current run" : "Send message")
        }
        .padding(.horizontal, PatchworkTheme.space10)
        .padding(.bottom, PatchworkTheme.space8)
        .padding(.top, PatchworkTheme.space4)
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
                .font(.system(size: PatchworkIcon.small, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(
                    hovering ? Color.patchworkHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: PatchworkTheme.radiusSmall, style: .continuous)
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
            if store.isOffline {
                Label(store.runtimeState.isWaitingForNetwork ? "Offline · paused" : "Offline", systemImage: "wifi.slash")
                    .foregroundStyle(Color.patchworkOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isWaitingForNetwork {
                Label("Resuming", systemImage: "arrow.clockwise")
                    .foregroundStyle(Color.patchworkOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isCompacting {
                Label("Compacting", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Color.patchworkPurple)
            } else if store.isSelectedRuntime,
                      let queue = store.statusModel.values[ExtensionStatusParser.providerQueueKey], !queue.isEmpty {
                Label(queue, systemImage: "hourglass")
                    .foregroundStyle(Color.patchworkOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isRetrying {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = store.runtimeState.retrySecondsRemaining(at: context.date)
                    Label(remaining.map { $0 > 0 ? "Retry in \($0)s" : "Retrying" }
                        ?? "Retry \(store.runtimeState.retryAttempt ?? 1)", systemImage: "arrow.clockwise")
                }
                .foregroundStyle(Color.patchworkOrange)
                .help(store.runtimeState.retryErrorMessage ?? "Retrying the last provider request")
            } else if let label = store.currentRouteRuntimePhase?.label {
                HStack(spacing: PatchworkTheme.space4) {
                    StatusDot(color: .patchworkGreen, pulsing: true)
                    Text(label)
                }
                .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
        .font(PatchworkFont.caption)
        .lineLimit(1)
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
                .font(PatchworkFont.caption)
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
