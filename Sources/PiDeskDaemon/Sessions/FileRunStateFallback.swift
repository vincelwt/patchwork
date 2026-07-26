import Foundation
import PiDeskKit

/// Run state for sessions that predate the heartbeat extension, or ran while it was disabled.
///
/// The app applies exactly these rules when a session has no heartbeat, so the daemon, the CLI,
/// the web remote, and the window all report the same thing. Without this the daemon called
/// every pre-heartbeat session idle while the window correctly showed it running.
enum FileRunStateFallback {
    /// A write this recent, with a non-terminal last entry, means a turn is in flight.
    static let staleAfter: TimeInterval = 15
    /// Nothing older than this is running, whatever the entry says.
    static let idleAfter: TimeInterval = 90
    static let tailByteLimit = 64 * 1_024

    static let terminalStopReasons: Set<String> = ["stop", "length", "error", "aborted"]

    /// `true` when the file alone says a turn is in flight.
    static func isRunning(sessionFile: URL, now: Date = Date()) -> Bool {
        let fresh = URL(fileURLWithPath: sessionFile.path)
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        if age > idleAfter { return false }
        guard let entry = lastEntry(inTailOf: fresh) else { return false }
        return isRunning(lastEntry: entry, age: age)
    }

    /// Pure rule, kept separate so it can be tested without touching the disk.
    static func isRunning(lastEntry entry: PiJSONValue, age: TimeInterval) -> Bool {
        if age > idleAfter { return false }
        let type = entry["type"]?.stringValue
        if type == "bashExecution" { return age <= staleAfter }
        guard type == "message", let message = entry["message"] else { return false }

        switch message["role"]?.stringValue {
        case "user", "toolResult", "bashExecution":
            // Pi has just been handed work; only a stalled file says otherwise.
            return age <= staleAfter
        case "assistant":
            let stopReason = message["stopReason"]?.stringValue
            // A terminal stop reason wins even for a write from a moment ago.
            if let stopReason, terminalStopReasons.contains(stopReason) { return false }
            if stopReason == "toolUse" { return age <= staleAfter }
            return false
        default:
            return false
        }
    }

    /// Reads a bounded tail and returns the last decodable record, tolerating a partial line.
    static func lastEntry(inTailOf url: URL) -> PiJSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(tailByteLimit) ? end - UInt64(tailByteLimit) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let tail = try? handle.read(upToCount: tailByteLimit) else { return nil }

        for line in tail.split(separator: 0x0A, omittingEmptySubsequences: true).reversed().prefix(4) {
            var record = Data(line)
            if record.last == 0x0D { record.removeLast() }
            guard !record.isEmpty, let value = try? PiJSONValue.decode(record) else { continue }
            return value
        }
        return nil
    }
}
