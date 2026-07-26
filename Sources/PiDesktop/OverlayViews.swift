import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtensionDialogView: View {
    @EnvironmentObject private var store: AppStore
    let request: ExtensionDialogRequest
    @State private var value: String

    init(request: ExtensionDialogRequest) {
        self.request = request
        _value = State(initialValue: request.prefill ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space16) {
            HStack(alignment: .top, spacing: PiTheme.space10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.piPurple)
                VStack(alignment: .leading, spacing: PiTheme.space4) {
                    Text(request.title)
                        .font(PiFont.title)
                    if let message = request.message, !message.isEmpty {
                        Text(message)
                            .font(PiFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            dialogContent

            HStack {
                Spacer()
                Button("Cancel") { store.respondToExtensionDialog(cancelled: true) }
                    .keyboardShortcut(.cancelAction)
                if request.method == .input || request.method == .editor {
                    Button("Submit") { store.respondToExtensionDialog(value: value) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(value.isEmpty)
                }
            }
        }
        .padding(PiTheme.space20)
        .frame(width: 460)
        .background(Color.piTranscript)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var dialogContent: some View {
        switch request.method {
        case .select:
            VStack(spacing: PiTheme.space6) {
                ForEach(request.options, id: \.self) { option in
                    Button {
                        store.respondToExtensionDialog(value: option)
                    } label: {
                        HStack {
                            Text(option).font(PiFont.row)
                            Spacer()
                            PiChevron(expanded: false)
                        }
                        .padding(.horizontal, PiTheme.space10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .piInset()
                }
            }
        case .confirm:
            HStack(spacing: PiTheme.space8) {
                Button("No") { store.respondToExtensionDialog(confirmed: false) }
                    .frame(maxWidth: .infinity)
                Button("Yes") { store.respondToExtensionDialog(confirmed: true) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
            }
        case .input:
            TextField(request.placeholder ?? "Enter a value", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !value.isEmpty { store.respondToExtensionDialog(value: value) } }
        case .editor:
            TextEditor(text: $value)
                .font(PiFont.code)
                .frame(height: 260)
                .padding(PiTheme.space6)
                .piInset()
        }
    }
}

struct ImageViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: ImagePayload
    @State private var zoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(payload.fileName ?? "Conversation image")
                    .font(PiFont.rowEmphasis)
                Spacer()
                Button(action: save) { Image(systemName: "square.and.arrow.down") }
                    .help("Save image")
                Slider(value: $zoom, in: 0.25...3)
                    .frame(width: 110)
                    .accessibilityLabel("Image zoom")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.bar)

            ScrollView([.horizontal, .vertical]) {
                if let image = payload.nsImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            width: max(300, image.size.width * zoom),
                            height: max(240, image.size.height * zoom)
                        )
                        .padding(24)
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .frame(width: 500, height: 400)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.88))
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = payload.fileName ?? "Pi image.\(fileExtension)"
        panel.allowedContentTypes = [UTType(mimeType: payload.mimeType) ?? .png]
        if panel.runModal() == .OK, let url = panel.url {
            try? payload.data.write(to: url, options: .atomic)
        }
    }

    private var fileExtension: String {
        UTType(mimeType: payload.mimeType)?.preferredFilenameExtension ?? "png"
    }
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(toast.text)
                .font(PiFont.caption)
                .lineLimit(3)
        }
        .padding(.horizontal, PiTheme.space12)
        .padding(.vertical, PiTheme.space8)
        .background(Color.piTranscript, in: Capsule())
        .overlay { Capsule().stroke(Color.piHairline, lineWidth: PiTheme.hairline) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .accessibilityLabel(toast.text)
    }

    private var icon: String {
        switch toast.style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .info: .accentColor
        case .warning: .orange
        case .error: .piRed
        }
    }
}
