import Foundation
import PiDeskKit

/// Run state for sessions that predate the heartbeat extension, or ran while it was disabled.
///
/// The app applies exactly these rules when a session has no heartbeat, so the daemon, the CLI,
/// the web remote, and the window all report the same thing. Without this the daemon called
/// every pre-heartbeat session idle while the window correctly showed it running.
enum FileRunStateFallback {
    /// A write this recent, with a non-terminal last entry, means a turn is in flight.
    static let staleAfter = SessionFileActivityClassifier.staleNonTerminalWindow
    /// Nothing older than this is running, whatever the entry says.
    static let idleAfter = SessionFileActivityClassifier.idleWindow
    static let tailByteLimit = SessionFileActivityClassifier.tailByteLimit

    static let terminalStopReasons = SessionFileActivityClassifier.terminalStopReasons

    /// `true` when the file alone says a turn is in flight.
    static func isRunning(
        sessionFile: URL, agent: AgentKind = .pi, now: Date = Date()
    ) -> Bool {
        let fresh = URL(fileURLWithPath: sessionFile.path)
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else { return false }
        return isRunning(
            sessionFile: fresh, agent: agent, modifiedAt: modifiedAt, now: now
        )
    }

    /// Variant for catalog/activity callers that already obtained the transcript mtime with a
    /// direct stat. This avoids a second metadata lookup while preserving the same bounded tail
    /// classification.
    static func isRunning(
        sessionFile: URL, agent: AgentKind = .pi, modifiedAt: Date, now: Date
    ) -> Bool {
        SessionFileActivityClassifier.isRunning(
            sessionFile: sessionFile, agent: agent, modifiedAt: modifiedAt, now: now
        )
    }

    /// Pure rule, kept separate so it can be tested without touching the disk.
    static func isRunning(lastEntry entry: PiJSONValue, age: TimeInterval) -> Bool {
        SessionFileActivityClassifier.classify(lastEntry: entry, age: age) == .running
    }

    /// Reads a bounded tail and returns the last decodable record, tolerating a partial line.
    static func lastEntry(inTailOf url: URL) -> PiJSONValue? {
        SessionFileActivityClassifier.readTail(at: url).flatMap {
            SessionFileActivityClassifier.lastEntry(inTail: $0)
        }
    }
}
