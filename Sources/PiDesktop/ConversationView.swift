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
    private var revision = -1
    private var isRunning = false
    private var mode: TranscriptPresentationMode = .detailed
    private var cached: [TranscriptItem] = []
    private(set) var buildCount = 0

    func items(
        revision: Int,
        messages: [ChatMessage],
        streaming: ChatMessage?,
        isRunning: Bool,
        mode: TranscriptPresentationMode = .detailed
    ) -> [TranscriptItem] {
        guard self.revision != revision || self.isRunning != isRunning || self.mode != mode else { return cached }
        self.revision = revision
        self.isRunning = isRunning
        self.mode = mode
        let projected = TranscriptPresenter.items(
            messages: messages,
            streaming: streaming,
            isRunning: isRunning,
            mode: mode
        )
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
                    InspectorView(activities: store.runtimeActivities)
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
                        isStreaming: store.isSelectedRuntime && store.runtimeState.isBusy,
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
        if store.isSelectedRuntime, store.runtimeState.isBusy { return true }
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
        } else if store.messages.isEmpty && store.streamingMessage == nil && !store.isBrowsingEarlierHistory {
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
                stream: store.transcriptStream,
                isRunning: conversationIsRunning,
                onEditLastMessage: store.isBrowsingEarlierHistory ? nil : {
                    store.beginEditingLastMessage()
                    composerFocusTick += 1
                }
            )
            .id(store.route)
        }
    }
}

struct MessageScrollView: View {
    @EnvironmentObject private var store: AppStore
    let messages: [ChatMessage]
    @ObservedObject var stream: TranscriptStreamModel
    /// True for a turn in flight here or in a terminal, so the live turn stays open either way.
    let isRunning: Bool
    /// Wired only to the conversation's single most recent user message; every earlier turn's
    /// bubble never receives this at all (see the `message.id == lastUserMessageID` check below).
    var onEditLastMessage: (() -> Void)?
    @State private var isPinnedToBottom = true
    /// Bumped by the coordinator's paint heal; reading it in the tree below guarantees one
    /// SwiftUI render pass against the viewport actually on screen after an open settles.
    @State private var healTick = 0
    @State private var scrollBridge = ConversationScrollBridge()
    @State private var pageReplacementArmed = false
    @State private var pageReplacementGeneration = 0
    @State private var didMarkFirstTextPaint = false
    @State private var projectionCache = TranscriptProjectionCache()

    private var transcriptItems: [TranscriptItem] {
        projectionCache.items(
            revision: store.transcriptRevision,
            messages: messages,
            streaming: stream.message,
            isRunning: isRunning,
            mode: store.isBrowsingEarlierHistory ? .focusedHistory : .detailed
        )
    }

    private var lastUserMessageID: String? { messages.last(where: { $0.role == .user })?.id }

    /// Changes when the inline questionnaire appears or moves to another buffered question.
    private var questionnaireKey: String? {
        store.activeQuestionnaireSession.map { "\($0.toolCallID):\($0.currentIndex)" }
    }

    var body: some View {
        let items = transcriptItems
        ScrollView {
            // A single small gap between entries keeps consecutive tool rows on an even
            // rhythm; paragraphs get their breathing room from the block renderer.
            LazyVStack(alignment: .leading, spacing: PiTheme.transcriptEntrySpacing) {
                if !store.isBrowsingEarlierHistory {
                    if store.isLoadingEarlierMessages {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Loading older conversation")
                    } else if store.hasEarlierMessages {
                        Button("Load older conversation") { requestEarlierMessages() }
                            .buttonStyle(.plain)
                            .font(PiFont.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else if store.conversationHistoryLimitReached {
                        Text("Earlier history could not be read safely.")
                            .font(PiFont.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                } else if store.conversationHistoryLimitReached {
                    Text("Earlier history could not be read safely.")
                        .font(PiFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                } else if !store.hasEarlierMessages {
                    Text("Beginning of conversation")
                        .font(PiFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }

                if items.isEmpty, store.isBrowsingEarlierHistory {
                    Text("No user or assistant messages in this section.")
                        .font(PiFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PiTheme.space20)
                }

                ForEach(items) { item in
                    Group {
                        switch item {
                        case let .message(message, isStreaming):
                            MessageView(
                                message: message,
                                isStreaming: isStreaming,
                                onImage: store.showImage,
                                showsActions: true,
                                onEdit: message.role == .user && message.id == lastUserMessageID ? onEditLastMessage : nil
                            )
                            .equatable()
                            .padding(.top, message.role == .user ? PiTheme.transcriptTurnSpacing : 0)
                        case let .work(block):
                            TranscriptWorkView(
                                block: block,
                                onImage: store.showImage,
                                questionnaireKey: questionnaireKey
                            )
                            .equatable()
                            .padding(.top, PiTheme.space6)
                        }
                    }
                    .id(item.id)
                    .onAppear {
                        guard !didMarkFirstTextPaint else { return }
                        didMarkFirstTextPaint = true
                        ConversationPerformance.mark(
                            "Conversation first text paint",
                            path: store.selectedSession?.fileURL.path ?? "new-chat",
                            count: items.count
                        )
                    }
                }
            }
            .padding(.top, PiTheme.space24)
            .padding(.bottom, PiTheme.space8)
            .frame(maxWidth: PiTheme.transcriptMaxWidth, alignment: .leading)
            .padding(.horizontal, PiTheme.space20)
            .frame(maxWidth: .infinity)
            .background(
                ConversationScrollObserver(
                    bridge: scrollBridge,
                    onChange: { metrics in handleScrollMetrics(metrics) },
                    onHeal: { healTick &+= 1 }
                )
            )
            .overlay(alignment: .topLeading) { Color.clear.frame(width: 0, height: 0).id(healTick) }
        }
        // The native anchor positions the first frame at the bottom; from then on the AppKit
        // coordinator keeps the viewport pinned through streaming growth, image decodes, and
        // lazily settling rows — synchronously, inside each layout pass.
        .defaultScrollAnchor(.bottom)
        // A hard top edge on purpose: the soft (progressive-blur) scroll edge effect computes
        // its extent from scroll state that programmatic positioning (bottom anchor plus the
        // coordinator's clip-origin corrections) leaves stale, ballooning a ghost "blur
        // overlay" over the top of freshly opened conversations until a real scroll recomputes
        // it. The toolbar background is opaque here anyway, so the soft fade bought nothing.
        .piHardTopScrollEdge()
        .scrollDismissesKeyboard(.interactively)
        .onAppear { store.consumeInitialScrollTarget() }
        .onChange(of: store.transcriptRevision) { _, _ in
            guard pageReplacementArmed else { return }
            scrollBridge.applyPageReplacement()
            releasePageReplacementSoon()
        }
        .onChange(of: store.isLoadingEarlierMessages) { wasLoading, isLoading in
            if pageReplacementArmed, wasLoading, !isLoading { releasePageReplacementSoon() }
        }
        .onChange(of: store.isLoadingNewerMessages) { wasLoading, isLoading in
            if pageReplacementArmed, wasLoading, !isLoading { releasePageReplacementSoon() }
        }
        .onChange(of: store.latestScrollRequest) { _, _ in
            pageReplacementArmed = false
            pageReplacementGeneration &+= 1
            scrollBridge.disarmPageReplacement()
            isPinnedToBottom = true
            scrollBridge.pinToBottom()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.isBrowsingEarlierHistory { historyNavigationBar }
        }
        .overlay(alignment: .bottom) {
            if !store.isBrowsingEarlierHistory, !isPinnedToBottom {
                Button {
                    isPinnedToBottom = true
                    scrollBridge.pinToBottom()
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
    }

    private var historyNavigationBar: some View {
        HStack(spacing: PiTheme.space8) {
            Text("History · work omitted")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Conversation history. Work details are omitted.")
            Divider()
                .frame(height: PiTheme.space16)
                .accessibilityHidden(true)
            historyButton(
                "Older", systemImage: "chevron.up",
                isLoading: store.isLoadingEarlierMessages,
                disabled: !store.hasEarlierMessages || store.isLoadingEarlierMessages || store.isLoadingNewerMessages,
                hint: "Show the preceding conversation page",
                action: requestEarlierMessages
            )
            historyButton(
                "Newer", systemImage: "chevron.down",
                isLoading: store.isLoadingNewerMessages,
                disabled: !store.hasNewerMessages || store.isLoadingEarlierMessages || store.isLoadingNewerMessages,
                hint: "Show the following conversation page",
                action: requestNewerMessages
            )
            Button {
                store.jumpToLatestMessages()
            } label: {
                Label("Latest", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Return to the live conversation and its newest message")
            .help("Return to the live conversation")
        }
        .font(PiFont.caption)
        .padding(.horizontal, PiTheme.space10)
        .padding(.vertical, PiTheme.space6)
        .background(Color.piTranscript, in: Capsule())
        .overlay { Capsule().stroke(Color.piHairline, lineWidth: PiTheme.hairline) }
        .padding(.bottom, PiTheme.space10)
    }

    private func historyButton(
        _ title: String,
        systemImage: String,
        isLoading: Bool,
        disabled: Bool,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .opacity(isLoading ? 0 : 1)
                .overlay {
                    if isLoading {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(isLoading ? "Loading" : "")
        .accessibilityHint(hint)
        .help(hint)
    }

    private func requestEarlierMessages() {
        guard store.hasEarlierMessages, !store.isLoadingEarlierMessages, !store.isLoadingNewerMessages else { return }
        armPageReplacement(.bottom)
        if !store.loadEarlierMessages() { cancelPageReplacement() }
    }

    private func requestNewerMessages() {
        guard store.hasNewerMessages, !store.isLoadingEarlierMessages, !store.isLoadingNewerMessages else { return }
        armPageReplacement(.top)
        if !store.loadNewerMessages() { cancelPageReplacement() }
    }

    private func armPageReplacement(_ edge: ConversationPageEdge) {
        pageReplacementGeneration &+= 1
        pageReplacementArmed = true
        scrollBridge.armPageReplacement(edge)
    }

    private func cancelPageReplacement() {
        pageReplacementGeneration &+= 1
        pageReplacementArmed = false
        scrollBridge.disarmPageReplacement()
    }

    private func releasePageReplacementSoon() {
        guard pageReplacementArmed else { return }
        let generation = pageReplacementGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard pageReplacementArmed, pageReplacementGeneration == generation,
                  !store.isLoadingEarlierMessages, !store.isLoadingNewerMessages else { return }
            cancelPageReplacement()
        }
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
