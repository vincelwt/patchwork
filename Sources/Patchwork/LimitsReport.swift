import AppKit
import Foundation
import PatchworkKit
import SwiftUI

/// A parsed `/limits` report. The codex-limits extension prints one indented block per
/// signed-in account; this turns that text into something the status bar can draw with native
/// controls instead of showing a monospaced dump. `Codable` so it can be persisted to disk and
/// survive a relaunch.
struct LimitsReport: Equatable, Codable, Sendable {
    var accounts: [LimitsAccount]
    var generatedAt: Date

    var isEmpty: Bool { accounts.isEmpty }
}

struct LimitsAccount: Identifiable, Equatable, Codable, Sendable {
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

struct LimitsWindow: Identifiable, Equatable, Codable, Sendable {
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

/// Persists the last successfully parsed `/limits` report so the popover (main window hover and
/// menu bar alike) has something to show the instant the app relaunches, before any runtime has
/// answered a fresh request.
struct LimitsReportDiskCache {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let defaultDirectory = PatchworkPaths.cacheDirectory
        self.fileURL = fileURL ?? defaultDirectory.appendingPathComponent("limits-report-cache.json")
    }

    func load() -> LimitsReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LimitsReport.self, from: data)
    }

    func save(_ report: LimitsReport) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Pure staleness policy shared by the hover trigger and the periodic background tick: never
/// while inactive, never without a way to refresh, never more often than the staleness window.
/// Kept independent of `LimitsReportStore` so every branch is directly testable.
enum LimitsRefreshPolicy {
    static func shouldRefresh(
        now: Date,
        appActive: Bool,
        hasRefreshAction: Bool,
        lastRequestedAt: Date?,
        reportGeneratedAt: Date?,
        staleAfter: TimeInterval
    ) -> Bool {
        guard hasRefreshAction, appActive else { return false }
        if let lastRequestedAt, now.timeIntervalSince(lastRequestedAt) < staleAfter { return false }
        if let reportGeneratedAt, now.timeIntervalSince(reportGeneratedAt) < staleAfter { return false }
        return true
    }
}

/// Holds the latest `/limits` result for the whole app. The refresh action is installed by the
/// app store once a runtime exists; the view never talks to Pi directly. Renders from the
/// on-disk cache instantly at launch, then refreshes itself periodically in the background —
/// hovering the account chip or opening the menu bar popover is no longer the only trigger.
@MainActor
final class LimitsReportStore: ObservableObject {
    static let shared = LimitsReportStore()

    @Published private(set) var report: LimitsReport?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// Set by `AppStore`. Absent means limits cannot be fetched right now.
    var refreshAction: (() -> Void)? {
        didSet { if refreshAction != nil { startBackgroundRefresh() } }
    }

    /// Neither a hover nor the background tick fires a command more often than this — a few
    /// minutes is current enough without spawning a Pi round trip on every pointer crossing or
    /// timer tick.
    static let staleAfter: TimeInterval = 300
    private var lastRequestedAt: Date?
    private let diskCache: LimitsReportDiskCache
    private var isAppActive: Bool
    private(set) var backgroundTask: Task<Void, Never>?
    private var activationTokens: [NSObjectProtocol] = []

    /// `isActiveOverride` and an explicit `diskCache` let tests drive staleness deterministically
    /// with an injected clock instead of real notifications or a live timer.
    init(diskCache: LimitsReportDiskCache = LimitsReportDiskCache(), isActiveOverride: Bool? = nil) {
        self.diskCache = diskCache
        self.report = diskCache.load()
        self.isAppActive = isActiveOverride ?? NSApplication.shared.isActive
        guard isActiveOverride == nil else { return }
        let center = NotificationCenter.default
        activationTokens = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isAppActive = true }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isAppActive = false }
            }
        ]
    }

    deinit {
        backgroundTask?.cancel()
        let center = NotificationCenter.default
        for token in activationTokens { center.removeObserver(token) }
    }

    var canRefresh: Bool { refreshAction != nil }

    func refreshIfStale(now: Date = Date()) {
        guard LimitsRefreshPolicy.shouldRefresh(
            now: now,
            appActive: isAppActive,
            hasRefreshAction: refreshAction != nil,
            lastRequestedAt: lastRequestedAt,
            reportGeneratedAt: report?.generatedAt,
            staleAfter: Self.staleAfter
        ) else { return }
        lastRequestedAt = now
        isLoading = true
        refreshAction?()
    }

    func apply(text: String, now: Date = Date()) {
        let parsed = LimitsReportParser.parse(text, now: now)
        isLoading = false
        lastError = parsed.isEmpty ? "No accounts reported" : nil
        guard !parsed.isEmpty else { return }
        report = parsed
        diskCache.save(parsed)
    }

    func fail(_ message: String) {
        isLoading = false
        lastError = message
    }

    /// Ticks at the staleness interval and lets `refreshIfStale` decide whether a request is
    /// actually worth sending — the interval itself is the throttle, this loop just wakes up.
    private func startBackgroundRefresh() {
        guard backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.staleAfter * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.refreshIfStale()
            }
        }
    }
}

/// The hover surface for account limits: every account, every window, native controls.
struct LimitsPopoverView: View {
    @ObservedObject private var limits = LimitsReportStore.shared
    /// Shown until the full report arrives, so the hover is never empty.
    let fallback: CodexAccountStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space12) {
            HStack(spacing: PatchworkTheme.space6) {
                PatchworkSectionHeader(title: "Usage limits")
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
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = limits.lastError, limits.report != nil {
                Text(error).font(PatchworkFont.micro).foregroundStyle(Color.patchworkOrange)
            }
        }
        .padding(PatchworkTheme.space16)
        .frame(width: 320)
        .onAppear { limits.refreshIfStale() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subscription usage limits")
    }
}

private struct LimitsAccountView: View {
    let account: LimitsAccount

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            HStack(spacing: PatchworkTheme.space6) {
                Text(account.name).font(PatchworkFont.captionEmphasis)
                if let plan = account.plan {
                    Text(plan)
                        .font(PatchworkFont.micro)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, PatchworkTheme.space4)
                        .patchworkInset(radius: PatchworkTheme.radiusSmall)
                }
                Spacer(minLength: 0)
            }
            if let email = account.email {
                Text(email).font(PatchworkFont.micro).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            if let error = account.error {
                Text(error).font(PatchworkFont.micro).foregroundStyle(Color.patchworkOrange).lineLimit(2)
            }

            ForEach(account.windows) { window in
                HStack(spacing: PatchworkTheme.space8) {
                    Text(window.label)
                        .font(PatchworkFont.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    ProgressView(value: Double(window.remainingPercent ?? 0), total: 100)
                        .progressViewStyle(.linear)
                        .tint(tint(window.remainingPercent))
                    Text(window.remainingPercent.map { "\($0)%" } ?? "—")
                        .font(PatchworkFont.micro.monospacedDigit())
                        .foregroundStyle(tint(window.remainingPercent))
                        .frame(width: 32, alignment: .trailing)
                }
                .help(window.detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(account.name) \(window.label)")
                .accessibilityValue(window.detail)
            }

            ForEach(account.notes, id: \.self) { note in
                Text(note).font(PatchworkFont.micro).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private func tint(_ remaining: Int?) -> Color {
        guard let remaining else { return .secondary }
        if remaining <= 15 { return .patchworkRed }
        if remaining <= 30 { return .patchworkOrange }
        return .secondary
    }
}
