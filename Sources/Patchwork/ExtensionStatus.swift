import Foundation

// MARK: - ANSI

enum ANSI {
    /// Pi extensions colour their footer text for the TUI. Every status string is stripped
    /// before it reaches the desktop UI, including OSC sequences and stray control characters.
    static func strip(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var iterator = Array(text)
        var index = 0

        while index < iterator.count {
            let character = iterator[index]
            guard character == "\u{1B}" else {
                // Drop other C0 control characters except tab/newline.
                if character.isASCII, let ascii = character.asciiValue, ascii < 0x20, ascii != 0x09, ascii != 0x0A {
                    index += 1
                    continue
                }
                output.append(character)
                index += 1
                continue
            }

            index += 1
            guard index < iterator.count else { break }
            let introducer = iterator[index]

            if introducer == "[" {
                // CSI: parameters and intermediates, terminated by a final byte @-~.
                index += 1
                while index < iterator.count {
                    let value = iterator[index]
                    index += 1
                    if let ascii = value.asciiValue, ascii >= 0x40, ascii <= 0x7E { break }
                }
                continue
            }

            if introducer == "]" {
                // OSC: terminated by BEL or ESC \.
                index += 1
                while index < iterator.count {
                    let value = iterator[index]
                    if value == "\u{07}" { index += 1; break }
                    if value == "\u{1B}", index + 1 < iterator.count, iterator[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }

            // Two-character escape (e.g. ESC ( B): drop the introducer.
            index += 1
        }

        iterator.removeAll()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Parsed statuses

/// One remaining-quota window from `codex-account`, e.g. `5h:78%`.
struct CodexUsageWindow: Equatable, Hashable, Sendable {
    let label: String
    /// Percentage of the window still available (the extension already inverts "used").
    let remainingPercent: Int
}

/// `<email> 5h:78% 7d:57% reset×2:12h`
struct CodexAccountStatus: Equatable, Sendable {
    let account: String
    let windows: [CodexUsageWindow]
    let bankedResetCount: Int?
    let bankedResetExpiry: String?

    /// The tightest window drives the compact label and the warning state.
    var tightestWindow: CodexUsageWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var isLow: Bool { (tightestWindow?.remainingPercent ?? 100) <= 15 }
    var isWarning: Bool { (tightestWindow?.remainingPercent ?? 100) <= 30 }

    /// `78%` style compact suffix for the status bar.
    var compactRemaining: String? {
        guard let window = tightestWindow else { return nil }
        return "\(window.label) \(window.remainingPercent)%"
    }

    var compactReset: String? {
        guard let count = bankedResetCount, count > 0 else { return nil }
        return "reset×\(count)" + (bankedResetExpiry.map { ":\($0)" } ?? "")
    }

    /// Exact extension-style summary used where percentages and reset detail must stay visible.
    var compactUsage: String? {
        let parts = windows.map { "\($0.label):\($0.remainingPercent)%" } + [compactReset].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var detailLines: [String] {
        var lines = [account]
        for window in windows { lines.append("\(window.label) window · \(window.remainingPercent)% remaining") }
        if let count = bankedResetCount, count > 0 {
            let expiry = bankedResetExpiry.map { ", first expires in \($0)" } ?? ""
            lines.append("\(count) banked reset\(count == 1 ? "" : "s")\(expiry)")
        }
        return lines
    }
}

/// The four modes registered by the `mode` extension.
enum PiMode: String, CaseIterable, Identifiable, Sendable {
    case xfast, fast, smart, ultra

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xfast: "xfast"
        case .fast: "fast"
        case .smart: "smart"
        case .ultra: "ultra"
        }
    }

    var detail: String {
        switch self {
        case .xfast: "Terra · xhigh · no subagents"
        case .fast: "Sol · xhigh · no subagents"
        case .smart: "Sol · xhigh · subagents"
        case .ultra: "Sol · max · subagents"
        }
    }
}

/// `fast` / `fast (inactive)` from the codex-fast extension.
struct FastPriorityStatus: Equatable, Sendable {
    let isActive: Bool
    let raw: String
}

enum ExtensionStatusParser {
    static let codexAccountKey = "codex-account"
    static let modeKey = "mode"
    static let fastPriorityKey = "fast-priority"
    static let subagentsKey = "subagents"
    static let providerQueueKey = "codex-provider-queue"

    /// Runtime-local statuses must never leak into another conversation through the cache.
    static let ephemeralKeys: Set<String> = [subagentsKey, providerQueueKey]

    /// Keys rendered by dedicated status-bar controls rather than the generic chip list.
    static let specialKeys: Set<String> = [codexAccountKey, modeKey, fastPriorityKey, providerQueueKey]

    /// `"<email> 5h:78% 7d:57% reset×2:12h"`. The leading token is the account name/email;
    /// `label:NN%` tokens are remaining windows; `reset×N[:time]` is optional.
    static func codexAccount(_ rawValue: String) -> CodexAccountStatus? {
        let value = ANSI.strip(rawValue)
        guard !value.isEmpty else { return nil }
        // The extension emits this before the usage endpoint answers; treat it as "not yet
        // known" rather than inventing an account literally named "loading".
        if value.lowercased().hasPrefix("codex account: loading") { return nil }

        var tokens = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var windows: [CodexUsageWindow] = []
        var resetCount: Int?
        var resetExpiry: String?
        var accountTokens: [String] = []
        var sawStructuredToken = false

        // The account name may contain spaces, so consume leading tokens until the first
        // structured token appears.
        for token in tokens {
            if let window = parseWindow(token) {
                windows.append(window)
                sawStructuredToken = true
                continue
            }
            if let reset = parseReset(token) {
                resetCount = reset.count
                resetExpiry = reset.expiry
                sawStructuredToken = true
                continue
            }
            if sawStructuredToken { continue }
            accountTokens.append(token)
        }
        tokens.removeAll()

        let account = accountTokens.joined(separator: " ")
        // Real usage data (a window) is trustworthy even without a name. Free text alone —
        // "loading", "signed out", a future diagnostic message the extension has not sent
        // before — is not distinguishable from an account name unless it looks like one (an
        // email, the documented format). Anything else degrades to nil rather than showing
        // status text as though it were an identity.
        guard !windows.isEmpty || account.contains("@") else { return nil }
        return CodexAccountStatus(
            account: account.isEmpty ? "Codex account" : account,
            windows: windows,
            bankedResetCount: resetCount,
            bankedResetExpiry: resetExpiry
        )
    }

    /// `label:NN%` where the label may itself contain a colon-free window name.
    private static func parseWindow(_ token: String) -> CodexUsageWindow? {
        guard token.hasSuffix("%"), let separator = token.lastIndex(of: ":") else { return nil }
        let label = String(token[token.startIndex..<separator])
        let percentText = token[token.index(after: separator)...].dropLast()
        guard !label.isEmpty, !label.hasPrefix("reset"), let percent = Int(percentText) else { return nil }
        return CodexUsageWindow(label: label, remainingPercent: max(0, min(100, percent)))
    }

    /// `reset×2:12h` or `reset×1`. `x` is accepted as well as `×`.
    private static func parseReset(_ token: String) -> (count: Int, expiry: String?)? {
        let lowered = token.lowercased()
        guard lowered.hasPrefix("reset") else { return nil }
        var body = String(token.dropFirst("reset".count))
        if body.hasPrefix("×") || body.hasPrefix("x") || body.hasPrefix("X") { body.removeFirst() }
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let count = Int(first) else { return nil }
        let expiry = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (count, expiry)
    }

    /// `mode:ultra`
    static func mode(_ rawValue: String) -> PiMode? {
        let value = ANSI.strip(rawValue).lowercased()
        guard !value.isEmpty else { return nil }
        let candidate = value.hasPrefix("mode:")
            ? String(value.dropFirst("mode:".count)).trimmingCharacters(in: .whitespaces)
            : value
        return PiMode(rawValue: candidate)
    }

    /// `fast` or `fast (inactive)`
    static func fastPriority(_ rawValue: String) -> FastPriorityStatus? {
        let value = ANSI.strip(rawValue)
        guard !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        guard lowered.contains("fast") else { return nil }
        return FastPriorityStatus(isActive: !lowered.contains("inactive"), raw: value)
    }

    /// Unknown keys still show up so a newly installed extension is never invisible.
    static func generic(key: String, value: String) -> String? {
        let clean = ANSI.strip(value)
        guard !clean.isEmpty else { return nil }
        return clean
    }
}

/// What actually belongs in the account chip: fresh wire data when `codex-account` currently
/// parses, or the last value that *did* parse (kept while the extension is loading or in a
/// shape this build has never seen), or nothing at all the first time an install has never
/// reported an account. Pure and independent of any shared cache, so it is fully testable with
/// explicit inputs instead of the process-wide memory below.
enum CodexAccountResolution {
    struct Resolved: Equatable {
        let status: CodexAccountStatus
        /// False once this is served from memory rather than the current wire value.
        let isStale: Bool
    }

    static func resolve(raw: String?, previousGood: CodexAccountStatus?) -> Resolved? {
        if let raw, let parsed = ExtensionStatusParser.codexAccount(raw) {
            return Resolved(status: parsed, isStale: false)
        }
        guard let previousGood else { return nil }
        return Resolved(status: previousGood, isStale: true)
    }
}

/// Cross-render memory for the last codex-account payload that actually parsed. A fresh
/// `ExtensionStatusModel` is rebuilt on every status change, so this is the one piece of state
/// that survives the gap while the extension is between updates (e.g. right after a runtime
/// attaches, before its first real status arrives) — shared across the main window and the menu
/// bar, which both render an account chip from independent view hierarchies.
final class CodexAccountMemory: @unchecked Sendable {
    static let shared = CodexAccountMemory()

    private(set) var lastGood: CodexAccountStatus?

    /// Non-shared instances exist purely so tests can exercise the fallback without depending on
    /// (or polluting) global state.
    init(lastGood: CodexAccountStatus? = nil) {
        self.lastGood = lastGood
    }

    func remember(_ status: CodexAccountStatus) {
        lastGood = status
    }
}

/// The desktop's view of every extension status, live or cached, ready for the status bar.
struct ExtensionStatusModel: Equatable {
    /// Raw (already ANSI-stripped) values keyed by status key.
    var values: [String: String] = [:]
    /// False when the values come from the persisted cache rather than an attached runtime.
    var isLive = false

    /// Resolves against the shared memory: fresh data when codex-account currently parses, else
    /// the last known good account (see `codexAccountIsStale`), else nil the first time this
    /// install has ever seen the extension.
    var codexAccount: CodexAccountStatus? {
        resolvedCodexAccount(memory: CodexAccountMemory.shared)?.status
    }

    /// True once `codexAccount` is the last known value rather than what the wire says right
    /// now — the chip should read as "last known", not as a live number.
    var codexAccountIsStale: Bool {
        resolvedCodexAccount(memory: CodexAccountMemory.shared)?.isStale ?? false
    }

    /// Exposed with an explicit memory parameter so tests resolve deterministically instead of
    /// through the shared singleton.
    func resolvedCodexAccount(memory: CodexAccountMemory) -> CodexAccountResolution.Resolved? {
        let resolved = CodexAccountResolution.resolve(
            raw: values[ExtensionStatusParser.codexAccountKey],
            previousGood: memory.lastGood
        )
        if let resolved, !resolved.isStale { memory.remember(resolved.status) }
        return resolved
    }

    var mode: PiMode? {
        values[ExtensionStatusParser.modeKey].flatMap(ExtensionStatusParser.mode)
    }

    /// The extension removes its status key when fast priority is off, but the toggle must remain.
    var fastPriority: FastPriorityStatus {
        values[ExtensionStatusParser.fastPriorityKey].flatMap(ExtensionStatusParser.fastPriority)
            ?? FastPriorityStatus(isActive: false, raw: "fast (inactive)")
    }

    /// Everything the status bar renders as a plain chip, in stable key order.
    var genericChips: [(key: String, value: String)] {
        values.keys.sorted()
            .filter { !ExtensionStatusParser.specialKeys.contains($0) }
            .compactMap { key in
                guard let value = ExtensionStatusParser.generic(key: key, value: values[key] ?? "") else { return nil }
                return (key, value)
            }
    }

    var isEmpty: Bool { values.isEmpty }
}
