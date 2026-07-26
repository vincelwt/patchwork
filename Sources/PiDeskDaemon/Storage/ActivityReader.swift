import Darwin
import Foundation
import PiDeskKit

/// One `~/.pi/agent/desktop-activity/*.json` heartbeat, written by the Pi extension whenever it
/// starts or updates a run. Fields per the contract: `sessionId`, `sessionFile`, `cwd`, `pid`,
/// `state` ("running"/"idle"), `startedAt`, `updatedAt`.
struct Heartbeat: Sendable {
    var sessionId: String
    var sessionFile: String?
    var cwd: String?
    var pid: Int32?
    var state: String
    var startedAt: Date?
    var updatedAt: Date
}

/// Reads and classifies heartbeat files. Never throws: a missing directory (no extension has
/// run yet), an unreadable file, or a malformed one are all just absent data, not an error.
enum ActivityReader {
    /// "Fresh" per the contract's "~10s" guidance.
    static let freshnessWindow: TimeInterval = 10

    static func readHeartbeats(directory: URL = PiDeskPaths.activityDirectory, logger: DaemonLogger? = nil) -> [Heartbeat] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return [] // directory does not exist yet, or is unreadable: degrade to "nothing running"
        }

        var heartbeats: [Heartbeat] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let data = manager.contents(atPath: url.path),
                  let value = try? PiJSONValue.decode(data),
                  let object = value.objectValue,
                  let sessionId = object["sessionId"]?.stringValue, !sessionId.isEmpty else {
                logger?.warn("Skipping malformed heartbeat file \(url.lastPathComponent)")
                continue
            }
            heartbeats.append(Heartbeat(
                sessionId: sessionId,
                sessionFile: object["sessionFile"]?.stringValue,
                cwd: object["cwd"]?.stringValue,
                pid: object["pid"]?.intValue.map(Int32.init),
                state: object["state"]?.stringValue ?? "idle",
                startedAt: object["startedAt"]?.stringValue.flatMap(PiDeskDate.date(from:)),
                updatedAt: object["updatedAt"]?.stringValue.flatMap(PiDeskDate.date(from:)) ?? .distantPast
            ))
        }
        return heartbeats
    }

    /// A session counts as running only when all three hold: the file says so, the write is
    /// recent, and the pid is actually alive \u2014 a stale heartbeat left behind by a killed
    /// process must never be reported as a live run.
    static func isRunning(_ heartbeat: Heartbeat, now: Date = Date()) -> Bool {
        guard heartbeat.state == "running" else { return false }
        guard now.timeIntervalSince(heartbeat.updatedAt) <= freshnessWindow else { return false }
        guard let pid = heartbeat.pid else { return false }
        return isProcessAlive(pid: pid)
    }

    /// Signal 0: no signal is delivered, only existence/permission is checked \u2014 the standard
    /// POSIX liveness probe. `EPERM` still means a process with that pid exists.
    static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
