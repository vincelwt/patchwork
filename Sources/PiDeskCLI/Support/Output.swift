import Foundation

/// Every place a command writes output goes through here, so tests can capture it and `--json`
/// / `--quiet` / colour rules are applied in exactly one place.
final class OutputSink {
    private let writeOut: (String) -> Void
    private let writeErr: (String) -> Void
    let quiet: Bool
    let jsonOutput: Bool
    let colorEnabled: Bool

    init(writeOut: @escaping (String) -> Void, writeErr: @escaping (String) -> Void, quiet: Bool, jsonOutput: Bool, colorEnabled: Bool) {
        self.writeOut = writeOut
        self.writeErr = writeErr
        self.quiet = quiet
        self.jsonOutput = jsonOutput
        self.colorEnabled = colorEnabled
    }

    /// Requested data/results: always printed, even under --quiet.
    func line(_ text: String) { writeOut(text + "\n") }

    /// Incidental/progress text (e.g. "waiting for run to finish…"). Always stderr, never stdout
    /// — so it can never corrupt `--json`/NDJSON output — and suppressed entirely by --quiet.
    func info(_ text: String) {
        guard !quiet else { return }
        writeErr(text + "\n")
    }

    func errorLine(_ text: String) { writeErr(text + "\n") }

    func json(_ value: some Encodable) {
        writeOut(JSONFormatting.render(value, pretty: true) + "\n")
    }

    /// One compact JSON object per line (NDJSON), for `threads watch --json` / `daemon logs --json`.
    func jsonLine(_ value: some Encodable) {
        writeOut(JSONFormatting.render(value, pretty: false) + "\n")
    }

    func rawJSONLine(_ value: JSONValue) {
        writeOut(JSONFormatting.render(value, pretty: false) + "\n")
    }
}

enum JSONFormatting {
    static func render(_ value: some Encodable, pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

enum ANSI {
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
}

func colorize(_ text: String, _ code: String, enabled: Bool) -> String {
    enabled ? "\(code)\(text)\(ANSI.reset)" : text
}

/// Aligned, colour-free-by-default column rendering for human output. `String.padding` truncates
/// if asked to pad shorter than the input, so widths are always computed as a max first.
enum Table {
    static func render(headers: [String], rows: [[String]]) -> [String] {
        guard !rows.isEmpty else { return [] }
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func padded(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        return [padded(headers)] + rows.map(padded)
    }
}
