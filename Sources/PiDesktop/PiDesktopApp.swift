import SwiftUI

@main
struct PiDesktopApp: App {
    /// The probe factory is supplied only here: `AppStore` never spawns a Pi process in tests.
    @StateObject private var store = AppStore(
        probeRuntimeFactory: { PiRPCClient(additionalArguments: ["--no-session"]) }
    )

    var body: some Scene {
        WindowGroup("Pi Desktop") {
            RootView().environmentObject(store)
        }
        .defaultSize(width: 1_280, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.openNewChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Conversation") {
                Button("Quick Switch…") { store.quickSwitchPresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") { Task { await store.refreshSessions() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button(archiveTitle) { store.toggleArchiveSelected() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(store.selectedSession == nil)
                Button("Rename…") { store.renameRequested = true }
                    .disabled(store.selectedSession == nil)
                Divider()
                Button("Stop Pi", action: store.abort)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.runtimeState.isStreaming)
                Button("Compact Context", action: store.compact)
                    .disabled(!store.isSelectedRuntime || store.runtimeState.isStreaming)
                Divider()
                Button("Toggle Environment") { store.inspectorVisible.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Pi") {
                Menu("Mode") {
                    ForEach(PiMode.allCases) { mode in
                        Button(mode.label) { store.setMode(mode) }
                    }
                }
                Button("Toggle Fast Priority") { store.toggleFastPriority() }
                Button("Show Limits…") { store.showLimits() }
                Divider()
                Button("Refresh Extension Statuses") { store.refreshExtensionStatuses() }
                    .disabled(store.isProbingStatuses)
            }
        }

        MenuBarExtra {
            MenuBarContentView().environmentObject(store)
        } label: {
            MenuBarLabelView().environmentObject(store)
        }
    }

    private var archiveTitle: String {
        store.selectedSession?.isArchived == true ? "Unarchive Conversation" : "Archive Conversation"
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: PiTheme.sidebarMinWidth,
                    ideal: PiTheme.sidebarIdealWidth,
                    max: PiTheme.sidebarMaxWidth
                )
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.route {
                    case .newChat: NewChatView()
                    case .session:
                        if store.selectedSession != nil { ConversationView() }
                        else {
                            ContentUnavailableView("Conversation not found", systemImage: "bubble.left")
                                .background(Color.piTranscript)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBarView()
            }
            .frame(minWidth: 640)
        }
        .navigationSplitViewStyle(.balanced)
        // Extension `setTitle` drives the real window title, not just an inspector field.
        .navigationTitle(store.windowTitle)
        .frame(minWidth: 940, minHeight: 620)
        .task { store.bootstrap() }
        .sheet(item: $store.activeDialog) { request in
            ExtensionDialogView(request: request).environmentObject(store)
        }
        .sheet(item: $store.viewedImage) { item in ImageViewerView(payload: item.image) }
        .overlay {
            if store.quickSwitchPresented {
                QuickSwitchOverlay()
            }
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    // Clears the unified toolbar so the toast is never hidden behind it.
                    .padding(.top, PiTheme.space32 + PiTheme.space24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
    }
}

/// A dimmed scrim plus the palette. Presented as an overlay rather than a sheet so ⌘K feels
/// instant and Esc dismisses without an animation round trip.
private struct QuickSwitchOverlay: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.14)
                .ignoresSafeArea()
                .onTapGesture { store.quickSwitchPresented = false }
            QuickSwitcherView(isPresented: $store.quickSwitchPresented)
                .padding(.top, 88)
        }
        .transition(.opacity)
        .zIndex(20)
    }
}
