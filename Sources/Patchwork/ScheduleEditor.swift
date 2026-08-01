import SwiftUI

/// One sheet for creating and editing an automation. Every trigger kind the control plane
/// supports is expressible here, and an automation that could never fire cannot be saved.
struct ScheduleEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var entry: ScheduleEntry
    @State private var kind: TriggerKind
    @State private var onceDate: Date
    @State private var everyMinutes: Int
    @State private var cronExpression: String
    private let isNew: Bool
    private let onSave: (ScheduleEntry) -> Void

    enum TriggerKind: String, CaseIterable, Identifiable {
        case once, every, cron, idle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .once: "Once"
            case .every: "Every"
            case .cron: "Cron"
            case .idle: "When idle"
            }
        }
    }

    init(draft: ScheduleDraft, onSave: @escaping (ScheduleEntry) -> Void) {
        _entry = State(initialValue: draft.entry)
        isNew = draft.isNew
        self.onSave = onSave
        switch draft.entry.trigger {
        case let .once(at):
            _kind = State(initialValue: .once)
            _onceDate = State(initialValue: at)
            _everyMinutes = State(initialValue: 60)
            _cronExpression = State(initialValue: "0 9 * * 1-5")
        case let .interval(seconds):
            _kind = State(initialValue: .every)
            _onceDate = State(initialValue: Date().addingTimeInterval(3_600))
            _everyMinutes = State(initialValue: max(1, seconds / 60))
            _cronExpression = State(initialValue: "0 9 * * 1-5")
        case let .cron(expression, _):
            _kind = State(initialValue: .cron)
            _onceDate = State(initialValue: Date().addingTimeInterval(3_600))
            _everyMinutes = State(initialValue: 60)
            _cronExpression = State(initialValue: expression)
        case let .heartbeat(seconds):
            _kind = State(initialValue: .idle)
            _onceDate = State(initialValue: Date().addingTimeInterval(3_600))
            _everyMinutes = State(initialValue: max(1, seconds / 60))
            _cronExpression = State(initialValue: "0 9 * * 1-5")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New automation" : "Edit automation")
                .font(PatchworkFont.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PatchworkTheme.space16)
                .padding(.vertical, PatchworkTheme.space12)
            PatchworkHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: PatchworkTheme.space16) {
                    field("Name") {
                        TextField("Morning triage", text: $entry.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Runs in") { targetPicker }

                    field("Prompt") {
                        TextEditor(text: $entry.prompt)
                            .font(PatchworkFont.body)
                            .frame(height: 80)
                            .scrollContentBackground(.hidden)
                            .padding(PatchworkTheme.space6)
                            .patchworkInset()
                    }

                    field("Trigger") { triggerControls }

                    field("Safety") {
                        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
                            Toggle("Skip when the conversation is already running", isOn: $entry.skipIfRunning)
                            Toggle("Enabled", isOn: $entry.enabled)
                        }
                        .toggleStyle(.checkbox)
                        .font(PatchworkFont.caption)
                    }

                    if let problem = ScheduleValidation.problem(with: composed) {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(PatchworkFont.caption)
                            .foregroundStyle(Color.patchworkOrange)
                    }
                }
                .padding(PatchworkTheme.space16)
            }

            PatchworkHairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Create" : "Save") {
                    onSave(composed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ScheduleValidation.problem(with: composed) != nil)
            }
            .padding(PatchworkTheme.space12)
        }
        .frame(width: 520, height: 560)
        .background(Color.patchworkTranscript)
    }

    /// The entry as the form currently describes it, so validation and saving always agree.
    private var composed: ScheduleEntry {
        var value = entry
        switch kind {
        case .once: value.trigger = .once(at: onceDate)
        case .every: value.trigger = .interval(everySeconds: everyMinutes * 60)
        case .cron: value.trigger = .cron(expression: cronExpression, timeZone: TimeZone.current.identifier)
        case .idle: value.trigger = .heartbeat(everySeconds: everyMinutes * 60)
        }
        return value
    }

    @ViewBuilder
    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            Picker("", selection: targetIsExisting) {
                Text("An existing conversation").tag(true)
                Text("A new conversation").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if case .existingThread = entry.target {
                Picker("", selection: threadSelection) {
                    ForEach(store.sessions.filter { !$0.isArchived }.prefix(50)) { session in
                        Text(session.displayName).tag(session.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            } else if case let .newThread(cwd, _) = entry.target {
                HStack(spacing: PatchworkTheme.space6) {
                    Text(cwd.isEmpty ? "No folder chosen" : cwd)
                        .font(PatchworkFont.micro)
                        .foregroundStyle(cwd.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                        .font(PatchworkFont.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var triggerControls: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space8) {
            Picker("", selection: $kind) {
                ForEach(TriggerKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .once:
                DatePicker("", selection: $onceDate, in: Date()...)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            case .every, .idle:
                HStack(spacing: PatchworkTheme.space6) {
                    Stepper(value: $everyMinutes, in: 1...10_080) {
                        Text("Every \(everyMinutes) minute\(everyMinutes == 1 ? "" : "s")")
                            .font(PatchworkFont.caption)
                    }
                    if kind == .idle {
                        Text("only while the conversation is idle")
                            .font(PatchworkFont.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .cron:
                VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
                    TextField("0 9 * * 1-5", text: $cronExpression)
                        .textFieldStyle(.roundedBorder)
                        .font(PatchworkFont.code)
                    Text("minute hour day-of-month month day-of-week · \(TimeZone.current.identifier)")
                        .font(PatchworkFont.micro)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var targetIsExisting: Binding<Bool> {
        Binding(
            get: { if case .existingThread = entry.target { return true } else { return false } },
            set: { isExisting in
                if isExisting {
                    entry.target = .existingThread(threadID: store.selectedSession?.id ?? store.sessions.first?.id ?? "")
                } else {
                    entry.target = .newThread(cwd: store.selectedFolder?.path ?? "", namePattern: nil)
                }
            }
        )
    }

    private var threadSelection: Binding<String> {
        Binding(
            get: { if case let .existingThread(id) = entry.target { return id } else { return "" } },
            set: { entry.target = .existingThread(threadID: $0) }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if case let .newThread(_, pattern) = entry.target {
            entry.target = .newThread(cwd: url.path, namePattern: pattern)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            Text(title.uppercased())
                .font(PatchworkFont.micro.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
