import AppKit
import SwiftUI

/// ⌘K palette. Fuzzy/substring ranking over the bounded search key that summary projection
/// already folded, so hundreds of sessions filter without a visible delay.
struct QuickSwitcherView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0

    private var results: [SessionSummary] {
        QuickSwitchScoring.rank(
            store.sessions.filter { !$0.isArchived },
            query: query,
            limit: PiTheme.quickSwitchResultLimit,
            folderName: { store.displayFolderName(for: $0) }
        )
    }

    var body: some View {
        let matches = results
        VStack(spacing: 0) {
            HStack(spacing: PiTheme.space8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                // A native field so arrow keys and Return are intercepted before the text
                // field turns them into caret movement.
                PaletteField(
                    text: $query,
                    placeholder: "Go to conversation",
                    onMove: { delta in
                        guard !matches.isEmpty else { return }
                        selection = min(max(0, selection + delta), matches.count - 1)
                    },
                    onSubmit: { activate(matches) },
                    onCancel: { isPresented = false }
                )
                .frame(height: 20)
                if !query.isEmpty {
                    Text("\(matches.count)")
                        .font(PiFont.micro.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, PiTheme.space16)
            .frame(height: 44)

            PiHairline()

            if matches.isEmpty {
                Text("No conversations match “\(query)”")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PiTheme.space16)
                    .padding(.vertical, PiTheme.space20)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, session in
                                QuickSwitchRow(
                                    session: session,
                                    running: store.isRunning(session),
                                    modifiedAt: store.liveModifiedAt(session),
                                    folderName: store.displayFolderName(for: session),
                                    unread: store.isUnread(session),
                                    selected: index == selection
                                )
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    activate(matches)
                                }
                            }
                        }
                        .padding(.vertical, PiTheme.space4)
                    }
                    .frame(maxHeight: PiTheme.quickSwitchRowHeight * 8)
                    .onChange(of: selection) { _, value in
                        withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(value, anchor: .center) }
                    }
                }
            }

            PiHairline()

            HStack(spacing: PiTheme.space12) {
                HintLabel(keys: "↑↓", text: "Navigate")
                HintLabel(keys: "↩", text: "Open")
                HintLabel(keys: "esc", text: "Dismiss")
                Spacer()
            }
            .padding(.horizontal, PiTheme.space16)
            .frame(height: 26)
            // The shortcuts are already spoken by the field and the rows.
            .accessibilityHidden(true)
        }
        .frame(width: PiTheme.quickSwitchWidth)
        .background(Color.piTranscript, in: RoundedRectangle(cornerRadius: PiTheme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PiTheme.panelRadius, style: .continuous)
                .stroke(Color.piHairline, lineWidth: PiTheme.hairline)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onChange(of: query) { _, _ in selection = 0 }
        .onExitCommand { isPresented = false }
        // `contain` rather than a blanket label, otherwise every child inherits the palette
        // name and VoiceOver repeats it once per hint chip.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick conversation switcher")
    }

    private func activate(_ matches: [SessionSummary]) {
        guard selection >= 0, selection < matches.count else { return }
        store.selectSession(matches[selection])
        isPresented = false
    }
}

private struct QuickSwitchRow: View {
    let session: SessionSummary
    let running: Bool
    let modifiedAt: Date
    let folderName: String
    let unread: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            if unread {
                Circle().fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .frame(width: PiTheme.gridIconColumn, alignment: .center)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: PiTheme.gridIconColumn, alignment: .center)
            }
            Text(session.displayName)
                .font(selected ? PiFont.rowEmphasis : PiFont.row)
                .lineLimit(1)
            Text(folderName)
                .font(PiFont.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: PiTheme.space4)
            if running {
                ProgressView().controlSize(.mini)
            } else {
                Text(modifiedAt.relativeShort)
                    .font(PiFont.micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, PiTheme.space12)
        .frame(height: PiTheme.quickSwitchRowHeight)
        .contentShape(Rectangle())
        .background(
            selected ? Color.piSelection : Color.clear,
            in: RoundedRectangle(cornerRadius: PiTheme.radiusSmall, style: .continuous)
        )
        .padding(.horizontal, PiTheme.space6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [session.displayName, folderName, modifiedAt.relativeShort]
        if running { parts.append("running") }
        if unread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

/// A borderless single-line `NSTextField` that hands arrow/Return/Escape to the palette instead
/// of consuming them as text editing commands.
private struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        field.setAccessibilityLabel("Quick switcher query")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if !context.coordinator.hasFocused, field.window != nil {
            context.coordinator.hasFocused = true
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        var hasFocused = false

        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

private struct HintLabel: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: PiTheme.space4) {
            Text(keys)
                .font(PiFont.micro.weight(.medium))
                .padding(.horizontal, PiTheme.space4)
                .frame(height: 14)
                .piInset(radius: 3)
            Text(text)
                .font(PiFont.micro)
                .foregroundStyle(.tertiary)
        }
    }
}
