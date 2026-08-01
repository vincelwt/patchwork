import SwiftUI

struct NewChatView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: PatchworkTheme.space6) {
            if store.messages.isEmpty {
                Spacer()
                Text("Start a conversation")
                    .font(PatchworkFont.displayTitle)
                Text(emptyStateDetail)
                    .font(PatchworkFont.body)
                    .foregroundStyle(.secondary)
                AgentPicker()
                    .padding(.top, PatchworkTheme.space8)
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
        .background(Color.patchworkTranscript)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: PatchworkTheme.space8) {
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
            .frame(maxWidth: PatchworkTheme.composerMaxWidth)
            .padding(.horizontal, PatchworkTheme.space20)
            .padding(.bottom, PatchworkTheme.space16)
            .frame(maxWidth: .infinity)
            .background(Color.patchworkTranscript)
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
        HStack(spacing: PatchworkTheme.space8) {
            Image(systemName: isGlobal ? "globe" : "folder")
                .font(.system(size: PatchworkIcon.small))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(isGlobal ? "Global" : (store.selectedFolder?.lastPathComponent ?? "Choose a working folder"))
                    .font(PatchworkFont.rowEmphasis)
                    .lineLimit(1)
                Text(isGlobal
                    ? "Not tied to a project folder"
                    : (store.selectedFolder?.path ?? "\(store.newChatAgent.displayName) uses this as its current directory"))
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: PatchworkTheme.space8)
            Toggle("Worktree", isOn: Binding(
                get: { store.newChatWorktree != nil },
                set: { store.setNewChatWorktree($0) }
            ))
            .toggleStyle(.checkbox)
            .font(PatchworkFont.caption)
            .disabled(isGlobal && store.newChatWorktree == nil)
            .help("Run this chat in a fresh worktree cut off the project's main branch, stored in \(WorktreeService.root.path)")
            if store.selectedGit.isRepository, let branch = store.selectedGit.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(PatchworkFont.caption)
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
                Text("Choose…").font(PatchworkFont.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Conversation scope")
            .accessibilityValue(isGlobal ? "Global" : (store.selectedFolder?.lastPathComponent ?? "No folder"))
        }
        .padding(.horizontal, PatchworkTheme.space10)
        .frame(height: 40)
        .patchworkInset()
    }
}
