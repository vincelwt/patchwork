import Foundation

/// Validates the standard 5-field cron form the contract specifies: minute hour day-of-month
/// month day-of-week, with `*`, `,`, `-`, `*/n`, and named months/days. This is syntax
/// validation only (no next-run computation) — enough to reject a broken `--cron` at the CLI
/// layer instead of letting it reach the daemon and "silently never fire" (docs/daemon-api.md).
enum CronExpression {
    private struct Field {
        let name: String
        let min: Int
        let max: Int
        let names: [String: Int]
    }

    private static let fields: [Field] = [
        Field(name: "minute", min: 0, max: 59, names: [:]),
        Field(name: "hour", min: 0, max: 23, names: [:]),
        Field(name: "day-of-month", min: 1, max: 31, names: [:]),
        Field(name: "month", min: 1, max: 12, names: [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]),
        Field(name: "day-of-week", min: 0, max: 7, names: [
            "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6
        ])
    ]

    /// Returns the expression with normalized whitespace on success.
    @discardableResult
    static func validate(_ expression: String) throws -> String {
        let tokens = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count == 5 else {
            throw UsageError.invalidValue(
                flag: "--cron",
                value: expression,
                reason: "expected 5 fields (minute hour day-of-month month day-of-week), got \(tokens.count)"
            )
        }
        for (field, token) in zip(fields, tokens) {
            try validate(field: field, text: token, original: expression)
        }
        return tokens.joined(separator: " ")
    }

    private static func validate(field: Field, text: String, original: String) throws {
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            try validateItem(field: field, item: String(item), original: original)
        }
    }

    private static func validateItem(field: Field, item: String, original: String) throws {
        guard !item.isEmpty else { throw invalid(field: field, original: original) }
        let stepParts = item.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard stepParts.count <= 2 else { throw invalid(field: field, original: original) }
        if stepParts.count == 2 {
            guard let step = Int(stepParts[1]), step > 0 else { throw invalid(field: field, original: original) }
        }
        let base = String(stepParts[0])
        if base == "*" { return }
        if let dash = base.firstIndex(of: "-") {
            let low = try resolve(field: field, token: String(base[base.startIndex..<dash]), original: original)
            let high = try resolve(field: field, token: String(base[base.index(after: dash)...]), original: original)
            guard low <= high else { throw invalid(field: field, original: original) }
            return
        }
        _ = try resolve(field: field, token: base, original: original)
    }

    private static func resolve(field: Field, token: String, original: String) throws -> Int {
        if let named = field.names[token.lowercased()] { return named }
        guard let value = Int(token) else { throw invalid(field: field, original: original) }
        guard value >= field.min, value <= field.max else {
            throw UsageError.invalidValue(
                flag: "--cron",
                value: original,
                reason: "\(field.name) value \(value) is out of range \(field.min)-\(field.max)"
            )
        }
        return value
    }

    private static func invalid(field: Field, original: String) -> UsageError {
        .invalidValue(flag: "--cron", value: original, reason: "invalid \(field.name) field")
    }
}
