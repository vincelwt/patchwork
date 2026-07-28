import SwiftUI

struct NewChatView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: PiTheme.space6) {
            if store.messages.isEmpty {
                Spacer()
                Text("Start a conversation")
                    .font(PiFont.displayTitle)
                Text("Start globally, or choose a project folder.")
                    .font(PiFont.body)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                MessageScrollView(
                    messages: store.messages,
                    streaming: store.streamingMessage,
                    isRunning: true,
                    transcriptRevision: store.transcriptRevision,
                    unseenMessageID: nil
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
                    placeholder: "Describe a task for Pi…",
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
                Text(isGlobal ? "Not tied to a project folder" : (store.selectedFolder?.path ?? "Pi uses this as its current directory"))
                    .font(PiFont.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: PiTheme.space8)
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
                if !workingFolders.isEmpty { Divider() }
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
