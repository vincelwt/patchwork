import AppKit
import SwiftUI

/// The toolbar title's own bound, distinct from the transcript/composer measure — it shares
/// a toolbar with window traffic lights and the inspector toggle, so it needs a cap well short of
/// `PiTheme.transcriptMaxWidth`.
extension PiTheme {
    static let conversationTitleMaxWidth: CGFloat = 280
}

@MainActor
final class TranscriptProjectionCache {
    private var route: AppRoute?
    private var revision = -1
    private var isRunning = false
    private var cached: [TranscriptItem] = []
    private(set) var buildCount = 0

    func items(
        route: AppRoute = .newChat,
        revision: Int,
        messages: [ChatMessage],
        streaming: ChatMessage?,
        isRunning: Bool
    ) -> [TranscriptItem] {
        guard self.route != route || self.revision != revision || self.isRunning != isRunning else { return cached }
        if self.route != route { cached.removeAll(keepingCapacity: true) }
        self.route = route
        self.revision = revision
        self.isRunning = isRunning
        let projected = TranscriptPresenter.items(messages: messages, streaming: streaming, isRunning: isRunning)
        cached = preservingWorkIDs(in: projected)
        buildCount += 1
        return cached
    }

    private func preservingWorkIDs(in projected: [TranscriptItem]) -> [TranscriptItem] {
        var previousIDByEntry: [String: String] = [:]
        for case let .work(block) in cached {
            for entry in block.entries { previousIDByEntry[entry.id] = block.id }
        }
        var used: Set<String> = []
        return projected.map { item in
            guard case var .work(block) = item,
                  let priorID = block.entries.lazy.compactMap({ previousIDByEntry[$0.id] }).first,
                  used.insert(priorID).inserted else { return item }
            block.id = priorID
            return .work(block)
        }
    }
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
                    .contentShape(Rectangle())
                    .onDrop(of: ImageImportService.dropTypes, isTargeted: nil) { providers in
                        let route = store.route
                        return ImageImportService.loadDroppedAttachments(from: providers) { images in
                            guard store.route == route, !images.isEmpty else { return }
                            store.addAttachments(images)
                            composerFocusTick += 1
                        }
                    }

                if showsInspector {
                    Rectangle()
                        .fill(Color.piHairline)
                        .frame(width: PiTheme.hairline)
                    InspectorView()
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .piPlainToolbar { conversationToolbar }
        // Without this the transcript scrolls visibly under a transparent toolbar.
        .toolbarBackground(.visible, for: .windowToolbar)
        // Switching conversations keeps the already-mounted composer first responder: the row's
        // `autofocus` only fires on first mount, so the same focus signal covers the rest.
        .onChange(of: store.route) { _, _ in composerFocusTick += 1 }
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
            // The transcript's structural swaps (loading → content, `.id(route)` remounts) must
            // never inherit an ambient animation. `withAnimation` around any shared-store
            // mutation (a toast appearing, for example) animates every view diff batched into
            // that update, which turned those swaps into opacity crossfades; an interrupted
            // crossfade left the whole conversation ghosted at partial opacity until a scroll
            // forced fresh layers. Row-level `.animation(_, value:)` modifiers set their own
            // animation downstream of this strip, so in-row micro-animations still play.
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: PiTheme.space6) {
                    runtimeError
                    if store.isEditingLastMessage {
                        EditingMessageBanner {
                            store.cancelEditingLastMessage()
                            store.draft = ""
                            store.attachments = []
                        }
                    }
                    ExtensionWidgetStrip(placement: .aboveEditor)
                    ComposerView(
                        model: store.composer,
                        isStreaming: store.isSelectedRuntime && store.runtimeState.isStreaming,
                        autofocus: true,
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

    @ViewBuilder
    private var runtimeError: some View {
        if let error = store.runtimeState.lastError, store.isSelectedRuntime {
            InlineError(text: error, retryEnabled: store.canRetryLastFailure) {
                store.retryLastFailedTurn()
            }
        }
    }

    /// Working, whether this app's runtime drives the turn or a terminal does.
    private var conversationIsRunning: Bool {
        if store.isSelectedRuntime, store.runtimeState.isStreaming { return true }
        guard let session = store.selectedSession else { return false }
        return store.isRunning(session)
    }

    /// The open conversation's full sidebar categorization, e.g.
    /// `lexirise > product > growth > convo name`, so the toolbar says where it lives and not only
    /// what it is called. Same helper the sidebar's Status rows use.
    private var breadcrumb: String {
        guard let session = store.selectedSession else { return "Conversation" }
        return store.categorization(of: session).joined(separator: " > ")
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        // Leading placement, so the title reads as the conversation pane's header rather than a
        // floating centered pill. Bounded width plus tail truncation keeps a long name from
        // pushing the trailing toolbar items around.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: PiTheme.space6) {
                Image(systemName: "folder")
                    .font(.system(size: PiIcon.small))
                    .foregroundStyle(.tertiary)
                Text(breadcrumb)
                    .font(PiFont.rowEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Truncated on screen, complete on hover and to VoiceOver.
                    .help(breadcrumb)
                    .accessibilityLabel(breadcrumb)
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
                        .disabled(!store.isSelectedRuntime || store.runtimeState.isBusy)
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
            .frame(maxWidth: PiTheme.conversationTitleMaxWidth, alignment: .leading)
            .contentShape(Rectangle())
            .help(store.selectedSession?.cwd.path ?? "Conversation actions")
        }

        // Keep the inspector control at the trailing edge on macOS 26 toolbars.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        // Only present once the conversation actually opened a pull request.
        if let link = store.pullRequestLink {
            ToolbarItem(placement: .primaryAction) {
                Link(destination: link) {
                    Label(
                        PullRequestLink.number(in: link) ?? "Pull request",
                        systemImage: "arrow.triangle.pull"
                    )
                    .font(PiFont.caption)
                }
                .help(link.absoluteString)
                .accessibilityLabel("Open pull request \(PullRequestLink.number(in: link) ?? "") in your browser")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation(.easeOut(duration: 0.16)) { store.inspectorVisible.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: PiIcon.small, weight: .regular))
            }
            .buttonStyle(.borderless)
            .help("Toggle Environment inspector (⌥⌘I)")
        }
    }

    @ViewBuilder
    private var messageArea: some View {
        if store.isConversationLoading && store.messages.isEmpty {
            DelayedConversationLoadingView()
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
                transcriptRevision: store.transcriptRevision,
                onEditLastMessage: {
                    store.beginEditingLastMessage()
                    composerFocusTick += 1
                }
            )
        }
    }
}

struct MessageScrollView: View {
    @EnvironmentObject private var store: AppStore
    let messages: [ChatMessage]
    let streaming: ChatMessage?
    /// True for a turn in flight here or in a terminal, so the live turn stays open either way.
    let isRunning: Bool
    let transcriptRevision: Int
    /// Wired only to the conversation's single most recent user message.
    var onEditLastMessage: (() -> Void)?
    @State private var isPinnedToBottom = true
    @State private var pinRequest = 0
    @State private var underfillPageAttempts = 0
    @State private var didMarkFirstTextPaint = false
    @State private var projectionCache = TranscriptProjectionCache()

    private var transcriptItems: [TranscriptItem] {
        projectionCache.items(
            route: store.route,
            revision: transcriptRevision,
            messages: messages,
            streaming: streaming,
            isRunning: isRunning
        )
    }

    private var history: NativeTranscriptHistory? {
        if store.isLoadingEarlierMessages { return .loading }
        if store.hasEarlierMessages { return .loadEarlier }
        if store.conversationHistoryLimitReached { return .limitReached }
        return nil
    }

    private var lastUserMessageID: String? { messages.last(where: { $0.role == .user })?.id }

    /// Changes when the inline questionnaire appears or moves to another buffered question.
    private var questionnaireKey: String? {
        store.activeQuestionnaireSession.map { "\($0.toolCallID):\($0.currentIndex)" }
    }

    private var questionnaireToolCallID: String? { store.activeQuestionnaireSession?.toolCallID }

    var body: some View {
        let items = transcriptItems
        let rows = NativeTranscriptRow.rows(
            items: items,
            history: history,
            lastUserMessageID: lastUserMessageID,
            questionnaireToolCallID: questionnaireToolCallID,
            questionnaireKey: questionnaireKey
        )
        NativeTranscriptView(
            route: store.route,
            rows: rows,
            isLoadingEarlier: store.isLoadingEarlierMessages,
            pinRequest: pinRequest,
            performancePath: store.selectedSession?.fileURL.path ?? "new-chat",
            onLoadEarlier: { _ = requestEarlierMessages() },
            onEditLastMessage: onEditLastMessage,
            onMetrics: handleScrollMetrics,
            onFirstPaint: {
                guard !didMarkFirstTextPaint else { return }
                didMarkFirstTextPaint = true
                ConversationPerformance.mark(
                    "Conversation first text paint",
                    path: store.selectedSession?.fileURL.path ?? "new-chat",
                    count: items.count
                )
            }
        )
        .piHardTopScrollEdge()
        .scrollDismissesKeyboard(.interactively)
        .onAppear { store.consumeInitialScrollTarget() }
        .onChange(of: store.route) { _, _ in
            isPinnedToBottom = true
            underfillPageAttempts = 0
            didMarkFirstTextPaint = false
        }
        .overlay(alignment: .bottom) {
            if !isPinnedToBottom {
                Button {
                    isPinnedToBottom = true
                    pinRequest &+= 1
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

    private func handleScrollMetrics(_ metrics: ConversationScrollMetrics) {
        if isPinnedToBottom != metrics.isNearBottom { isPinnedToBottom = metrics.isNearBottom }
        guard metrics.shouldRequestEarlierHistory else { return }
        if metrics.isUnderfilled {
            guard underfillPageAttempts < 2 else { return }
            if requestEarlierMessages() { underfillPageAttempts += 1 }
        } else {
            requestEarlierMessages()
        }
    }

    @discardableResult
    private func requestEarlierMessages() -> Bool {
        guard store.hasEarlierMessages, !store.isLoadingEarlierMessages else { return false }
        store.loadEarlierMessages()
        return true
    }
}

private struct DelayedConversationLoadingView: View {
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.clear
            if isVisible {
                VStack(spacing: PiTheme.space8) {
                    ProgressView().controlSize(.small)
                    Text("Opening conversation…").font(PiFont.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            isVisible = true
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
    let retryEnabled: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: PiIcon.small))
                .foregroundStyle(Color.piRed)
            Text(text).font(PiFont.caption).lineLimit(2)
            Spacer()
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!retryEnabled)
            .accessibilityHint("Continue the failed turn without repeating completed work")
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.vertical, PiTheme.space8)
        .background(Color.piRed.opacity(0.08), in: RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous))
    }
}
