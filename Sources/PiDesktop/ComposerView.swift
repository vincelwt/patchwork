import AppKit
import PiDeskKit
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
    @State private var editorHeight: CGFloat = PiTheme.composerMinEditorHeight
    /// Starting Pi is a first-edit side effect, not work every repeated key should perform.
    @State private var preparedRuntimeRouteID: String?

    private var content: Binding<ComposerContent> {
        Binding(
            get: { model.content },
            set: { value in
                guard model.content != value else { return }
                model.content = value
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

    var body: some View {
        VStack(spacing: 0) {
            OutboxStrip()

            NativeComposerTextView(
                content: content,
                bridge: bridge,
                placeholder: placeholder,
                autofocus: autofocus,
                onSubmit: handleSend,
                onEscape: { store.stopFromEscape(fully: $0) },
                admitImages: { store.admitAttachments($0, existing: $1) },
                onHeightChange: { editorHeight = $0 }
            )
            .frame(height: clampedHeight)
            .padding(.horizontal, PiTheme.space10)
            .padding(.top, PiTheme.space8)

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
        .background(Color.piTranscript, in: RoundedRectangle(cornerRadius: PiTheme.composerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PiTheme.composerRadius, style: .continuous)
                .stroke(Color.piHairline, lineWidth: PiTheme.hairline)
        }
        .onChange(of: focusSignal) { _, _ in
            bridge.resetEscapeSequence?()
            bridge.focus?()
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
            store.enqueueOutbox(text: text, delivery: delivery, attachments: attachments)
            model.content = .empty
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
        HStack(spacing: PiTheme.space8) {
            IconButton(symbol: "plus", help: "Attach images", action: onAttach)
                .accessibilityLabel("Attach images")

            ComposerRuntimeLabel()

            if store.runtimeState.queueCount > 0, store.isSelectedRuntime {
                QueueMenu()
            }

            Spacer(minLength: PiTheme.space8)

            // The composer carries one control: how hard Pi should work. Model and thinking
            // level are reported in the status bar.
            ModeSlider()

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
                    Image(systemName: "chevron.up").font(.system(size: PiIcon.small, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .help("Choose delivery mode")
                .accessibilityLabel("Delivery mode")
            }

            Button(action: onSend) {
                Image(systemName: isStreaming ? "arrow.turn.up.right" : "arrow.up")
                    .font(.system(size: PiIcon.small, weight: .semibold))
                    .foregroundStyle(canSend ? Color(nsColor: .textBackgroundColor) : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(canSend ? Color.primary : Color.piInsetStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(isStreaming ? "Steer current run" : "Send")
            .accessibilityLabel(isStreaming ? "Steer current run" : "Send message")
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.bottom, PiTheme.space8)
        .padding(.top, PiTheme.space4)
    }
}

/// The active agent's mode ladder as a continuous choice from most restrained to strongest. For
/// Pi that is the `/mode` effort ladder (model, thinking level, subagents); for Codex the sandbox
/// policy; for Claude Code the permission mode. One control, agent-specific stops. It disappears
/// when the agent has not reported a mode on that ladder.
struct ModeSlider: View {
    @EnvironmentObject private var store: AppStore

    private var modes: [AgentMode] { store.availableModes }
    private var mode: AgentMode? { store.currentMode }
    private var title: String { store.activeCapabilities.modeControlTitle }

    @ViewBuilder
    var body: some View {
        if let mode, modes.count > 1 {
            let rank = modes.firstIndex { $0.id == mode.id } ?? 0
            HStack(spacing: PiTheme.space6) {
                Text(mode.title)
                    .font(rank == modes.count - 1 ? PiFont.captionEmphasis : PiFont.caption)
                    .foregroundStyle(PiTheme.effortColor(rank: rank, of: modes.count))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                // AppKit's slider cannot be restyled, so this gets its own calm-to-hot track.
                PiEffortTrack(modes: modes, mode: mode) { store.setAgentMode($0.id) }
                    .frame(width: PiTheme.effortTrackWidth, height: PiTheme.effortUltraKnobDiameter)
            }
            .help("\(title) \(mode.title) · \(mode.detail)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(mode.title), \(mode.detail)")
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? rank + 1 : rank - 1
                guard modes.indices.contains(next) else { return }
                store.setAgentMode(modes[next].id)
            }
        }
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
                .font(.system(size: PiIcon.small, weight: .medium))
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
            if store.isOffline {
                Label(store.runtimeState.isWaitingForNetwork ? "Offline · paused" : "Offline", systemImage: "wifi.slash")
                    .foregroundStyle(Color.piOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isWaitingForNetwork {
                Label("Resuming", systemImage: "arrow.clockwise")
                    .foregroundStyle(Color.piOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isCompacting {
                Label("Compacting", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Color.piPurple)
            } else if store.isSelectedRuntime,
                      let queue = store.statusModel.values[ExtensionStatusParser.providerQueueKey], !queue.isEmpty {
                Label(queue, systemImage: "hourglass")
                    .foregroundStyle(Color.piOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isRetrying {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = store.runtimeState.retrySecondsRemaining(at: context.date)
                    Label(remaining.map { $0 > 0 ? "Retry in \($0)s" : "Retrying" }
                        ?? "Retry \(store.runtimeState.retryAttempt ?? 1)", systemImage: "arrow.clockwise")
                }
                .foregroundStyle(Color.piOrange)
                .help(store.runtimeState.retryErrorMessage ?? "Retrying the last provider request")
            } else if let label = store.currentRouteRuntimePhase?.label {
                HStack(spacing: PiTheme.space4) {
                    StatusDot(color: .piGreen, pulsing: true)
                    Text(label)
                }
                .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
        .font(PiFont.caption)
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
