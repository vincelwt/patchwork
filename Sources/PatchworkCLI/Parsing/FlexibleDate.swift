import Foundation

/// Accepts both strict ISO-8601 (with a "Z" or numeric offset, as the API uses) and a friendly
/// local datetime with no zone attached, for `--at`. The friendly forms are interpreted in
/// `timeZone` (the caller's local zone by default) and converted to an absolute instant before
/// being sent to the daemon — the wire payload is always a proper ISO-8601 instant.
enum FlexibleDate {
    static func parse(_ raw: String, timeZone: TimeZone = .current) throws -> Date {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            throw UsageError.invalidValue(flag: "date", value: raw, reason: "empty")
        }

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFraction.date(from: text) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }

        // Friendly forms carry no zone, so `timeZone` decides what instant they mean.
        for pattern in [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }

        throw UsageError.invalidValue(
            flag: "date",
            value: raw,
            reason: "expected ISO-8601 (2026-07-27T09:00:00Z) or a local datetime (2026-07-27T09:00 / \"2026-07-27 09:00\")"
        )
    }

    /// The wire format the API examples use: "2026-07-27T09:00:00Z".
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Best-effort parse of a server timestamp for human display. Never throws: an unparseable
    /// or future-format timestamp just falls back to the raw string, per the app's
    /// forward-compatibility rule for unknown/evolving wire shapes.
    static func displayLocal(_ raw: String?) -> String {
        guard let raw, let date = try? parse(raw, timeZone: .init(identifier: "UTC") ?? .current) else {
            return raw ?? "—"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
