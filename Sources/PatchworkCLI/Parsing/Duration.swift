import Foundation

/// Parses human durations like "45s", "15m", "2h", "1d", or a compound "1h30m". Units require an
/// explicit suffix on purpose — a bare "45" is rejected rather than guessing seconds, per the
/// contract's "reject ambiguity loudly" rule for trigger flags.
func parseDuration(_ raw: String) throws -> TimeInterval {
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
        throw UsageError.invalidValue(flag: "duration", value: raw, reason: "empty")
    }

    var total: Double = 0
    var numberBuffer = ""
    var sawSegment = false
    var index = text.startIndex

    while index < text.endIndex {
        let ch = text[index]
        if ch.isNumber || ch == "." {
            numberBuffer.append(ch)
            index = text.index(after: index)
            continue
        }
        guard !numberBuffer.isEmpty, let value = Double(numberBuffer) else {
            throw UsageError.invalidValue(flag: "duration", value: raw, reason: "\"\(ch)\" is not a valid unit (use s, m, h, or d)")
        }
        let unitSeconds: Double
        switch ch {
        case "s": unitSeconds = 1
        case "m": unitSeconds = 60
        case "h": unitSeconds = 3600
        case "d": unitSeconds = 86400
        default:
            throw UsageError.invalidValue(flag: "duration", value: raw, reason: "\"\(ch)\" is not a valid unit (use s, m, h, or d)")
        }
        total += value * unitSeconds
        numberBuffer = ""
        sawSegment = true
        index = text.index(after: index)
    }

    guard numberBuffer.isEmpty else {
        throw UsageError.invalidValue(flag: "duration", value: raw, reason: "missing a unit after \(numberBuffer) (use s, m, h, or d)")
    }
    guard sawSegment else {
        throw UsageError.invalidValue(flag: "duration", value: raw, reason: "not a duration")
    }
    guard total > 0 else {
        throw UsageError.invalidValue(flag: "duration", value: raw, reason: "must be greater than zero")
    }
    guard total <= 366 * 86400 else {
        throw UsageError.invalidValue(flag: "duration", value: raw, reason: "longer than a year; double-check the unit")
    }
    return total
}

/// Renders seconds back into the compact form `parseDuration` accepts, for human display
/// (e.g. schedule listings). Not a strict inverse — it just picks the coarsest useful units.
func formatDuration(_ seconds: Double) -> String {
    var remaining = Int(seconds.rounded())
    guard remaining > 0 else { return "0s" }
    let days = remaining / 86_400; remaining %= 86_400
    let hours = remaining / 3600; remaining %= 3600
    let minutes = remaining / 60; remaining %= 60
    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 { parts.append("\(minutes)m") }
    if remaining > 0 || parts.isEmpty { parts.append("\(remaining)s") }
    return parts.joined()
}
