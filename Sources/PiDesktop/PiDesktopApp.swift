import Foundation
import PiDeskKit
import SwiftUI

@main
struct PiDesktopApp: App {
    /// The probe factory is supplied only here for the explicit refresh command.
    @StateObject private var store = AppStore(
        connectivityMonitor: ConnectivityMonitor(),
        // The status probe reads Pi's extension host, which is a Pi-only concept, so it always
        // attaches to Pi regardless of which agent the current conversation uses.
        probeRuntimeFactory: { AgentRuntimeClient(adapter: PiProtocolAdapter(), additionalArguments: ["--no-session"]) },
        sleepPrevention: SleepPreventionController.liveHandler()
    )
    // Owns the in-process control service lifecycle. Kept on the app delegate (not a second
    // @StateObject) so launch/quit and the Settings scene share the exact same instance.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // LaunchServices starts GUI apps with cwd="/". Keep the host process on a readable,
        // ordinary directory before any SwiftUI task launches Pi or a Git subprocess.
        _ = FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var body: some Scene {
        WindowGroup("Pi Desktop") {
            RootView()
                .environmentObject(store)
                // Also governs any plain Text/Button labels that do not choose a semantic role.
                .font(PiFont.body)
        }
        .defaultSize(width: 1_280, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.openNewChat() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Virtual Folder…") { store.newVirtualFolderRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandMenu("Conversation") {
                Button("Quick Switch…") { store.quickSwitchPresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") {
                    Task { await store.refreshSessions(); await store.refreshScheduledThreads() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button(archiveTitle) { store.toggleArchiveSelected() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(store.selectedSession == nil)
                Button("Rename…") { store.renameRequested = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.selectedSession == nil)
                Button("Mark as Unread") { store.markSelectedUnread() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .disabled(store.selectedSession == nil)
                Divider()
                Button("Stop Thread", action: store.abort)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.canStopCurrentThread)
                Button("Compact Context", action: store.compact)
                    .disabled(!store.canCompact)
                Divider()
                Button("Automations") { store.schedulesPresented = true }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Toggle Environment") { store.inspectorVisible.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Agent") {
                Menu(store.activeCapabilities.modeControlTitle) {
                    ForEach(store.availableModes) { mode in
                        Button(mode.title) { store.setAgentMode(mode.id) }
                    }
                }
                .disabled(store.availableModes.isEmpty)
                // Fast priority, limits, and extension statuses all come from Pi extensions.
                Group {
                    Button("Toggle Fast Priority") { store.toggleFastPriority() }
                    Button("Show Limits…") { store.showLimits() }
                    Divider()
                    Button("Refresh Extension Statuses") { store.refreshExtensionStatuses() }
                        .disabled(store.isProbingStatuses)
                }
                .disabled(!store.activeCapabilities.supportsActivityExtension)
            }
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(store)
                .font(PiFont.body)
        } label: {
            MenuBarLabelView().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            DaemonSettingsView()
                .environmentObject(appDelegate.daemonSupervisor)
                .font(PiFont.body)
        }
    }

    private var archiveTitle: String {
        store.selectedSession?.isArchived == true ? "Unarchive Conversation" : "Archive Conversation"
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var collapseState = SidebarAutoCollapseState()
    @State private var expectedPolicyVisibility: NavigationSplitViewVisibility?
    @State private var currentWidth: CGFloat = PiTheme.windowMinimumWidth
    @State private var newVirtualFolderName = ""

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: PiTheme.sidebarMinWidth,
                    ideal: PiTheme.sidebarIdealWidth,
                    max: PiTheme.sidebarMaxWidth
                )
                .toolbar(removing: .sidebarToggle)
                .piPlainToolbar { sidebarToggleItem }
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBarView()
            }
            .frame(minWidth: 500)
        }
        .navigationSplitViewStyle(.balanced)
        // Extension `setTitle` drives the real window title, not just an inspector field.
        .navigationTitle(store.windowTitle)
        .onAppear { updateSidebar(for: geometry.size.width) }
        .onChange(of: geometry.size.width) { _, width in updateSidebar(for: width) }
        .onChange(of: columnVisibility) { _, visibility in
            if expectedPolicyVisibility == visibility {
                expectedPolicyVisibility = nil
            } else {
                collapseState.userChangedVisibility(width: currentWidth, threshold: PiTheme.sidebarAutoCollapseWidth)
            }
        }
        .task { store.bootstrap() }
        .alert("New virtual folder", isPresented: $store.newVirtualFolderRequested) {
            TextField("Folder name", text: $newVirtualFolderName)
            Button("Cancel", role: .cancel) { newVirtualFolderName = "" }
            Button("Create") {
                _ = store.createVirtualFolder(named: newVirtualFolderName)
                newVirtualFolderName = ""
            }
        } message: {
            Text("Virtual folders organize conversations without changing files on disk.")
        }
        .sheet(item: sheetDialog) { request in
            ExtensionDialogView(request: request).environmentObject(store)
        }
        .overlay {
            if store.quickSwitchPresented {
                QuickSwitchOverlay()
            }
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Group {
                    if toast.sessionPath == nil {
                        ToastView(toast: toast)
                    } else {
                        Button { store.openToast(toast) } label: { ToastView(toast: toast) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Open conversation")
                    }
                }
                // Clears the unified toolbar so the toast is never hidden behind it.
                .padding(.top, PiTheme.space32 + PiTheme.space24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        // Last root overlay on purpose: the viewer covers quick switch and toasts.
        .overlay {
            if let viewed = store.viewedImage {
                ImageViewerView(selection: viewed) { store.viewedImage = nil }
                    .id(viewed.id)
            }
        }
        }
        .frame(minWidth: PiTheme.windowMinimumWidth, minHeight: PiTheme.windowMinimumHeight)
        // Kept on the outer container so it does not compete with the virtual-folder alert.
        .alert(item: archiveConfirmationBinding) { confirmation in
            Alert(
                title: Text("Archive conversation?"),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.actionTitle)) {
                    Task { await store.confirmArchive(confirmation) }
                },
                secondaryButton: .cancel { store.cancelArchiveConfirmation() }
            )
        }
    }

    private var archiveConfirmationBinding: Binding<ArchiveConfirmation?> {
        Binding(
            get: { store.archiveConfirmation },
            set: { if $0 == nil { store.cancelArchiveConfirmation() } }
        )
    }

    /// Scoped to the sidebar column so it renders at that column's trailing edge.
    /// Setting `columnVisibility` without arming `expectedPolicyVisibility` is deliberate: the
    /// `onChange` above must read this as a user override, exactly as the automatic toggle did.
    @ToolbarContentBuilder
    private var sidebarToggleItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Image(systemName: "sidebar.left").font(.system(size: PiIcon.small, weight: .regular))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Toggle Sidebar")
            .help("Show or hide the sidebar")
        }
    }

    /// An `ask_user_question` request keeps its place in the store — it still owns the response
    /// ID, the FIFO slot, and the timeout — but renders inline at its transcript row, so only
    /// generic extension dialogs ever reach the sheet.
    private var sheetDialog: Binding<ExtensionDialogRequest?> {
        Binding(
            get: { store.activeDialog.flatMap { store.questionnaireQuestion(for: $0) == nil ? $0 : nil } },
            set: { _ in }
        )
    }

    /// Automations is a page, not an `AppRoute`: `store.route` (and with it the selected
    /// conversation and its parked draft) survives a visit here untouched.
    @ViewBuilder
    private var detail: some View {
        if store.schedulesPresented {
            SchedulesView(service: store.scheduleService)
        } else {
            switch store.route {
            case .newChat: NewChatView()
            case .session:
                if store.selectedSession != nil { ConversationView() }
                else {
                    PiUnavailableView("Conversation not found", systemImage: "bubble.left")
                        .background(Color.piTranscript)
                }
            }
        }
    }

    private func updateSidebar(for width: CGFloat) {
        currentWidth = width
        let visible = columnVisibility != .detailOnly
        guard let action = collapseState.action(
            width: width,
            sidebarVisible: visible,
            threshold: PiTheme.sidebarAutoCollapseWidth
        ) else { return }
        let target: NavigationSplitViewVisibility = action == .collapse ? .detailOnly : .all
        expectedPolicyVisibility = target
        columnVisibility = target
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
