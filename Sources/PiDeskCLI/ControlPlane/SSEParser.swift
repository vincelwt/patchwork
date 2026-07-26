import Foundation

/// Incremental SSE line parser, kept separate from the socket code so it's testable with plain
/// strings. Per docs/daemon-api.md: `event: name` / `data: json` pairs separated by a blank line,
/// `: keep-alive` comments ignored, unknown event names passed through untouched.
struct SSEParser {
    private var pendingName: String?
    private var pendingData: [String] = []

    /// Feed one line (no trailing newline). Returns a decoded event when `line` is the blank line
    /// that terminates a message; returns nil while a message is still accumulating, for a
    /// comment line, or when a "data:" line isn't valid JSON (malformed events are dropped, not
    /// fatal — a stream must survive one bad line).
    mutating func feed(_ line: String) -> ControlPlaneEvent? {
        if line.isEmpty {
            defer { pendingName = nil; pendingData = [] }
            guard !pendingData.isEmpty, let data = try? JSONValue.decode(Data(pendingData.joined(separator: "\n").utf8)) else {
                return nil
            }
            return ControlPlaneEvent(name: pendingName ?? "message", data: data)
        }
        if line.hasPrefix(":") { return nil } // comment / keep-alive
        if let value = field("event:", in: line) {
            pendingName = value
        } else if let value = field("data:", in: line) {
            pendingData.append(value)
        }
        // Other SSE fields (id:, retry:) aren't part of the contract; ignored rather than rejected.
        return nil
    }

    private func field(_ prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }
}
