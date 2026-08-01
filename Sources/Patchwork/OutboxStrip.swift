import SwiftUI

/// The strip listing every message still waiting to reach Pi, shown directly above the text
/// editor. Absent entirely (not just visually empty) when there is nothing queued, so it never
/// nudges the composer's height — see `OutboxPresentation.isEmpty` in `Outbox.swift`.
struct OutboxStrip: View {
    @EnvironmentObject private var store: AppStore

    private var rows: [OutboxPresentation.Row] {
        // Scoped to the conversation the attached runtime actually belongs to — `outbox` and
        // `runtimeState` are both process-wide, so an unrelated or idle conversation must never
        // show (or let you touch) another one's queued messages. Matches `QueueMenu`'s own gate
        // in `ComposerView.swift`.
        OutboxPresentation.rows(
            outbox: store.outbox,
            steeringQueue: store.runtimeState.steeringQueue,
            followUpQueue: store.runtimeState.followUpQueue,
            isSelectedRuntime: store.isSelectedRuntime
        )
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
                    ForEach(rows) { OutboxRowView(row: $0) }
                }
                .padding(.horizontal, PatchworkTheme.space10)
                .padding(.top, PatchworkTheme.space8)
                .padding(.bottom, PatchworkTheme.space6)

                PatchworkHairline()
            }
            .transition(.opacity)
        }
    }
}

/// One quiet row: a delivery-kind control, the text (truncated, editable in place for app-held
/// entries), and remove/edit actions. Read-only rows (Pi's own queue) render the same shape
/// minus every control that would imply they can be changed here.
private struct OutboxRowView: View {
    @EnvironmentObject private var store: AppStore
    let row: OutboxPresentation.Row
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
            HStack(alignment: .top, spacing: PatchworkTheme.space8) {
                deliveryControl
                textArea
                Spacer(minLength: PatchworkTheme.space4)
                actions
            }
            if let entry = row.entry, !entry.attachments.isEmpty {
                thumbnails(entry.attachments)
            }
        }
    }

    @ViewBuilder private var deliveryControl: some View {
        if let entry = row.entry {
            Menu {
                Button(OutboxEntry.Delivery.steer.label) {
                    store.setOutboxDelivery(id: entry.id, delivery: .steer)
                }
                Button(OutboxEntry.Delivery.followUp.label) {
                    store.setOutboxDelivery(id: entry.id, delivery: .followUp)
                }
            } label: {
                Text(entry.delivery.label)
            }
            .controlSize(.small)
            .font(PatchworkFont.micro)
            .fixedSize()
            .accessibilityLabel("Delivery")
            .accessibilityValue(entry.delivery.label)
        } else {
            Label(row.delivery.label, systemImage: "lock.fill")
                .font(PatchworkFont.micro)
                .foregroundStyle(.tertiary)
                .fixedSize()
                .help("Already queued with Pi — visible here, but only Pi can deliver or withdraw it")
        }
    }

    @ViewBuilder private var textArea: some View {
        if let entry = row.entry, isEditing {
            TextField("Message", text: Binding(
                get: { entry.text },
                set: { store.updateOutbox(id: entry.id, text: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(PatchworkFont.caption)
            .lineLimit(1...4)
            .focused($isFocused)
            .onSubmit { isEditing = false }
            .onAppear { isFocused = true }
        } else {
            Text(displayText)
                .font(PatchworkFont.caption)
                .foregroundStyle(row.isEditable ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.text.isEmpty ? displayText : row.text)
        }
    }

    /// Falls back to an attachment count when the queued message is image-only, so the row is
    /// never left blank.
    private var displayText: String {
        guard row.text.isEmpty else { return row.text }
        guard row.attachmentCount > 0 else { return "" }
        return row.attachmentCount == 1 ? "Image" : "\(row.attachmentCount) images"
    }

    @ViewBuilder private var actions: some View {
        if let entry = row.entry {
            IconButton(
                symbol: isEditing ? "checkmark" : "pencil",
                help: isEditing ? "Done editing" : "Edit",
                action: { isEditing.toggle() }
            )
            .accessibilityLabel(isEditing ? "Finish editing queued message" : "Edit queued message")

            IconButton(symbol: "xmark", help: "Remove", action: { store.removeOutbox(id: entry.id) })
                .accessibilityLabel("Remove queued message")
        }
    }

    /// Same preview size the composer itself uses inline, so a queued attachment looks exactly
    /// like it did before it was sent.
    private func thumbnails(_ attachments: [ImageAttachment]) -> some View {
        HStack(spacing: PatchworkTheme.space4) {
            ForEach(attachments) { attachment in
                if let image = attachment.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: PatchworkTheme.inlineAttachmentHeight)
                        .frame(maxWidth: PatchworkTheme.inlineAttachmentMaxWidth)
                        .clipShape(RoundedRectangle(cornerRadius: PatchworkTheme.radiusSmall, style: .continuous))
                }
            }
        }
    }
}
