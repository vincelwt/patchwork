import SwiftUI

/// Recurring automations, presented with the same restraint as the rest of the app: a flat list,
/// one editor sheet, and an honest empty state when the background service is not running.
struct SchedulesView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model: SchedulesModel

    init(service: any ScheduleServing) {
        _model = StateObject(wrappedValue: SchedulesModel(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PiHairline()
            content
        }
        .frame(width: 560, height: 460)
        .background(Color.piTranscript)
        .task { await model.reload() }
        .sheet(item: $model.editing) { draft in
            ScheduleEditor(draft: draft) { saved in
                Task { await model.save(saved) }
            }
            .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: PiTheme.space8) {
            Text("Automations").font(PiFont.title)
            if model.isBusy { ProgressView().controlSize(.mini) }
            Spacer(minLength: PiTheme.space8)
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
                    .font(PiFont.caption)
            }
            .buttonStyle(.plain)
            .help("Create a recurring automation")
        }
        .padding(.horizontal, PiTheme.space16)
        .padding(.vertical, PiTheme.space12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            ContentUnavailableView {
                Label("Automations unavailable", systemImage: "clock.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                "No automations yet",
                systemImage: "clock.arrow.2.circlepath",
                description: Text("Run a prompt on a schedule: once, every few minutes, on a cron, or whenever a conversation is idle.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                    ForEach(model.entries) { entry in
                        ScheduleRow(
                            entry: entry,
                            threadName: threadName(for: entry),
                            onEdit: { model.editing = ScheduleDraft(entry: entry, isNew: false) },
                            onToggle: { Task { await model.setPaused(entry, paused: entry.enabled) } },
                            onRun: { Task { await model.runNow(entry) } },
                            onDelete: { Task { await model.delete(entry) } }
                        )
                    }
                }
                .padding(.horizontal, PiTheme.space12)
                .padding(.vertical, PiTheme.space8)
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
    let onToggle: () -> Void
    let onRun: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: PiTheme.space10) {
            StatusDot(color: entry.enabled ? .piGreen : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(PiFont.rowEmphasis).lineLimit(1)
                Text("\(entry.trigger.summary) · \(threadName)")
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PiTheme.space8)
            if let next = entry.nextRunAt, entry.enabled {
                Text(next.relativeShort).font(PiFont.micro).foregroundStyle(.tertiary)
            }
            if hovering {
                Button(action: onRun) { Image(systemName: "play.fill") }
                    .buttonStyle(.plain).help("Run now")
                Button(action: onToggle) { Image(systemName: entry.enabled ? "pause.fill" : "play.circle") }
                    .buttonStyle(.plain).help(entry.enabled ? "Pause" : "Resume")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete")
            }
        }
        .font(.system(size: PiIcon.small, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PiTheme.space10)
        .frame(height: 40)
        .contentShape(Rectangle())
        .piRowBackground(selected: false, hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.trigger.summary), \(entry.enabled ? "enabled" : "paused")")
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
    @Published var error: String?
    @Published var isBusy = false

    private let service: any ScheduleServing

    init(service: any ScheduleServing) { self.service = service }

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            entries = try await service.loadSchedules().sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
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
