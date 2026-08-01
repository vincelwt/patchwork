import SwiftUI

/// Recurring automations, presented with the same restraint as the rest of the app: a flat list,
/// one editor sheet, and an honest empty state when the background service is not running.
/// A detail page (see `RootView.detail`), so visiting it never disturbs the selected conversation.
struct SchedulesView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model: SchedulesModel

    init(
        service: any ScheduleServing,
        persistence: (any ScheduleMutationIntentPersisting)? = nil
    ) {
        _model = StateObject(wrappedValue: SchedulesModel(
            service: service, persistence: persistence
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PiHairline()
            content
                // A second sheet, deliberately on the inner view: two `.sheet` modifiers on the
                // same view fight over one presentation slot.
                .sheet(item: $model.history) { entry in
                    RunHistoryView(
                        entry: entry,
                        service: model.service,
                        requiresAcknowledgement: model.runNeedsReviewIDs.contains(entry.id),
                        onReviewed: { model.acknowledgeRunHistory(entry) }
                    )
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.piTranscript)
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
            ScheduleEditor(
                draft: draft,
                onSave: { saved in await model.save(saved, isNew: draft.isNew) },
                onReviewCreation: { await model.reviewCreationOutcome() }
            )
            .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: PiTheme.space8) {
            Text("Automations").font(PiFont.title)
            if model.isBusy { ProgressView().controlSize(.mini) }
            Spacer(minLength: PiTheme.space8)
            Button {
                model.beginNew(
                    defaultEntry: ScheduleEntry(
                        name: "",
                        target: store.selectedSession.map { .existingThread(threadID: $0.id) }
                            ?? .newThread(cwd: store.selectedFolder?.path ?? "", namePattern: nil),
                        prompt: "",
                        agent: store.selectedSession == nil ? store.newChatAgent : nil,
                        trigger: .interval(everySeconds: 3_600)
                    )
                )
            } label: {
                Label("New automation", systemImage: "plus")
                    .font(PiFont.caption)
            }
            .buttonStyle(.plain)
            .disabled(model.creationNeedsReview)
            .help("Create a recurring automation")
        }
        .padding(.horizontal, PiTheme.space16)
        .padding(.vertical, PiTheme.space12)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if model.creationNeedsReview {
                HStack(alignment: .center, spacing: PiTheme.space8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("An automation may already have been created. Refresh and review the list before creating another one.")
                        .font(PiFont.caption)
                    Spacer(minLength: PiTheme.space8)
                    Button("Refresh and Review") {
                        Task { _ = await model.reviewCreationOutcome() }
                    }
                    .font(PiFont.caption)
                }
                .foregroundStyle(Color.piOrange)
                .padding(.horizontal, PiTheme.space16)
                .padding(.vertical, PiTheme.space8)
            }
            scheduleContent
        }
    }

    @ViewBuilder
    private var scheduleContent: some View {
        if let error = model.error, model.entries.isEmpty, !model.creationNeedsReview {
            PiUnavailableView(
                "Automations unavailable",
                systemImage: "clock.badge.exclamationmark",
                description: error
            ) {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.entries.isEmpty {
            PiUnavailableView(
                "No automations yet",
                systemImage: "clock.arrow.2.circlepath",
                description: "Run a prompt on a schedule: once, every few minutes, on a cron, or whenever a conversation is idle."
            )
        } else {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline, spacing: PiTheme.space8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(error).font(PiFont.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.piRed)
                    .padding(.horizontal, PiTheme.space16)
                    .padding(.vertical, PiTheme.space8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                        ForEach(model.entries) { entry in
                            ScheduleRow(
                                entry: entry,
                                threadName: threadName(for: entry),
                                onEdit: { model.editing = ScheduleDraft(entry: entry, isNew: false) },
                                onHistory: { model.reviewRunHistory(entry) },
                                onToggle: { enabled in Task { await model.setPaused(entry, paused: !enabled) } },
                                isRunningNow: model.runningNowIDs.contains(entry.id),
                                needsRunReview: model.runNeedsReviewIDs.contains(entry.id),
                                onRun: { Task { await model.runNow(entry) } },
                                onDelete: { Task { await model.delete(entry) } }
                            )
                        }
                    }
                    // Rows stay readable on a wide window instead of stretching the full detail width.
                    .frame(maxWidth: PiTheme.transcriptMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, PiTheme.space12)
                    .padding(.vertical, PiTheme.space8)
                }
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
    let isRunningNow: Bool
    let needsRunReview: Bool
    let onRun: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: PiTheme.space10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(PiFont.rowEmphasis).lineLimit(1)
                Text("\(entry.trigger.summary) · \(threadName)")
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PiTheme.space8)
            if entry.enabled, let next = entry.nextRunAt {
                Text(next.relativeShort).font(PiFont.micro).foregroundStyle(.tertiary)
            } else if !entry.enabled {
                Text("Paused").font(PiFont.micro).foregroundStyle(.tertiary)
            }
            // Always visible, not hover-revealed and not buried in the menu: knowing whether an
            // automation actually ran is the first question anyone has about it.
            Button(action: onHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: PiIcon.small, weight: .medium))
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
                Button(
                    isRunningNow ? "Starting…" : (needsRunReview ? "Review Before Running" : "Run Now"),
                    action: onRun
                )
                .disabled(isRunningNow || needsRunReview)
                Button("Run History…", action: onHistory)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: PiIcon.small, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(entry.name) actions")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, PiTheme.space10)
        .frame(height: 40)
        .contentShape(Rectangle())
        .piRowBackground(selected: false, hovering: hovering)
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
    @Published private(set) var runningNowIDs: Set<String> = []
    @Published private(set) var runNeedsReviewIDs: Set<String> = []
    @Published private(set) var creationNeedsReview = false

    let service: any ScheduleServing
    private let persistence: (any ScheduleMutationIntentPersisting)?
    private let now: () -> Date
    private let runClientIDFactory: () -> String
    private var intents: [String: ScheduleMutationIntent]
    private var runClientIDs: [String: String] = [:]
    private var pendingCreation: ScheduleEntry?
    private var savingKeys: Set<String> = []
    private var reloadGeneration = 0
    private var outstandingReloads = 0

    init(
        service: any ScheduleServing,
        persistence: (any ScheduleMutationIntentPersisting)? = nil,
        now: @escaping () -> Date = Date.init,
        runClientIDFactory: @escaping () -> String = {
            "desktop-run-\(UUID().uuidString.lowercased())"
        }
    ) {
        self.service = service
        self.persistence = persistence
        self.now = now
        self.runClientIDFactory = runClientIDFactory
        var recovered = persistence?.scheduleMutationIntents ?? [:]
        var changed = false
        for key in recovered.keys {
            guard var intent = recovered[key] else { continue }
            if intent.phase == .dispatching
                || now().timeIntervalSince(intent.startedAt) >= ScheduleMutationIntent.replayTTL {
                intent.phase = .needsReview
                recovered[key] = intent
                changed = true
            }
        }
        intents = recovered
        pendingCreation = recovered[ScheduleMutationIntent.creationKey]?.creationDraft
        creationNeedsReview = recovered[ScheduleMutationIntent.creationKey]?.phase == .needsReview
        for intent in recovered.values where intent.kind == .manualRun {
            guard let scheduleID = intent.scheduleID else { continue }
            runClientIDs[scheduleID] = intent.clientID
            if intent.phase == .needsReview { runNeedsReviewIDs.insert(scheduleID) }
        }
        if changed, persistence?.replaceScheduleMutationIntents(recovered) == false {
            error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
        }
    }

    @discardableResult
    func reload() async -> Bool {
        reloadGeneration += 1
        let generation = reloadGeneration
        outstandingReloads += 1
        isBusy = true
        defer {
            outstandingReloads -= 1
            isBusy = outstandingReloads > 0
        }
        do {
            let loaded = try await service.loadSchedules()
                .filter { !$0.isInternalPullRequestReviewWatch }
                .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            guard generation == reloadGeneration else { return false }
            entries = loaded
            guard pruneRunIntents(retaining: Set(loaded.map(\.id))) else {
                error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                return false
            }
            error = nil
            return true
        } catch {
            guard generation == reloadGeneration else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    func beginNew(defaultEntry: ScheduleEntry) {
        guard !creationNeedsReview else { return }
        editing = ScheduleDraft(entry: pendingCreation ?? defaultEntry, isNew: true)
    }

    func save(_ entry: ScheduleEntry, isNew: Bool) async -> ScheduleSaveResult {
        let saveKey = isNew ? ScheduleMutationIntent.creationKey : "edit:\(entry.id)"
        guard savingKeys.insert(saveKey).inserted else {
            return .failed(ScheduleServiceError.mutationAlreadyInFlight.localizedDescription)
        }
        defer { savingKeys.remove(saveKey) }
        if isNew, creationNeedsReview {
            return .needsReview(ScheduleServiceError.creationOutcomeUnknown.localizedDescription)
        }
        if isNew {
            if let existing = intents[ScheduleMutationIntent.creationKey] {
                if now().timeIntervalSince(existing.startedAt) >= ScheduleMutationIntent.replayTTL {
                    _ = updateIntentPhase(key: ScheduleMutationIntent.creationKey, phase: .needsReview)
                    return .needsReview(ScheduleServiceError.creationOutcomeUnknown.localizedDescription)
                }
                guard existing.phase == .retryable, existing.creationDraft == entry else {
                    return .failed("Retry the saved automation unchanged, or refresh and review the automation list before replacing it.")
                }
                var dispatching = existing
                dispatching.phase = .dispatching
                guard replaceIntent(key: ScheduleMutationIntent.creationKey, with: dispatching) else {
                    return .failed(ScheduleServiceError.recoveryStorageUnavailable.localizedDescription)
                }
            } else {
                let intent = ScheduleMutationIntent(
                    kind: .creation, phase: .dispatching, clientID: entry.id,
                    scheduleID: nil, creationDraft: entry, startedAt: now()
                )
                guard replaceIntent(key: ScheduleMutationIntent.creationKey, with: intent) else {
                    return .failed(ScheduleServiceError.recoveryStorageUnavailable.localizedDescription)
                }
            }
        }
        do {
            _ = try await service.save(entry, isNew: isNew)
            if isNew {
                guard replaceIntent(key: ScheduleMutationIntent.creationKey, with: nil) else {
                    markIntentNeedsReviewInMemory(key: ScheduleMutationIntent.creationKey)
                    self.error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                    return .needsReview(ScheduleServiceError.recoveryStorageUnavailable.localizedDescription)
                }
            }
            await reload()
            return .saved
        } catch {
            if isNew,
               let serviceError = error as? ScheduleServiceError,
               case .creationOutcomeUnknown = serviceError {
                if !updateIntentPhase(key: ScheduleMutationIntent.creationKey, phase: .needsReview) {
                    markIntentNeedsReviewInMemory(key: ScheduleMutationIntent.creationKey)
                }
                self.error = serviceError.localizedDescription
                return .needsReview(serviceError.localizedDescription)
            }
            if isNew, !updateIntentPhase(key: ScheduleMutationIntent.creationKey, phase: .retryable) {
                markIntentNeedsReviewInMemory(key: ScheduleMutationIntent.creationKey)
            }
            self.error = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// A successful reload is the acknowledgement boundary for an ambiguous create. The list is
    /// authoritative; only after it arrives may a later New action mint another idempotency key.
    func reviewCreationOutcome() async -> Bool {
        guard await reload() else { return false }
        guard replaceIntent(key: ScheduleMutationIntent.creationKey, with: nil) else {
            error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
            return false
        }
        error = nil
        return true
    }

    func delete(_ entry: ScheduleEntry) async {
        do {
            try await service.delete(id: entry.id)
            guard replaceIntent(key: ScheduleMutationIntent.runKey(entry.id), with: nil) else {
                self.error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                return
            }
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
        guard !runNeedsReviewIDs.contains(entry.id) else { return }
        guard runningNowIDs.insert(entry.id).inserted else { return }
        defer { runningNowIDs.remove(entry.id) }
        let key = ScheduleMutationIntent.runKey(entry.id)
        let clientID: String
        if var existing = intents[key] {
            if now().timeIntervalSince(existing.startedAt) >= ScheduleMutationIntent.replayTTL {
                _ = updateIntentPhase(key: key, phase: .needsReview)
                return
            }
            guard existing.phase == .retryable else { return }
            existing.phase = .dispatching
            guard replaceIntent(key: key, with: existing) else {
                error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                return
            }
            clientID = existing.clientID
        } else {
            clientID = runClientIDFactory()
            let intent = ScheduleMutationIntent(
                kind: .manualRun, phase: .dispatching, clientID: clientID,
                scheduleID: entry.id, creationDraft: nil, startedAt: now()
            )
            guard replaceIntent(key: key, with: intent) else {
                error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                return
            }
        }
        do {
            try await service.runNow(id: entry.id, clientID: clientID)
            guard replaceIntent(key: key, with: nil) else {
                markIntentNeedsReviewInMemory(key: key)
                error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                return
            }
            await reload()
        } catch {
            if let serviceError = error as? ScheduleServiceError, case .outcomeUnknown = serviceError {
                if !updateIntentPhase(key: key, phase: .needsReview) {
                    markIntentNeedsReviewInMemory(key: key)
                }
            } else if !updateIntentPhase(key: key, phase: .retryable) {
                markIntentNeedsReviewInMemory(key: key)
            }
            self.error = error.localizedDescription
        }
    }

    func reviewRunHistory(_ entry: ScheduleEntry) {
        history = entry
    }

    @discardableResult
    func acknowledgeRunHistory(_ entry: ScheduleEntry) -> Bool {
        guard replaceIntent(key: ScheduleMutationIntent.runKey(entry.id), with: nil) else {
            error = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
            return false
        }
        error = nil
        return true
    }

    private func updateIntentPhase(key: String, phase: ScheduleMutationIntent.Phase) -> Bool {
        guard var intent = intents[key] else { return false }
        intent.phase = phase
        return replaceIntent(key: key, with: intent)
    }

    private func replaceIntent(key: String, with intent: ScheduleMutationIntent?) -> Bool {
        var updated = intents
        if let intent { updated[key] = intent } else { updated.removeValue(forKey: key) }
        guard ScheduleMutationIntent.isWithinNormalBounds(updated) else { return false }
        if let persistence, !persistence.replaceScheduleMutationIntents(updated) { return false }
        intents = updated
        synchronizeRecoveryPresentation()
        return true
    }

    private func synchronizeRecoveryPresentation() {
        let creation = intents[ScheduleMutationIntent.creationKey]
        pendingCreation = creation?.creationDraft
        creationNeedsReview = creation?.phase == .needsReview
        runClientIDs = [:]
        runNeedsReviewIDs = []
        for intent in intents.values where intent.kind == .manualRun {
            guard let scheduleID = intent.scheduleID else { continue }
            runClientIDs[scheduleID] = intent.clientID
            if intent.phase == .needsReview { runNeedsReviewIDs.insert(scheduleID) }
        }
    }

    private func markIntentNeedsReviewInMemory(key: String) {
        guard var intent = intents[key] else { return }
        intent.phase = .needsReview
        intents[key] = intent
        synchronizeRecoveryPresentation()
    }

    private func pruneRunIntents(retaining scheduleIDs: Set<String>) -> Bool {
        let staleKeys = intents.compactMap { key, intent -> String? in
            guard intent.kind == .manualRun,
                  let scheduleID = intent.scheduleID,
                  !scheduleIDs.contains(scheduleID) else { return nil }
            return key
        }
        guard !staleKeys.isEmpty else { return true }
        var updated = intents
        for key in staleKeys { updated.removeValue(forKey: key) }
        guard let persistence else {
            intents = updated
            synchronizeRecoveryPresentation()
            return true
        }
        guard persistence.replaceScheduleMutationIntents(updated) else { return false }
        intents = updated
        synchronizeRecoveryPresentation()
        return true
    }
}

enum ScheduleSaveResult: Equatable {
    case saved
    case failed(String)
    case needsReview(String)
}
