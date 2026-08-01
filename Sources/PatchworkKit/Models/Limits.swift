import Foundation

/// One usage window inside an account's `/limits` report, e.g. "5h" or "7d".
public struct LimitsWindowData: Codable, Hashable, Sendable {
    public var label: String
    public var remainingPercent: Int?
    public var resets: String?
    /// Everything the extension printed for this window, verbatim, for a client that wants to
    /// show more than the parsed fields.
    public var detail: String

    public init(label: String, remainingPercent: Int?, resets: String?, detail: String) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resets = resets
        self.detail = detail
    }
}

public struct LimitsAccountData: Codable, Hashable, Sendable {
    public var name: String
    public var email: String?
    public var plan: String?
    public var windows: [LimitsWindowData]
    public var notes: [String]
    public var error: String?

    public init(name: String, email: String? = nil, plan: String? = nil, windows: [LimitsWindowData] = [], notes: [String] = [], error: String? = nil) {
        self.name = name
        self.email = email
        self.plan = plan
        self.windows = windows
        self.notes = notes
        self.error = error
    }
}

/// The `"report"` object in `GET /v1/limits`.
public struct LimitsReportData: Codable, Hashable, Sendable {
    public var accounts: [LimitsAccountData]
    public init(accounts: [LimitsAccountData]) { self.accounts = accounts }
    public var isEmpty: Bool { accounts.isEmpty }
}

/// `GET /v1/limits → {"report":{…},"generatedAt":"…","stale":false}`.
public struct LimitsSnapshot: Codable, Sendable {
    public var report: LimitsReportData
    public var generatedAt: Date
    /// True once a cached report has aged past what the daemon considers fresh, e.g. because no
    /// thread has run `/limits` recently. Still the best data available.
    public var stale: Bool

    public init(report: LimitsReportData, generatedAt: Date, stale: Bool) {
        self.report = report
        self.generatedAt = generatedAt
        self.stale = stale
    }
}

/// Turns the codex-limits extension's indented text block into structured data. Ported from the
/// app's `LimitsReportParser` (same algorithm, renamed types — `LimitsReport`/`LimitsAccount`/
/// `LimitsWindow` already exist as AppKit-facing view models in `Sources/Patchwork`, so this
/// package uses the `…Data` suffix to stay a safe, unambiguous import for that target later).
public enum LimitsTextParser {
    public static func parse(_ text: String, now: Date = Date()) -> LimitsReportData {
        var accounts: [LimitsAccountData] = []
        var current: LimitsAccountData?

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
                current = LimitsAccountData(name: trimmed)
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

        // Bounded, matching the app's rendering budget: a runaway report must not become an
        // unbounded JSON payload either.
        let limited = accounts.prefix(8).map { account -> LimitsAccountData in
            var value = account
            value.windows = Array(value.windows.prefix(8))
            value.notes = Array(value.notes.prefix(8))
            return value
        }
        return LimitsReportData(accounts: Array(limited))
    }

    private static func window(label: String, value: String) -> LimitsWindowData {
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
        return LimitsWindowData(
            label: label.replacingOccurrences(of: "_", with: " ").capitalizedFirstWordPatchwork,
            remainingPercent: remaining,
            resets: resets,
            detail: value
        )
    }
}

private extension String {
    /// Local copy of the app's `capitalizedFirstWord` (private there): capitalises only the
    /// first character, leaving the rest — including existing capitals in acronyms — untouched.
    var capitalizedFirstWordPatchwork: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
