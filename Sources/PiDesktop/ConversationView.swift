import AppKit
import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var store: AppStore
    @State private var renamePresented = false
    @State private var renameValue = ""

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
                    ExtensionWidgetStrip(placement: .aboveEditor)
                    ComposerView(
                        text: $store.draft,
                        attachments: $store.attachments,
                        isStreaming: store.isSelectedRuntime && store.runtimeState.isStreaming,
                        onSend: { store.submitDraft(delivery: .automatic) },
                        onSteer: { store.submitDraft(delivery: .steer) },
                        onFollowUp: { store.submitDraft(delivery: .followUp) },
                        onAbort: store.abort
                    )
                    ExtensionWidgetStrip(placement: .belowEditor)
                }
                .frame(maxWidth: PiTheme.composerMaxWidth)
                .padding(.horizontal, PiTheme.space20)
                .padding(.top, PiTheme.space8)
                .padding(.bottom, PiTheme.space16)
                .frame(maxWidth: .infinity)
                .background(Color.piTranscript)
            }
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: PiTheme.space6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(store.selectedSession?.displayName ?? "Conversation")
                    .font(PiFont.rowEmphasis)
                    .lineLimit(1)
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
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
            }
            .help(store.selectedSession?.cwd.path ?? "Conversation actions")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation(.easeOut(duration: 0.16)) { store.inspectorVisible.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12, weight: .regular))
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
            ContentUnavailableView {
                Label("Couldn’t open this session", systemImage: "doc.badge.exclamationmark")
            } description: { Text(error) } actions: { Button("Try Again", action: store.retryConversationLoad) }
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
            MessageScrollView(messages: store.messages, streaming: store.streamingMessage)
        }
    }
}

private struct MessageScrollView: View {
    @EnvironmentObject private var store: AppStore
    let messages: [ChatMessage]
    let streaming: ChatMessage?
    @State private var scrollTask: Task<Void, Never>?
    /// Tracked by a bottom sentinel appearing/disappearing, which works on macOS 14 without
    /// scroll-position APIs. Auto-scroll only happens while the user is pinned at the bottom.
    @State private var isPinnedToBottom = true
    private let bottomID = "conversation-bottom"

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                // A single small gap between entries keeps consecutive tool rows on an even
                // rhythm; paragraphs get their breathing room from the block renderer.
                LazyVStack(alignment: .leading, spacing: PiTheme.space10) {
                    ForEach(messages) { message in
                        MessageView(message: message, isStreaming: false, onImage: store.showImage)
                            .id(message.id)
                    }
                    if let streaming {
                        MessageView(message: streaming, isStreaming: true, onImage: store.showImage)
                            .id("streaming-\(streaming.id)")
                    }
                    Color.clear
                        .frame(height: PiTheme.space8)
                        .id(bottomID)
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.horizontal, PiTheme.space20)
                .padding(.top, PiTheme.space24)
                .padding(.bottom, PiTheme.space20)
                .frame(maxWidth: PiTheme.transcriptMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                isPinnedToBottom = true
                reader.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                guard isPinnedToBottom else { return }
                withAnimation(.easeOut(duration: 0.18)) { reader.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: streaming?.textContent.count ?? 0) { _, _ in
                guard isPinnedToBottom else { return }
                scrollTask?.cancel()
                scrollTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard !Task.isCancelled, isPinnedToBottom else { return }
                    reader.scrollTo(bottomID, anchor: .bottom)
                }
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

private struct InlineError: View {
    let text: String
    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.piRed)
            Text(text).font(PiFont.caption).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.vertical, PiTheme.space8)
        .background(Color.piRed.opacity(0.08), in: RoundedRectangle(cornerRadius: PiTheme.radiusMedium, style: .continuous))
    }
}
