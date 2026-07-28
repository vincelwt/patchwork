import AppKit
import SwiftUI

/// The toolbar title's own bound, distinct from the transcript/composer measure — it shares
/// a toolbar with window traffic lights and the inspector toggle, so it needs a cap well short of
/// `PiTheme.transcriptMaxWidth`.
extension PiTheme {
    static let conversationTitleMaxWidth: CGFloat = 280
}

@MainActor
final class ConversationScrollAnchorStore {
    private var anchors: [String: String] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 32) { self.limit = limit }

    func anchor(for path: String) -> String? { anchors[path] }

    func remember(_ anchor: String, for path: String) {
        guard anchors[path] != anchor else { return }
        anchors[path] = anchor
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > limit { anchors.removeValue(forKey: order.removeFirst()) }
    }
}

@MainActor
final class TranscriptProjectionCache {
    private var revision = -1
    private var isRunning = false
    private var cached: [TranscriptItem] = []
    private(set) var buildCount = 0

    func items(
        revision: Int,
        messages: [ChatMessage],
        streaming: ChatMessage?,
        isRunning: Bool
    ) -> [TranscriptItem] {
        guard self.revision != revision || self.isRunning != isRunning else { return cached }
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
    /// In-memory only: recent routes reopen at the row the user was reading. The transcript page
    /// cache carries the matching rows; both structures stay bounded.
    @State private var scrollAnchors = ConversationScrollAnchorStore()

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

    /// Working, whether this app's runtime drives the turn or a terminal does.
    private var conversationIsRunning: Bool {
        if store.isSelectedRuntime, store.runtimeState.isStreaming { return true }
        guard let session = store.selectedSession else { return false }
        return store.isRunning(session)
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
            let path = store.selectedSession?.fileURL.standardizedFileURL.path ?? "new-chat"
            MessageScrollView(
                messages: store.messages,
                streaming: store.streamingMessage,
                isRunning: conversationIsRunning,
                transcriptRevision: store.transcriptRevision,
                restoredAnchorID: scrollAnchors.anchor(for: path),
                unseenMessageID: store.initialScrollTargetMessageID,
                onVisibleAnchorChange: { rememberScrollAnchor($0, for: path) },
                onEditLastMessage: {
                    store.beginEditingLastMessage()
                    composerFocusTick += 1
                }
            )
            .id(store.route)
        }
    }

    private func rememberScrollAnchor(_ anchor: String, for path: String) {
        scrollAnchors.remember(anchor, for: path)
    }
}

struct MessageScrollView: View {
    @EnvironmentObject private var store: AppStore
    let messages: [ChatMessage]
    let streaming: ChatMessage?
    /// True for a turn in flight here or in a terminal, so the live turn stays open either way.
    let isRunning: Bool
    let transcriptRevision: Int
    let restoredAnchorID: String?
    let unseenMessageID: String?
    let onVisibleAnchorChange: (String) -> Void
    /// Wired only to the conversation's single most recent user message; every earlier turn's
    /// bubble never receives this at all (see the `message.id == lastUserMessageID` check below).
    var onEditLastMessage: (() -> Void)?
    @State private var scrollTask: Task<Void, Never>?
    @State private var isPinnedToBottom = true
    @State private var scrollBridge = ConversationScrollBridge()
    @State private var prependPending = false
    @State private var didRestoreInitialAnchor = false
    @State private var autoPageAttempts = 0
    @State private var underfillPageAttempts = 0
    @State private var didMarkFirstTextPaint = false
    @State private var initialDefaultScrollAnchor: UnitPoint?
    @State private var projectionCache = TranscriptProjectionCache()
    private let bottomID = "conversation-bottom"
    private let coordinateSpaceName = "conversation-scroll"

    static func unseenTargetID(_ sourceID: String?, in items: [TranscriptItem]) -> String? {
        guard let sourceID else { return nil }
        return items.first(where: { $0.sourceMessageID == sourceID })?.id
    }

    private func requestedDefaultScrollAnchor(items: [TranscriptItem]) -> UnitPoint {
        if unseenMessageID != nil,
           store.isConversationLoading || Self.unseenTargetID(unseenMessageID, in: items) != nil { return .top }
        if let restoredAnchorID, restoredAnchorID != bottomID,
           items.contains(where: { $0.id == restoredAnchorID }) { return .top }
        return .bottom
    }

    private var transcriptItems: [TranscriptItem] {
        projectionCache.items(
            revision: transcriptRevision,
            messages: messages,
            streaming: streaming,
            isRunning: isRunning
        )
    }

    private var lastUserMessageID: String? { messages.last(where: { $0.role == .user })?.id }

    /// Changes when the inline questionnaire appears or moves to another buffered question.
    private var questionnaireKey: String? {
        store.activeQuestionnaireSession.map { "\($0.toolCallID):\($0.currentIndex)" }
    }

    /// An image can arrive inside an existing work block without changing the transcript count.
    private func prominentImageIDs(in items: [TranscriptItem]) -> [String] {
        items.flatMap { item -> [String] in
            guard case let .work(block) = item else { return [] }
            return block.prominentSteps.flatMap { $0.result?.images.map(\.id) ?? [] }
        }
    }

    var body: some View {
        let items = transcriptItems
        let imageIDs = prominentImageIDs(in: items)
        ScrollViewReader { reader in
            ScrollView {
                // A single small gap between entries keeps consecutive tool rows on an even
                // rhythm; paragraphs get their breathing room from the block renderer.
                LazyVStack(alignment: .leading, spacing: PiTheme.transcriptEntrySpacing) {
                    if store.isLoadingEarlierMessages {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Loading earlier messages")
                    } else if store.hasEarlierMessages {
                        Button("Load earlier messages") { requestEarlierMessages() }
                            .buttonStyle(.plain)
                            .font(PiFont.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else if store.conversationHistoryLimitReached {
                        Text("Earlier history is outside this bounded window.")
                            .font(PiFont.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
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
                            case let .compaction(note):
                                CompactionRowView(note: note)
                                    .padding(.vertical, PiTheme.space6)
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TranscriptRowFramesKey.self,
                                    value: [item.id: proxy.frame(in: .named(coordinateSpaceName))]
                                )
                            }
                        )
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
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.top, PiTheme.space24)
                .padding(.bottom, PiTheme.space8)
                .frame(maxWidth: PiTheme.transcriptMaxWidth, alignment: .leading)
                .padding(.horizontal, PiTheme.space20)
                .frame(maxWidth: .infinity)
                .background(
                    ConversationScrollObserver(bridge: scrollBridge) { metrics in
                        handleScrollMetrics(metrics)
                    }
                )
            }
            // Native initial anchoring prevents a top-frame flash before any scrollTo callback.
            .defaultScrollAnchor(initialDefaultScrollAnchor ?? requestedDefaultScrollAnchor(items: items))
            .coordinateSpace(name: coordinateSpaceName)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                if initialDefaultScrollAnchor == nil {
                    initialDefaultScrollAnchor = requestedDefaultScrollAnchor(items: items)
                }
                restoreInitialAnchorIfPossible(items: items, reader: reader)
            }
            .onChange(of: messages.first?.id) { _, _ in
                restoreInitialAnchorIfPossible(items: items, reader: reader)
                if didRestoreInitialAnchor, isPinnedToBottom, !prependPending { scheduleBottomScroll(reader) }
            }
            .onChange(of: store.isConversationLoading) { wasLoading, isLoading in
                if wasLoading, !isLoading { restoreInitialAnchorIfPossible(items: items, reader: reader) }
            }
            .onChange(of: messages.last?.id) { _, _ in scheduleBottomScroll(reader) }
            .onChange(of: streaming?.textContent.count ?? 0) { _, _ in scheduleBottomScroll(reader) }
            .onChange(of: imageIDs) { _, _ in scheduleBottomScroll(reader) }
            // Only when already pinned: a question appearing must never yank a user reading history.
            .onChange(of: questionnaireKey) { _, _ in scheduleBottomScroll(reader) }
            .onChange(of: store.isLoadingEarlierMessages) { wasLoading, isLoading in
                guard wasLoading, !isLoading else { return }
                if prependPending {
                    scrollBridge.restoreAfterPrepend()
                    prependPending = false
                } else {
                    restoreInitialAnchorIfPossible(items: items, reader: reader)
                }
            }
            .onPreferenceChange(TranscriptRowFramesKey.self) { frames in
                guard !isPinnedToBottom,
                      let top = frames.filter({ $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY }) else { return }
                onVisibleAnchorChange(top.key)
            }
            .onDisappear { scrollTask?.cancel() }
            .overlay(alignment: .bottom) {
                if !isPinnedToBottom {
                    Button {
                        scrollTask?.cancel()
                        isPinnedToBottom = true
                        onVisibleAnchorChange(bottomID)
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

    private func handleScrollMetrics(_ metrics: ConversationScrollMetrics) {
        if isPinnedToBottom != metrics.isNearBottom { isPinnedToBottom = metrics.isNearBottom }
        if metrics.isNearBottom { onVisibleAnchorChange(bottomID) }
        guard didRestoreInitialAnchor, metrics.shouldRequestEarlierHistory else { return }
        if metrics.isUnderfilled {
            guard underfillPageAttempts < 2 else { return }
            if requestEarlierMessages() { underfillPageAttempts += 1 }
        } else {
            requestEarlierMessages()
        }
    }

    @discardableResult
    private func requestEarlierMessages() -> Bool {
        guard store.hasEarlierMessages, !store.isLoadingEarlierMessages, !prependPending else { return false }
        prependPending = true
        scrollBridge.captureBeforePrepend()
        store.loadEarlierMessages()
        return true
    }

    private func restoreInitialAnchorIfPossible(items: [TranscriptItem], reader: ScrollViewProxy) {
        guard !didRestoreInitialAnchor else { return }
        let target: String?
        if unseenMessageID != nil {
            if let unseenTarget = Self.unseenTargetID(unseenMessageID, in: items) {
                target = unseenTarget
            } else if store.isConversationLoading {
                return
            } else {
                // Empty/error completions can fold into a work row and have no standalone target.
                target = bottomID
            }
        } else if let restoredAnchorID {
            if restoredAnchorID == bottomID || items.contains(where: { $0.id == restoredAnchorID }) {
                target = restoredAnchorID
            } else if store.isLoadingEarlierMessages {
                return
            } else if store.hasEarlierMessages, autoPageAttempts < 2 {
                autoPageAttempts += 1
                store.loadEarlierMessages()
                return
            } else {
                target = bottomID
            }
        } else {
            target = bottomID
        }
        didRestoreInitialAnchor = true
        guard let target else { return }
        DispatchQueue.main.async {
            reader.scrollTo(target, anchor: target == bottomID ? .bottom : .top)
            if unseenMessageID != nil { store.consumeInitialScrollTarget() }
            ConversationPerformance.mark("Conversation anchor restore", path: store.selectedSession?.fileURL.path ?? "new-chat")
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

private struct TranscriptRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
