import PiDeskKit
import SwiftUI

/// What happened the last few times an automation fired. The control plane stores status,
/// timing, and one error or summary per run; full output remains in the target conversation.
struct RunHistoryView: View {
    let entry: ScheduleEntry
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RunHistoryModel

    init(entry: ScheduleEntry, service: any ScheduleServing) {
        self.entry = entry
        _model = StateObject(wrappedValue: RunHistoryModel(service: service, scheduleID: entry.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PiHairline()
            content
            PiHairline()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(PiTheme.space12)
        }
        .frame(width: 520, height: 460)
        .background(Color.piTranscript)
        .task { await model.reload() }
    }

    private var header: some View {
        HStack(spacing: PiTheme.space8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Run History").font(PiFont.title)
                Text(entry.name)
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: PiTheme.space8)
            if model.isLoading && !model.runs.isEmpty { ProgressView().controlSize(.mini) }
            Button { Task { await model.reload() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: PiIcon.small, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .accessibilityLabel("Refresh run history")
        }
        .padding(.horizontal, PiTheme.space16)
        .padding(.vertical, PiTheme.space12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            PiUnavailableView(
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
            PiUnavailableView(
                "No runs yet",
                systemImage: "clock.arrow.2.circlepath",
                description: "Runs appear here once this automation has fired. The background service keeps the most recent \(PiTheme.runHistoryLimit)."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PiTheme.space2) {
                    ForEach(model.runs) { RunHistoryRow(run: $0) }
                }
                .padding(.horizontal, PiTheme.space12)
                .padding(.vertical, PiTheme.space8)
            }
        }
    }
}

private struct RunHistoryRow: View {
    let run: Run

    var body: some View {
        HStack(alignment: .top, spacing: PiTheme.space8) {
            StatusDot(color: run.statusTint)
                .padding(.top, PiTheme.space6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: PiTheme.space6) {
                    Text(run.statusLabel).font(PiFont.rowEmphasis)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(PiFont.micro)
                        .foregroundStyle(.secondary)
                    if let duration = run.durationLabel {
                        Text("· \(duration)")
                            .font(PiFont.micro.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let attempt = run.attempt, attempt > 1 {
                        Text("· Attempt \(attempt)").font(PiFont.micro).foregroundStyle(.tertiary)
                    }
                }
                if let detail = run.detailText {
                    Text(detail)
                        .font(PiFont.micro)
                        .foregroundStyle(run.detailIsError ? Color.piRed : .secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PiTheme.space10)
        .padding(.vertical, PiTheme.space6)
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
        case .ok: .piGreen
        case .failed, .timeout: .piRed
        case .skipped, .interrupted: .piOrange
        case .queued, .running: .piBlue
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
        return String(parts.joined(separator: " ").prefix(PiTheme.sessionPreviewLimit))
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

    private let service: any ScheduleServing
    private let scheduleID: String

    init(service: any ScheduleServing, scheduleID: String) {
        self.service = service
        self.scheduleID = scheduleID
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await service.loadRuns(scheduleID: scheduleID)
                .sorted { $0.startedAt > $1.startedAt }
            runs = Array(loaded.prefix(PiTheme.runHistoryLimit))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
