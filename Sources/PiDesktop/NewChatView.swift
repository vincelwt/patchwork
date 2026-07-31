import SwiftUI

struct NewChatView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: PiTheme.space6) {
            if store.messages.isEmpty {
                Spacer()
                Text("Start a conversation")
                    .font(PiFont.displayTitle)
                Text(emptyStateDetail)
                    .font(PiFont.body)
                    .foregroundStyle(.secondary)
                AgentPicker()
                    .padding(.top, PiTheme.space8)
                Spacer()
            } else {
                MessageScrollView(
                    messages: store.messages,
                    stream: store.transcriptStream,
                    isRunning: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.piTranscript)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: PiTheme.space8) {
                folderContext
                ExtensionWidgetStrip(placement: .aboveEditor)
                ComposerView(
                    model: store.composer,
                    isStreaming: false,
                    placeholder: "Describe a task for \(store.newChatAgent.displayName)…",
                    autofocus: true,
                    onSend: { store.submitDraft() }
                )
                ExtensionWidgetStrip(placement: .belowEditor)
            }
            .frame(maxWidth: PiTheme.composerMaxWidth)
            .padding(.horizontal, PiTheme.space20)
            .padding(.bottom, PiTheme.space16)
            .frame(maxWidth: .infinity)
            .background(Color.piTranscript)
        }
        .contentShape(Rectangle())
        .onDrop(of: ImageImportService.dropTypes, isTargeted: nil) { providers in
            let route = store.route
            let folder = store.selectedFolder?.standardizedFileURL
            return ImageImportService.loadDroppedAttachments(from: providers) { images in
                guard store.route == route, store.selectedFolder?.standardizedFileURL == folder else { return }
                store.addAttachments(images)
            }
        }
    }

    private var isGlobal: Bool {
        store.selectedFolder.map(WorkspaceOrganization.isGlobalWorkingDirectory) ?? true
    }

    /// Says which agent will run when there is a choice to make, and stays out of the way when
    /// there is only one installed.
    private var emptyStateDetail: String {
        store.installedAgents.count > 1
            ? "Pick an agent, then start globally or choose a project folder."
            : "Start globally, or choose a project folder."
    }

    private var workingFolders: [URL] { store.sidebarFolders }

    private var folderContext: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: isGlobal ? "globe" : "folder")
                .font(.system(size: PiIcon.small))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(isGlobal ? "Global" : (store.selectedFolder?.lastPathComponent ?? "Choose a working folder"))
                    .font(PiFont.rowEmphasis)
                    .lineLimit(1)
                Text(isGlobal
                    ? "Not tied to a project folder"
                    : (store.selectedFolder?.path ?? "\(store.newChatAgent.displayName) uses this as its current directory"))
                    .font(PiFont.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: PiTheme.space8)
            Toggle("Worktree", isOn: Binding(
                get: { store.newChatWorktree != nil },
                set: { store.setNewChatWorktree($0) }
            ))
            .toggleStyle(.checkbox)
            .font(PiFont.caption)
            .disabled(isGlobal && store.newChatWorktree == nil)
            .help("Run this chat in a fresh worktree cut off the project's main branch, stored in \(WorktreeService.root.path)")
            if store.selectedGit.isRepository, let branch = store.selectedGit.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(store.selectedGit.statusHint ?? "Git branch")
            }
            Menu {
                Button {
                    store.chooseFolder(WorkspaceOrganization.globalWorkingDirectory)
                } label: {
                    Label("Global", systemImage: isGlobal ? "checkmark" : "globe")
                }
                .accessibilityValue(isGlobal ? "Selected" : "")
                ForEach(workingFolders, id: \.path) { folder in
                    let selected = store.selectedFolder?.standardizedFileURL.path == folder.standardizedFileURL.path
                    Button {
                        store.chooseFolder(folder)
                    } label: {
                        Label(
                            folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent,
                            systemImage: selected ? "checkmark" : "folder"
                        )
                    }
                    .help(folder.path)
                    .accessibilityValue(selected ? "Selected" : folder.path)
                }
                Button(action: store.importProjectFolder) {
                    Label("Import Folder…", systemImage: "folder.badge.plus")
                }
            } label: {
                Text("Choose…").font(PiFont.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Conversation scope")
            .accessibilityValue(isGlobal ? "Global" : (store.selectedFolder?.lastPathComponent ?? "No folder"))
        }
        .padding(.horizontal, PiTheme.space10)
        .frame(height: 40)
        .piInset()
    }
}
