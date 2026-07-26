import Darwin
import Foundation

/// One heartbeat file the `pi-desktop-activity` extension maintains at
/// `~/.pi/agent/desktop-activity/<sessionId>.json`. Decoding is all-or-nothing: a malformed or
/// partial record (a torn read racing the extension's own rename, a hand-edited file, a future
/// schema) is simply absent rather than guessed at, so the monitor always has a clean fallback.
struct ActivityHeartbeat: Decodable, Equatable, Sendable {
    let sessionId: String
    var sessionFile: String?
    var sessionDir: String?
    let pid: Int32
    let state: String
    var updatedAt: String
    var preview: String?
    var stopReason: String?

    /// The session JSONL path this heartbeat describes, reconstructed from `sessionDir` + id
    /// when the extension could not resolve a concrete file (an in-memory session).
    var resolvedSessionPath: String? {
        if let sessionFile, !sessionFile.isEmpty {
            return URL(fileURLWithPath: sessionFile).standardizedFileURL.path
        }
        guard let sessionDir, !sessionDir.isEmpty else { return nil }
        return URL(fileURLWithPath: sessionDir).appendingPathComponent("\(sessionId).jsonl").standardizedFileURL.path
    }
}

/// Pure running/idle verdict from one heartbeat record. Three independent signals must all
/// agree — this is deliberately conjunctive (AND, not OR) so any single stale or wrong field
/// can only ever make a session look *less* active, never falsely running.
enum ActivityHeartbeatClassifier {
    /// The extension refreshes `updatedAt` on a ~2s interval while running; 10s is several
    /// missed beats, not one scheduling hiccup, so a crashed process's stale "running" heartbeat
    /// stops being trusted well before a human would notice anything is wrong.
    static let freshnessWindow: TimeInterval = 10

    static func isRunning(
        _ heartbeat: ActivityHeartbeat,
        now: Date,
        isProcessAlive: (Int32) -> Bool = ActivityHeartbeatClassifier.isProcessAlive
    ) -> Bool {
        guard heartbeat.state == "running" else { return false }
        guard let updatedAt = Date.piDate(heartbeat.updatedAt) else { return false }
        guard now.timeIntervalSince(updatedAt) <= freshnessWindow else { return false }
        return isProcessAlive(heartbeat.pid)
    }

    /// A direct `kill(pid, 0)` liveness probe — not a `ps`/`lsof` shell-out. `ESRCH` means the
    /// process is gone; `EPERM` still means it exists (just owned by someone else), which in
    /// practice never happens for a heartbeat this app itself is allowed to read.
    static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// Reads the small heartbeat directory. One file per recently-active session in practice, so a
/// full directory scan every tick is cheap; still bounded defensively against a runaway count.
enum ActivityHeartbeatStore {
    static let maxFilesPerScan = 500

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/desktop-activity", isDirectory: true)
    }

    /// Grouped by resolved session-file path. Multiple Pi processes can attach to the same
    /// session, so each writer is retained; the monitor reports running when any writer is live.
    /// A missing directory (extension never installed, nothing has run yet) is simply empty.
    static func scan(directory: URL) -> [String: [ActivityHeartbeat]] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [String: [ActivityHeartbeat]] = [:]
        for url in entries.prefix(maxFilesPerScan) where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let heartbeat = try? JSONDecoder().decode(ActivityHeartbeat.self, from: data),
                  let path = heartbeat.resolvedSessionPath else { continue }
            result[path, default: []].append(heartbeat)
        }
        return result
    }
}
