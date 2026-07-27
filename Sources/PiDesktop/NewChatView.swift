import AppKit
import SwiftUI

struct NewChatView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: PiTheme.space6) {
            if store.messages.isEmpty {
                Spacer()
                Text("Start a conversation")
                    .font(PiFont.displayTitle)
                Text("Pi will work in the folder you choose.")
                    .font(PiFont.body)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                MessageScrollView(
                    messages: store.messages,
                    streaming: store.streamingMessage,
                    isRunning: true,
                    restoredAnchorID: nil,
                    unseenMessageID: nil,
                    onVisibleAnchorChange: { _ in }
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
                    text: $store.draft,
                    attachments: $store.attachments,
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

    private var folderContext: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: "folder")
                .font(.system(size: PiIcon.small))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.selectedFolder?.lastPathComponent ?? "Choose a working folder")
                    .font(PiFont.rowEmphasis)
                    .lineLimit(1)
                Text(store.selectedFolder?.path ?? "Pi uses this as its current directory")
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
                if !store.recentFolders.isEmpty {
                    ForEach(store.recentFolders, id: \.path) { folder in
                        Button(folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent) {
                            store.chooseFolder(folder)
                        }
                        .help(folder.path)
                    }
                    Divider()
                }
                Button("Browse…", action: browseForFolder)
            } label: {
                Text("Choose…").font(PiFont.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, PiTheme.space10)
        .frame(height: 40)
        .piInset()
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a working folder for Pi"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.selectedFolder
        if panel.runModal() == .OK, let url = panel.url { store.chooseFolder(url) }
    }
}
