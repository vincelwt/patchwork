import Darwin
import Foundation
import PatchworkKit

/// One `~/.pi/agent/patchwork-activity/*.json` heartbeat, written by the Pi extension whenever it
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
    var completionId: String? = nil
}

private final class DaemonHeartbeatFileCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: BoundedJSONFile.Fingerprint
        let heartbeat: Heartbeat?
    }

    private let lock = NSLock()
    private var directoryPath: String?
    private var entries: [String: Entry] = [:]
    private var catalog: BoundedJSONFiles.Catalog?

    func scan(directory: URL, logger: DaemonLogger?) -> [Heartbeat] {
        lock.lock()
        defer { lock.unlock() }
        let directoryPath = directory.standardizedFileURL.path
        if self.directoryPath != directoryPath {
            self.directoryPath = directoryPath
            entries.removeAll(keepingCapacity: false)
            catalog = nil
        }
        let scan = BoundedJSONFiles.scan(
            in: directory,
            limit: ActivityReader.maxFilesPerScan,
            maxBytes: ActivityReader.maxFileBytes,
            previous: catalog
        )
        catalog = scan.catalog
        let files = scan.catalog.files
        let retained = Set(files.map(\.path))
        entries = entries.filter { retained.contains($0.key) }

        let result = files.compactMap { file in
            if let cached = entries[file.path], cached.fingerprint == file.fingerprint {
                return cached.heartbeat
            }
            let heartbeat = BoundedJSONFiles.read(
                file, maxBytes: ActivityReader.maxFileBytes
            ).flatMap(ActivityReader.decode)
            entries[file.path] = Entry(fingerprint: file.fingerprint, heartbeat: heartbeat)
            if heartbeat == nil { logger?.warn("Skipping malformed heartbeat file \(file.url.lastPathComponent)") }
            return heartbeat
        }
        return result
    }
}

/// Reads and classifies heartbeat files. Never throws: a missing directory (no extension has
/// run yet), an unreadable file, or a malformed one are all just absent data, not an error.
enum ActivityReader {
    /// "Fresh" per the contract's "~10s" guidance.
    static let freshnessWindow: TimeInterval = 10
    static let maxFilesPerScan = 500
    static let maxFileBytes = 256 * 1_024
    private static let cache = DaemonHeartbeatFileCache()

    static func readHeartbeats(directory: URL = PatchworkPaths.activityDirectory, logger: DaemonLogger? = nil) -> [Heartbeat] {
        cache.scan(directory: directory, logger: logger)
    }

    fileprivate static func decode(_ data: Data) -> Heartbeat? {
        guard let value = try? PiJSONValue.decode(data),
              let object = value.objectValue,
              let sessionId = object["sessionId"]?.stringValue, !sessionId.isEmpty else {
            return nil
        }
        let sessionFile = object["sessionFile"]?.stringValue.flatMap { raw -> String? in
            guard !raw.isEmpty, (raw as NSString).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        return Heartbeat(
            sessionId: sessionId,
            sessionFile: sessionFile,
            cwd: object["cwd"]?.stringValue,
            pid: object["pid"]?.intValue.flatMap { Int32(exactly: $0) },
            state: object["state"]?.stringValue ?? "idle",
            startedAt: object["startedAt"]?.stringValue.flatMap(PatchworkDate.date(from:)),
            updatedAt: object["updatedAt"]?.stringValue.flatMap(PatchworkDate.date(from:)) ?? .distantPast,
            completionId: object["completionId"]?.stringValue
        )
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
