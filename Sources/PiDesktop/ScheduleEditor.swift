import PiDeskKit
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
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var creationNeedsReview = false
    private let isNew: Bool
    private let onSave: (ScheduleEntry) async -> ScheduleSaveResult
    private let onReviewCreation: () async -> Bool

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

    init(
        draft: ScheduleDraft,
        onSave: @escaping (ScheduleEntry) async -> ScheduleSaveResult,
        onReviewCreation: @escaping () async -> Bool
    ) {
        _entry = State(initialValue: draft.entry)
        isNew = draft.isNew
        self.onSave = onSave
        self.onReviewCreation = onReviewCreation
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
                .font(PiFont.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PiTheme.space16)
                .padding(.vertical, PiTheme.space12)
            PiHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: PiTheme.space16) {
                    field("Name") {
                        TextField("Morning triage", text: $entry.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Runs in") { targetPicker }

                    field("Prompt") {
                        TextEditor(text: $entry.prompt)
                            .font(PiFont.body)
                            .frame(height: 80)
                            .scrollContentBackground(.hidden)
                            .padding(PiTheme.space6)
                            .piInset()
                    }

                    field("Trigger") { triggerControls }

                    field("Safety") {
                        VStack(alignment: .leading, spacing: PiTheme.space6) {
                            Toggle("Skip when the conversation is already running", isOn: $entry.skipIfRunning)
                            Toggle("Enabled", isOn: $entry.enabled)
                        }
                        .toggleStyle(.checkbox)
                        .font(PiFont.caption)
                    }

                    if let problem = ScheduleValidation.problem(with: composed) {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(PiFont.caption)
                            .foregroundStyle(Color.piOrange)
                    }
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.circle")
                            .font(PiFont.caption)
                            .foregroundStyle(creationNeedsReview ? Color.piOrange : Color.piRed)
                    }
                }
                .padding(PiTheme.space16)
            }

            PiHairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if creationNeedsReview {
                    Button("Refresh and Review", action: reviewCreation)
                    .disabled(isSaving)
                }
                Button(isNew ? "Create" : "Save", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    ScheduleValidation.problem(with: composed) != nil
                        || isSaving || creationNeedsReview
                )
            }
            .padding(PiTheme.space12)
        }
        .frame(width: 520, height: 560)
        .background(Color.piTranscript)
    }

    private func submit() {
        guard !isSaving else { return }
        let value = composed
        isSaving = true
        saveError = nil
        Task {
            switch await onSave(value) {
            case .saved:
                dismiss()
            case let .failed(message):
                saveError = message
            case let .needsReview(message):
                creationNeedsReview = true
                saveError = message
            }
            isSaving = false
        }
    }

    private func reviewCreation() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            if await onReviewCreation() { dismiss() }
            isSaving = false
        }
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
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            Picker("", selection: targetIsExisting) {
                Text("An existing conversation").tag(true)
                Text("A new conversation").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if case .existingThread = entry.target {
                Picker("", selection: threadSelection) {
                    ForEach(store.sessions.filter { !$0.isArchived }.prefix(50), id: \.instanceID) { session in
                        Text(session.displayName).tag(session.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            } else if case let .newThread(cwd, _) = entry.target {
                VStack(alignment: .leading, spacing: PiTheme.space8) {
                    HStack(spacing: PiTheme.space6) {
                        Text(cwd.isEmpty ? "No folder chosen" : cwd)
                            .font(PiFont.micro)
                            .foregroundStyle(cwd.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                            .font(PiFont.caption)
                    }
                    Picker("Agent", selection: agentSelection) {
                        ForEach(scheduleAgentChoices, id: \.self) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    .frame(maxWidth: 320)
                }
            }
        }
    }

    @ViewBuilder
    private var triggerControls: some View {
        VStack(alignment: .leading, spacing: PiTheme.space8) {
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
                HStack(spacing: PiTheme.space6) {
                    Stepper(value: $everyMinutes, in: 1...10_080) {
                        Text("Every \(everyMinutes) minute\(everyMinutes == 1 ? "" : "s")")
                            .font(PiFont.caption)
                    }
                    if kind == .idle {
                        Text("only while the conversation is idle")
                            .font(PiFont.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .cron:
                VStack(alignment: .leading, spacing: PiTheme.space4) {
                    TextField("0 9 * * 1-5", text: $cronExpression)
                        .textFieldStyle(.roundedBorder)
                        .font(PiFont.code)
                    Text("minute hour day-of-month month day-of-week · \(TimeZone.current.identifier)")
                        .font(PiFont.micro)
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
                    let id = store.selectedSession?.id ?? store.sessions.first?.id ?? ""
                    entry.target = .existingThread(threadID: id)
                    entry.agent = nil
                    if store.sessions.first(where: { $0.id == id })?.agent != .pi {
                        entry.mode = nil
                    }
                } else {
                    entry.target = .newThread(cwd: store.selectedFolder?.path ?? "", namePattern: nil)
                    entry.agent = entry.agent ?? store.newChatAgent
                    if (entry.agent ?? .pi) != .pi { entry.mode = nil }
                }
            }
        )
    }

    private var threadSelection: Binding<String> {
        Binding(
            get: { if case let .existingThread(id) = entry.target { return id } else { return "" } },
            set: { id in
                entry.target = .existingThread(threadID: id)
                entry.agent = nil
                if store.sessions.first(where: { $0.id == id })?.agent != .pi {
                    entry.mode = nil
                }
            }
        )
    }

    private var scheduleAgentChoices: [AgentKind] {
        let selected = entry.agent ?? .pi
        var choices = store.installedAgents
        if !choices.contains(selected) { choices.append(selected) }
        if choices.isEmpty { choices = [.pi] }
        return choices
    }

    private var agentSelection: Binding<AgentKind> {
        Binding(
            get: { entry.agent ?? .pi },
            set: { agent in
                entry.agent = agent
                if agent != .pi { entry.mode = nil }
            }
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
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            Text(title.uppercased())
                .font(PiFont.micro.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
