import SwiftUI

/// Recurring automations, presented with the same restraint as the rest of the app: a flat list,
/// one editor sheet, and an honest empty state when the background service is not running.
/// A detail page (see `RootView.detail`), so visiting it never disturbs the selected conversation.
struct SchedulesView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model: SchedulesModel

    init(service: any ScheduleServing) {
        _model = StateObject(wrappedValue: SchedulesModel(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PatchworkHairline()
            content
                // A second sheet, deliberately on the inner view: two `.sheet` modifiers on the
                // same view fight over one presentation slot.
                .sheet(item: $model.history) { entry in
                    RunHistoryView(entry: entry, service: model.service)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.patchworkTranscript)
        .task {
            await model.reload()
            // A load that succeeded is authoritative even when it returns nothing: schedules
            // deleted elsewhere must clear the sidebar's clocks, and `.onChange` never fires
            // when an empty list reloads to an empty list. A failed load keeps the prior set.
            if model.error == nil { store.updateScheduledThreads(from: model.entries) }
        }
        // The sidebar's clock lives on `AppStore`; this is the one place the list is authoritative.
        .onChange(of: model.entries) { _, entries in store.updateScheduledThreads(from: entries) }
        .sheet(item: $model.editing) { draft in
            ScheduleEditor(draft: draft) { saved in
                Task { await model.save(saved) }
            }
            .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: PatchworkTheme.space8) {
            Text("Automations").font(PatchworkFont.title)
            if model.isBusy { ProgressView().controlSize(.mini) }
            Spacer(minLength: PatchworkTheme.space8)
            Button {
                model.editing = ScheduleDraft(
                    entry: ScheduleEntry(
                        name: "",
                        target: store.selectedSession.map { .existingThread(threadID: $0.id) }
                            ?? .newThread(cwd: store.selectedFolder?.path ?? "", namePattern: nil),
                        prompt: "",
                        trigger: .interval(everySeconds: 3_600)
                    ),
                    isNew: true
                )
            } label: {
                Label("New automation", systemImage: "plus")
                    .font(PatchworkFont.caption)
            }
            .buttonStyle(.plain)
            .help("Create a recurring automation")
        }
        .padding(.horizontal, PatchworkTheme.space16)
        .padding(.vertical, PatchworkTheme.space12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            PatchworkUnavailableView(
                "Automations unavailable",
                systemImage: "clock.badge.exclamationmark",
                description: error
            ) {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.entries.isEmpty {
            PatchworkUnavailableView(
                "No automations yet",
                systemImage: "clock.arrow.2.circlepath",
                description: "Run a prompt on a schedule: once, every few minutes, on a cron, or whenever a conversation is idle."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                    ForEach(model.entries) { entry in
                        ScheduleRow(
                            entry: entry,
                            threadName: threadName(for: entry),
                            onEdit: { model.editing = ScheduleDraft(entry: entry, isNew: false) },
                            onHistory: { model.history = entry },
                            onToggle: { enabled in Task { await model.setPaused(entry, paused: !enabled) } },
                            onRun: { Task { await model.runNow(entry) } },
                            onDelete: { Task { await model.delete(entry) } }
                        )
                    }
                }
                // Rows stay readable on a wide window instead of stretching the full detail width.
                .frame(maxWidth: PatchworkTheme.transcriptMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PatchworkTheme.space12)
                .padding(.vertical, PatchworkTheme.space8)
            }
        }
    }

    private func threadName(for entry: ScheduleEntry) -> String {
        switch entry.target {
        case let .existingThread(threadID):
            store.sessions.first { $0.id == threadID }?.displayName ?? "Conversation"
        case let .newThread(cwd, _):
            "New chat in \(URL(fileURLWithPath: cwd).lastPathComponent)"
        }
    }
}

private struct ScheduleRow: View {
    let entry: ScheduleEntry
    let threadName: String
    let onEdit: () -> Void
    let onHistory: () -> Void
    let onToggle: (Bool) -> Void
    let onRun: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: PatchworkTheme.space10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(PatchworkFont.rowEmphasis).lineLimit(1)
                Text("\(entry.trigger.summary) · \(threadName)")
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PatchworkTheme.space8)
            if entry.enabled, let next = entry.nextRunAt {
                Text(next.relativeShort).font(PatchworkFont.micro).foregroundStyle(.tertiary)
            } else if !entry.enabled {
                Text("Paused").font(PatchworkFont.micro).foregroundStyle(.tertiary)
            }
            // Always visible, not hover-revealed and not buried in the menu: knowing whether an
            // automation actually ran is the first question anyone has about it.
            Button(action: onHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: PatchworkIcon.small, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Run history")
            .accessibilityLabel("\(entry.name) run history")
            Toggle("", isOn: Binding(get: { entry.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(entry.enabled ? "Pause" : "Resume")
                .accessibilityLabel("\(entry.name) enabled")
            Menu {
                Button("Edit…", action: onEdit)
                Button("Run Now", action: onRun)
                Button("Run History…", action: onHistory)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: PatchworkIcon.small, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(entry.name) actions")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, PatchworkTheme.space10)
        .frame(height: 40)
        .contentShape(Rectangle())
        .patchworkRowBackground(selected: false, hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
    }
}

/// A schedule being edited. Identity is the sheet's presentation key.
struct ScheduleDraft: Identifiable {
    var entry: ScheduleEntry
    var isNew: Bool
    var id: String { entry.id }
}

@MainActor
final class SchedulesModel: ObservableObject {
    @Published var entries: [ScheduleEntry] = []
    @Published var editing: ScheduleDraft?
    /// The automation whose run history is on screen. `ScheduleEntry` is already `Identifiable`,
    /// so it is its own sheet key.
    @Published var history: ScheduleEntry?
    @Published var error: String?
    @Published var isBusy = false

    let service: any ScheduleServing

    init(service: any ScheduleServing) { self.service = service }

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            entries = try await service.loadSchedules()
                .filter { !$0.isInternalPullRequestReviewWatch }
                .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(_ entry: ScheduleEntry) async {
        do {
            _ = try await service.save(entry)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ entry: ScheduleEntry) async {
        do {
            try await service.delete(id: entry.id)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setPaused(_ entry: ScheduleEntry, paused: Bool) async {
        do {
            _ = try await service.setPaused(id: entry.id, paused: paused)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runNow(_ entry: ScheduleEntry) async {
        do {
            try await service.runNow(id: entry.id)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
