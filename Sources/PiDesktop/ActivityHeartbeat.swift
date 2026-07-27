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
    var completionId: String? = nil

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

/// Reuses decoded heartbeats until their file fingerprint changes. A busy day can leave hundreds
/// of idle writers in this directory; decoding all of them every two seconds is wasted CPU.
private final class ActivityHeartbeatFileCache: @unchecked Sendable {
    private struct Fingerprint: Equatable {
        let inode: UInt64
        let modifiedAt: TimeInterval
        let size: Int64
    }
    private struct Entry {
        let fingerprint: Fingerprint
        let heartbeat: ActivityHeartbeat?
    }

    private let lock = NSLock()
    private var directoryPath: String?
    private var entries: [String: Entry] = [:]

    func scan(directory: URL, limit: Int) -> [String: [ActivityHeartbeat]] {
        let path = directory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if directoryPath != path {
            directoryPath = path
            entries.removeAll(keepingCapacity: false)
        }
        guard let listedFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let files = Array(listedFiles.prefix(limit).filter { $0.pathExtension == "json" })
        let livePaths = Set(files.map { $0.standardizedFileURL.path })
        entries = entries.filter { livePaths.contains($0.key) }
        var result: [String: [ActivityHeartbeat]] = [:]
        for url in files {
            let filePath = url.standardizedFileURL.path
            var info = stat()
            guard fstatat(AT_FDCWD, filePath, &info, 0) == 0 else { continue }
            let fingerprint = Fingerprint(
                inode: UInt64(info.st_ino),
                modifiedAt: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                size: Int64(info.st_size)
            )
            let heartbeat: ActivityHeartbeat?
            if let cached = entries[filePath], cached.fingerprint == fingerprint {
                heartbeat = cached.heartbeat
            } else {
                heartbeat = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ActivityHeartbeat.self, from: $0) }
                entries[filePath] = Entry(fingerprint: fingerprint, heartbeat: heartbeat)
            }
            if let heartbeat, let sessionPath = heartbeat.resolvedSessionPath {
                result[sessionPath, default: []].append(heartbeat)
            }
        }
        return result
    }
}

/// Reads the small heartbeat directory. One file per recently-active session in practice, so a
/// full directory scan every tick is cheap; still bounded defensively against a runaway count.
enum ActivityHeartbeatStore {
    static let maxFilesPerScan = 500
    private static let cache = ActivityHeartbeatFileCache()

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/desktop-activity", isDirectory: true)
    }

    /// Grouped by resolved session-file path. Multiple Pi processes can attach to the same
    /// session, so each writer is retained; the monitor reports running when any writer is live.
    /// A missing directory (extension never installed, nothing has run yet) is simply empty.
    static func scan(directory: URL) -> [String: [ActivityHeartbeat]] {
        cache.scan(directory: directory, limit: maxFilesPerScan)
    }
}
