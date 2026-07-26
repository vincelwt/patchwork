import Foundation
import SwiftUI

/// A parsed `/limits` report. The codex-limits extension prints one indented block per
/// signed-in account; this turns that text into something the status bar can draw with native
/// controls instead of showing a monospaced dump.
struct LimitsReport: Equatable, Sendable {
    var accounts: [LimitsAccount]
    var generatedAt: Date

    var isEmpty: Bool { accounts.isEmpty }
}

struct LimitsAccount: Identifiable, Equatable, Sendable {
    var name: String
    var email: String?
    var plan: String?
    var windows: [LimitsWindow]
    /// Banked resets and any other trailing lines, kept verbatim so nothing is silently lost.
    var notes: [String]
    var error: String?

    var id: String { name }

    /// The window closest to running out drives the account's colour.
    var tightest: LimitsWindow? {
        windows.compactMap { $0.remainingPercent == nil ? nil : $0 }
            .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
    }
}

struct LimitsWindow: Identifiable, Equatable, Sendable {
    var label: String
    var remainingPercent: Int?
    var resets: String?
    /// Everything the extension printed for this window, for the tooltip.
    var detail: String

    var id: String { label }
}

enum LimitsReportParser {
    /// Lines are `Name`, `  Key: value`, `  window: 62% remaining · … · resets …`, and
    /// deeper-indented continuation lines. Anything unrecognised is preserved as a note.
    static func parse(_ text: String, now: Date = Date()) -> LimitsReport {
        var accounts: [LimitsAccount] = []
        var current: LimitsAccount?

        func commit() {
            if let account = current, !account.name.isEmpty { accounts.append(account) }
            current = nil
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                commit()
                current = LimitsAccount(name: trimmed, email: nil, plan: nil, windows: [], notes: [], error: nil)
                continue
            }
            guard current != nil else { continue }

            if let range = trimmed.range(of: "Unable to load limits:") {
                current?.error = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }

            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                current?.notes.append(trimmed)
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key.lowercased() {
            case "email":
                current?.email = value
            case "plan":
                current?.plan = value.replacingOccurrences(of: "_", with: " ")
            default:
                if value.contains("% remaining") || value.contains("% used") {
                    current?.windows.append(window(label: key, value: value))
                } else {
                    current?.notes.append(trimmed)
                }
            }
        }
        commit()

        // Bounded: a runaway report must not become an unbounded view hierarchy.
        let limited = accounts.prefix(8).map { account -> LimitsAccount in
            var value = account
            value.windows = Array(value.windows.prefix(8))
            value.notes = Array(value.notes.prefix(8))
            return value
        }
        return LimitsReport(accounts: Array(limited), generatedAt: now)
    }

    private static func window(label: String, value: String) -> LimitsWindow {
        let segments = value.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        var remaining: Int?
        var resets: String?
        for segment in segments {
            if segment.hasSuffix("% remaining"), let number = Int(segment.dropLast("% remaining".count)) {
                remaining = number
            } else if segment.lowercased().hasPrefix("resets ") {
                resets = String(segment.dropFirst("resets ".count))
            }
        }
        return LimitsWindow(
            label: label.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord,
            remainingPercent: remaining,
            resets: resets,
            detail: value
        )
    }
}

/// Holds the latest `/limits` result for the whole app. The refresh action is installed by the
/// app store once a runtime exists; the view never talks to Pi directly.
@MainActor
final class LimitsReportStore: ObservableObject {
    static let shared = LimitsReportStore()

    @Published private(set) var report: LimitsReport?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// Set by `AppStore`. Absent means limits cannot be fetched right now.
    var refreshAction: (() -> Void)?
    /// A hover must not fire a command every time the pointer crosses the chip.
    private static let staleAfter: TimeInterval = 120
    private var lastRequestedAt: Date?

    private init() {}

    var canRefresh: Bool { refreshAction != nil }

    func refreshIfStale(now: Date = Date()) {
        guard let refreshAction else { return }
        if let lastRequestedAt, now.timeIntervalSince(lastRequestedAt) < Self.staleAfter { return }
        if let report, now.timeIntervalSince(report.generatedAt) < Self.staleAfter { return }
        lastRequestedAt = now
        isLoading = true
        refreshAction()
    }

    func apply(text: String, now: Date = Date()) {
        let parsed = LimitsReportParser.parse(text, now: now)
        isLoading = false
        lastError = parsed.isEmpty ? "No accounts reported" : nil
        report = parsed.isEmpty ? report : parsed
    }

    func fail(_ message: String) {
        isLoading = false
        lastError = message
    }
}

/// The hover surface for account limits: every account, every window, native controls.
struct LimitsPopoverView: View {
    @ObservedObject private var limits = LimitsReportStore.shared
    /// Shown until the full report arrives, so the hover is never empty.
    let fallback: CodexAccountStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space12) {
            HStack(spacing: PiTheme.space6) {
                PiSectionHeader(title: "Usage limits")
                if limits.isLoading { ProgressView().controlSize(.mini) }
            }

            if let report = limits.report, !report.isEmpty {
                ForEach(report.accounts) { account in
                    LimitsAccountView(account: account)
                }
            } else if let fallback {
                LimitsAccountView(account: LimitsAccount(
                    name: fallback.account,
                    email: nil,
                    plan: nil,
                    windows: fallback.windows.map {
                        LimitsWindow(label: $0.label, remainingPercent: $0.remainingPercent, resets: nil, detail: "\($0.remainingPercent)% remaining")
                    },
                    notes: fallback.bankedResetCount.map { count in
                        count > 0 ? ["Banked resets: \(count) available"] : []
                    } ?? [],
                    error: nil
                ))
            } else {
                Text(limits.lastError ?? "Loading limits…")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = limits.lastError, limits.report != nil {
                Text(error).font(PiFont.micro).foregroundStyle(Color.piOrange)
            }
        }
        .padding(PiTheme.space16)
        .frame(width: 320)
        .onAppear { limits.refreshIfStale() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subscription usage limits")
    }
}

private struct LimitsAccountView: View {
    let account: LimitsAccount

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            HStack(spacing: PiTheme.space6) {
                Text(account.name).font(PiFont.captionEmphasis)
                if let plan = account.plan {
                    Text(plan)
                        .font(PiFont.micro)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, PiTheme.space4)
                        .piInset(radius: PiTheme.radiusSmall)
                }
                Spacer(minLength: 0)
            }
            if let email = account.email {
                Text(email).font(PiFont.micro).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            if let error = account.error {
                Text(error).font(PiFont.micro).foregroundStyle(Color.piOrange).lineLimit(2)
            }

            ForEach(account.windows) { window in
                HStack(spacing: PiTheme.space8) {
                    Text(window.label)
                        .font(PiFont.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    ProgressView(value: Double(window.remainingPercent ?? 0), total: 100)
                        .progressViewStyle(.linear)
                        .tint(tint(window.remainingPercent))
                    Text(window.remainingPercent.map { "\($0)%" } ?? "—")
                        .font(PiFont.micro.monospacedDigit())
                        .foregroundStyle(tint(window.remainingPercent))
                        .frame(width: 32, alignment: .trailing)
                }
                .help(window.detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(account.name) \(window.label)")
                .accessibilityValue(window.detail)
            }

            ForEach(account.notes, id: \.self) { note in
                Text(note).font(PiFont.micro).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private func tint(_ remaining: Int?) -> Color {
        guard let remaining else { return .secondary }
        if remaining <= 15 { return .piRed }
        if remaining <= 30 { return .piOrange }
        return .secondary
    }
}
