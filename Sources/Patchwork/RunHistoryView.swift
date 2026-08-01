import PatchworkKit
import SwiftUI

/// What happened the last few times an automation fired. The control plane stores status,
/// timing, and one error or summary per run; full output remains in the target conversation.
struct RunHistoryView: View {
    let entry: ScheduleEntry
    let requiresAcknowledgement: Bool
    let onReviewed: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RunHistoryModel
    @State private var reviewError: String?

    init(
        entry: ScheduleEntry,
        service: any ScheduleServing,
        requiresAcknowledgement: Bool = false,
        onReviewed: @escaping () -> Bool = { true }
    ) {
        self.entry = entry
        self.requiresAcknowledgement = requiresAcknowledgement
        self.onReviewed = onReviewed
        _model = StateObject(wrappedValue: RunHistoryModel(service: service, scheduleID: entry.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PatchworkHairline()
            content
            PatchworkHairline()
            HStack {
                if let reviewError {
                    Text(reviewError)
                        .font(PatchworkFont.caption)
                        .foregroundStyle(Color.patchworkRed)
                        .lineLimit(2)
                }
                Spacer()
                Button(requiresAcknowledgement ? "I Reviewed History" : "Done") {
                    if !requiresAcknowledgement || onReviewed() {
                        dismiss()
                    } else {
                        reviewError = ScheduleServiceError.recoveryStorageUnavailable.localizedDescription
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(requiresAcknowledgement && !model.hasAuthoritativeSnapshot)
            }
            .padding(PatchworkTheme.space12)
        }
        .frame(width: 520, height: 460)
        .background(Color.patchworkTranscript)
        .task { await model.reload() }
    }

    private var header: some View {
        HStack(spacing: PatchworkTheme.space8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Run History").font(PatchworkFont.title)
                Text(entry.name)
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PatchworkTheme.space8)
            if model.isLoading && !model.runs.isEmpty { ProgressView().controlSize(.mini) }
            Button { Task { await model.reload() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: PatchworkIcon.small, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .accessibilityLabel("Refresh run history")
        }
        .padding(.horizontal, PatchworkTheme.space16)
        .padding(.vertical, PatchworkTheme.space12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            PatchworkUnavailableView(
                "Run history unavailable",
                systemImage: "clock.badge.exclamationmark",
                description: error
            ) {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.runs.isEmpty {
            PatchworkUnavailableView(
                "No runs yet",
                systemImage: "clock.arrow.2.circlepath",
                description: "Runs appear here once this automation has fired. The background service keeps the most recent \(PatchworkTheme.runHistoryLimit)."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                    ForEach(model.runs) { RunHistoryRow(run: $0) }
                }
                .padding(.horizontal, PatchworkTheme.space12)
                .padding(.vertical, PatchworkTheme.space8)
            }
        }
    }
}

private struct RunHistoryRow: View {
    let run: Run

    var body: some View {
        HStack(alignment: .top, spacing: PatchworkTheme.space8) {
            StatusDot(color: run.statusTint)
                .padding(.top, PatchworkTheme.space6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: PatchworkTheme.space6) {
                    Text(run.statusLabel).font(PatchworkFont.rowEmphasis)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(PatchworkFont.micro)
                        .foregroundStyle(.secondary)
                    if let duration = run.durationLabel {
                        Text("· \(duration)")
                            .font(PatchworkFont.micro.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let attempt = run.attempt, attempt > 1 {
                        Text("· Attempt \(attempt)").font(PatchworkFont.micro).foregroundStyle(.tertiary)
                    }
                }
                if let detail = run.detailText {
                    Text(detail)
                        .font(PatchworkFont.micro)
                        .foregroundStyle(run.detailIsError ? Color.patchworkRed : .secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PatchworkTheme.space10)
        .padding(.vertical, PatchworkTheme.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension Run {
    /// A status a newer daemon invented still reads as itself rather than disappearing.
    var statusLabel: String {
        switch status {
        case .queued: "Queued"
        case .running: "Running"
        case .ok: "Succeeded"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .timeout: "Timed out"
        case .interrupted: "Interrupted"
        default: status.rawValue.isEmpty ? "Unknown" : status.rawValue.capitalized
        }
    }

    var statusTint: Color {
        switch status {
        case .ok: .patchworkGreen
        case .failed, .timeout: .patchworkRed
        case .skipped, .interrupted: .patchworkOrange
        case .queued, .running: .patchworkBlue
        default: .secondary
        }
    }

    /// Only a finished run has a duration; one still in flight would report a growing number
    /// that this sheet does not refresh, so it shows none.
    var durationLabel: String? {
        finishedAt.map { NumberFormatting.duration($0.timeIntervalSince(startedAt)) }
    }

    /// Whatever the daemon stored: the failure reason if there is one, otherwise the summary.
    /// Bounded like every other retained string in the app.
    var detailText: String? {
        var parts: [String] = []
        if let raw = (error ?? summary)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            parts.append(raw)
        }
        if let nextAttemptAt {
            parts.append("Retry scheduled \(nextAttemptAt.formatted(date: .abbreviated, time: .shortened)).")
        }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: " ").prefix(PatchworkTheme.sessionPreviewLimit))
    }

    var detailIsError: Bool {
        error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

@MainActor
final class RunHistoryModel: ObservableObject {
    @Published private(set) var runs: [Run] = []
    @Published private(set) var error: String?
    /// Starts true so the sheet opens on a spinner instead of flashing "No runs yet".
    @Published private(set) var isLoading = true
    @Published private(set) var hasAuthoritativeSnapshot = false

    private let service: any ScheduleServing
    private let scheduleID: String
    private var reloadGeneration = 0
    private var outstandingReloads = 0

    init(service: any ScheduleServing, scheduleID: String) {
        self.service = service
        self.scheduleID = scheduleID
    }

    @discardableResult
    func reload() async -> Bool {
        reloadGeneration += 1
        let generation = reloadGeneration
        outstandingReloads += 1
        isLoading = true
        defer {
            outstandingReloads -= 1
            isLoading = outstandingReloads > 0
        }
        do {
            let loaded = try await service.loadRuns(scheduleID: scheduleID)
                .sorted { $0.startedAt > $1.startedAt }
            guard generation == reloadGeneration else { return false }
            runs = Array(loaded.prefix(PatchworkTheme.runHistoryLimit))
            error = nil
            hasAuthoritativeSnapshot = true
            return true
        } catch {
            guard generation == reloadGeneration else { return false }
            self.error = error.localizedDescription
            return false
        }
    }
}
