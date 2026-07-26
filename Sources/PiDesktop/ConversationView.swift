import AppKit
import SwiftUI

/// The toolbar title pill's own bound, distinct from the transcript/composer measure — it shares
/// a toolbar with window traffic lights and the inspector toggle, so it needs a cap well short of
/// `PiTheme.transcriptMaxWidth`.
extension PiTheme {
    static let conversationTitlePillMaxWidth: CGFloat = 280
}

struct ConversationView: View {
    @EnvironmentObject private var store: AppStore
    @State private var renamePresented = false
    @State private var renameValue = ""
    /// Bumped whenever the last message's edit affordance fires, so the composer (which owns the
    /// actual `NSTextView`) knows to reclaim first responder after its content is replaced.
    @State private var composerFocusTick = 0

    var body: some View {
        GeometryReader { proxy in
            let showsInspector = ConversationLayout.showsInspector(
                requested: store.inspectorVisible,
                totalWidth: proxy.size.width
            )
            // A real reserved trailing column: the transcript and composer are laid out in the
            // remaining width instead of being covered by a floating overlay.
            HStack(spacing: 0) {
                conversationColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.piTranscript)

                if showsInspector {
                    Rectangle()
                        .fill(Color.piHairline)
                        .frame(width: PiTheme.hairline)
                    InspectorView()
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .toolbar { conversationToolbar }
        // Without this the transcript scrolls visibly under a transparent toolbar.
        .toolbarBackground(.visible, for: .windowToolbar)
        .onChange(of: store.renameRequested) { _, requested in
            guard requested else { return }
            renameValue = store.selectedSession?.displayName ?? ""
            renamePresented = true
            store.renameRequested = false
        }
        .alert("Rename conversation", isPresented: $renamePresented) {
            TextField("Conversation name", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameSelectedSession(renameValue) }
                .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The name is stored in the Pi session without contacting a model.")
        }
    }

    private var conversationColumn: some View {
        messageArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: PiTheme.space6) {
                    if let error = store.runtimeState.lastError, store.isSelectedRuntime { InlineError(text: error) }
                    if store.isEditingLastMessage {
                        EditingMessageBanner {
                            store.cancelEditingLastMessage()
                            store.draft = ""
                            store.attachments = []
                        }
                    }
                    ExtensionWidgetStrip(placement: .aboveEditor)
                    ComposerView(
                        text: $store.draft,
                        attachments: $store.attachments,
                        isStreaming: store.isSelectedRuntime && store.runtimeState.isStreaming,
                        focusSignal: composerFocusTick,
                        onSend: {
                            if store.isEditingLastMessage { store.resubmitEditedMessage() }
                            else { store.submitDraft(delivery: .automatic) }
                        },
                        onSteer: { store.submitDraft(delivery: .steer) },
                        onFollowUp: { store.submitDraft(delivery: .followUp) },
                        onAbort: store.abort
                    )
                    ExtensionWidgetStrip(placement: .belowEditor)
                }
                .frame(maxWidth: PiTheme.composerMaxWidth)
                .padding(.horizontal, PiTheme.space20)
                .padding(.top, PiTheme.space4)
                .padding(.bottom, PiTheme.space12)
                .frame(maxWidth: .infinity)
                .background(Color.piTranscript)
            }
    }

    /// Working, whether this app's runtime drives the turn or a terminal does.
    private var conversationIsRunning: Bool {
        if store.isSelectedRuntime, store.runtimeState.isStreaming { return true }
        guard let session = store.selectedSession else { return false }
        return store.isRunning(session)
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Explicit padding, a bounded width with truncation, and a `.contentShape` matching
            // the pill's own drawn bounds — the bare `HStack` this replaced had none of the
            // three, so it rendered flush against its own content and could clip inside the
            // toolbar's centered principal item.
            HStack(spacing: PiTheme.space6) {
                Image(systemName: "folder")
                    .font(.system(size: PiIcon.small))
                    .foregroundStyle(.tertiary)
                Text(store.selectedSession?.displayName ?? "Conversation")
                    .font(PiFont.rowEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let session = store.selectedSession, store.isRunning(session) {
                    ProgressView().controlSize(.mini)
                }
                Menu {
                    Button("Rename…") {
                        renameValue = store.selectedSession?.displayName ?? ""
                        renamePresented = true
                    }
                    if let session = store.selectedSession {
                        // The ⌘⇧A key equivalent is owned by the Conversation menu so it is
                        // registered exactly once for the window.
                        Button(session.isArchived ? "Unarchive" : "Archive") { store.toggleArchive(session) }
                    }
                    Divider()
                    Button("Compact Context", action: store.compact)
                        .disabled(!store.isSelectedRuntime || store.runtimeState.isStreaming)
                    Button("Export as HTML…", action: store.exportHTML)
                        .disabled(!store.isSelectedRuntime)
                    Divider()
                    Button("Reveal Session File") {
                        if let file = store.selectedSession?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: PiIcon.small, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
            }
            .padding(.horizontal, PiTheme.space10)
            .padding(.vertical, PiTheme.space4)
            .frame(maxWidth: PiTheme.conversationTitlePillMaxWidth, alignment: .leading)
            .background(Color.piInset, in: Capsule())
            .contentShape(Capsule())
            .help(store.selectedSession?.cwd.path ?? "Conversation actions")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation(.easeOut(duration: 0.16)) { store.inspectorVisible.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: PiIcon.medium, weight: .regular))
            }
            .help("Toggle Environment inspector (⌥⌘I)")
        }
    }

    @ViewBuilder
    private var messageArea: some View {
        if store.isConversationLoading {
            VStack(spacing: PiTheme.space8) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…").font(PiFont.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.conversationError {
            PiUnavailableView(
                "Couldn’t open this session",
                systemImage: "doc.badge.exclamationmark",
                description: error
            ) {
                Button("Try Again", action: store.retryConversationLoad)
            }
        } else if store.messages.isEmpty && store.streamingMessage == nil {
            VStack(spacing: PiTheme.space6) {
                Text("Ready for a new turn")
                    .font(PiFont.title)
                Text("Send a message to resume this Pi session.")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MessageScrollView(
                messages: store.messages,
                streaming: store.streamingMessage,
                isRunning: conversationIsRunning,
                onEditLastMessage: {
                    store.beginEditingLastMessage()
                    composerFocusTick += 1
                }
            )
        }
    }
}

private struct MessageScrollView: View {
    @EnvironmentObject private var store: AppStore
    let messages: [ChatMessage]
    let streaming: ChatMessage?
    /// True for a turn in flight here or in a terminal, so the live turn stays open either way.
    let isRunning: Bool
    /// Wired only to the conversation's single most recent user message; every earlier turn's
    /// bubble never receives this at all (see the `message.id == lastUserMessageID` check below).
    var onEditLastMessage: (() -> Void)?
    @State private var scrollTask: Task<Void, Never>?
    /// Tracked by a bottom sentinel appearing/disappearing, which works on macOS 14 without
    /// scroll-position APIs. Auto-scroll only happens while the user is pinned at the bottom.
    @State private var isPinnedToBottom = true
    /// This view instance can outlive a single conversation: switching from one already-loaded
    /// session straight to another never leaves the `else` branch in `messageArea`, so SwiftUI
    /// reuses the same `MessageScrollView` rather than remounting it. These two let the scroll
    /// handler tell "a different conversation just replaced this one" (always snap to bottom)
    /// apart from "the same conversation grew" (animate a genuine live append, but snap when
    /// Task 1's tail-first backfill only prepends earlier history above an unchanged tail).
    @State private var loadedRouteKey: AppRoute?
    @State private var lastKnownTailID: String?
    private let bottomID = "conversation-bottom"

    private var transcriptItems: [TranscriptItem] {
        TranscriptPresenter.items(
            messages: messages,
            streaming: streaming,
            isRunning: isRunning || (store.isSelectedRuntime && store.runtimeState.isStreaming)
        )
    }

    private var lastUserMessageID: String? { messages.last(where: { $0.role == .user })?.id }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                // A single small gap between entries keeps consecutive tool rows on an even
                // rhythm; paragraphs get their breathing room from the block renderer.
                LazyVStack(alignment: .leading, spacing: PiTheme.transcriptEntrySpacing) {
                    ForEach(transcriptItems) { item in
                        switch item {
                        case let .message(message, isStreaming):
                            MessageView(
                                message: message,
                                isStreaming: isStreaming,
                                onImage: store.showImage,
                                showsActions: true,
                                onEdit: message.role == .user && message.id == lastUserMessageID ? onEditLastMessage : nil
                            )
                            .padding(.top, message.role == .user ? PiTheme.transcriptTurnSpacing : 0)
                                .id(item.id)
                        case let .work(block):
                            TranscriptWorkView(block: block, onImage: store.showImage)
                                .padding(.top, PiTheme.space6)
                                .id(item.id)
                        case let .compaction(note):
                            CompactionRowView(note: note)
                                .padding(.vertical, PiTheme.space6)
                                .id(item.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.top, PiTheme.space24)
                .padding(.bottom, PiTheme.space8)
                // Frame the transcript content first, then add the same outer gutter as the
                // composer. This makes their visible left/right edges identical at every width.
                .frame(maxWidth: PiTheme.transcriptMaxWidth, alignment: .leading)
                .padding(.horizontal, PiTheme.space20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                isPinnedToBottom = true
                loadedRouteKey = store.route
                lastKnownTailID = transcriptItems.last?.id
                reader.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: store.route) { _, newRoute in
                // A different conversation was just selected: always resume at the bottom,
                // ignoring whatever scroll position the previous conversation was left at, and
                // never animate a jump the user did not cause (Task 1).
                loadedRouteKey = newRoute
                lastKnownTailID = transcriptItems.last?.id
                isPinnedToBottom = true
                reader.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: transcriptItems.count) { _, _ in
                // A route change above already snapped to the bottom for this same swap; do not
                // also animate here just because the message count happened to change too.
                guard loadedRouteKey == store.route else { return }
                guard isPinnedToBottom else {
                    lastKnownTailID = transcriptItems.last?.id
                    return
                }
                let tailChanged = transcriptItems.last?.id != lastKnownTailID
                lastKnownTailID = transcriptItems.last?.id
                if tailChanged {
                    withAnimation(.easeOut(duration: 0.18)) { reader.scrollTo(bottomID, anchor: .bottom) }
                } else {
                    // Same tail, more (earlier) history filled in above it — Task 1's cache-miss
                    // backfill. Snap instantly: nothing the user is looking at should move.
                    reader.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: streaming?.textContent.count ?? 0) { _, _ in
                scheduleBottomScroll(reader)
            }
            .onDisappear { scrollTask?.cancel() }
            .overlay(alignment: .bottom) {
                if !isPinnedToBottom {
                    Button {
                        scrollTask?.cancel()
                        isPinnedToBottom = true
                        withAnimation(.easeOut(duration: 0.18)) { reader.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(PiFont.caption)
                            .padding(.horizontal, PiTheme.space10)
                            .padding(.vertical, PiTheme.space6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.piTranscript, in: Capsule())
                    .overlay { Capsule().stroke(Color.piHairline, lineWidth: PiTheme.hairline) }
                    .padding(.bottom, PiTheme.space10)
                    .transition(.opacity)
                    .help("Scroll to the newest message")
                }
            }
        }
    }

    private func scheduleBottomScroll(_ reader: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, isPinnedToBottom else { return }
            reader.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

/// Extension widgets render at their documented placement around the composer.
struct ExtensionWidgetStrip: View {
    enum Placement: String { case aboveEditor, belowEditor }

    @EnvironmentObject private var store: AppStore
    let placement: Placement

    private var widgets: [ExtensionWidget] {
        store.extensionWidgets.values
            .filter { $0.placement == placement.rawValue }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        if !widgets.isEmpty {
            VStack(alignment: .leading, spacing: PiTheme.space6) {
                ForEach(widgets) { widget in
                    VStack(alignment: .leading, spacing: PiTheme.space2) {
                        Text(widget.key)
                            .font(PiFont.micro.weight(.medium))
                            .foregroundStyle(.tertiary)
                        ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                            Text(ANSI.strip(line))
                                .font(PiFont.codeSmall)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, PiTheme.space10)
            .padding(.vertical, PiTheme.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .piInset()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Extension widgets \(placement == .aboveEditor ? "above" : "below") the composer")
        }
    }
}

/// Shown above the composer while an edit is armed, so it is obvious the next Send replaces the
/// last turn instead of starting a new one, with an explicit way out.
private struct EditingMessageBanner: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: "pencil")
                .font(.system(size: PiIcon.small, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Editing your last message")
                .font(PiFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: PiTheme.space8)
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(PiFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.vertical, PiTheme.space6)
        .background(Color.piInset, in: RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct InlineError: View {
    let text: String
    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: PiIcon.small))
                .foregroundStyle(Color.piRed)
            Text(text).font(PiFont.caption).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.vertical, PiTheme.space8)
        .background(Color.piRed.opacity(0.08), in: RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous))
    }
}
