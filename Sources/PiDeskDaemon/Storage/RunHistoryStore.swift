import Foundation
import PiDeskKit

/// Owns `runs.jsonl`. A run is appended once when it starts (`status: running`, so it is visible
/// immediately) and again when it finishes; both are cheap append-only writes, and startup
/// replay dedupes by id (keeping the last line written) so a restart never resurrects a stale
/// "running" ghost for a run that actually finished before the daemon last stopped.
///
/// Bounded twice over, per the doc's "bound everything": the in-memory view keeps only the most
/// recent `maxInMemory` runs (older ones are simply not queryable any more), and the file itself
/// is rotated once it passes `maxFileBytes` \u2014 both deliberately generous, not tuned for a
/// particular workload.
actor RunHistoryStore {
    private let fileURL: URL
    private let logger: DaemonLogger
    private let maxInMemory: Int
    private let maxFileBytes: Int
    /// Oldest first.
    private var recent: [Run] = []
    private var writesSinceRotationCheck = 0

    init(fileURL: URL = PiDeskPaths.runHistory, logger: DaemonLogger, maxInMemory: Int = 5_000, maxFileBytes: Int = 8 * 1_024 * 1_024) {
        self.fileURL = fileURL
        self.logger = logger
        self.maxInMemory = maxInMemory
        self.maxFileBytes = maxFileBytes
        recent = Self.load(fileURL: fileURL, maxInMemory: maxInMemory, logger: logger)
    }

    func record(_ run: Run) {
        if let index = recent.firstIndex(where: { $0.id == run.id }) {
            recent[index] = run
        } else {
            recent.append(run)
            if recent.count > maxInMemory { recent.removeFirst(recent.count - maxInMemory) }
        }
        appendLine(run)
    }

    func get(id: String) -> Run? { recent.last { $0.id == id } }

    func query(scheduleId: String?, threadId: String?, limit: Int) -> [Run] {
        var matches: [Run] = []
        matches.reserveCapacity(min(limit, recent.count))
        for run in recent.reversed() {
            if let scheduleId, run.scheduleId != scheduleId { continue }
            if let threadId, run.threadId != threadId { continue }
            matches.append(run)
            if matches.count >= limit { break }
        }
        return matches
    }

    /// Every currently-running run, for `/v1/health`'s `runningRuns` and the queue's own
    /// bookkeeping cross-check.
    func runningCount() -> Int { recent.filter { $0.status == .running }.count }

    /// A plain static function, not an instance method: an actor's `init` cannot synchronously
    /// call its own actor-isolated methods, so loading is computed here and assigned directly.
    private static func load(fileURL: URL, maxInMemory: Int, logger: DaemonLogger) -> [Run] {
        guard let data = FileManager.default.contents(atPath: fileURL.path), !data.isEmpty else { return [] }
        var framer = JSONLFramer()
        var byID: [String: Run] = [:]
        var order: [String] = []
        func ingest(_ record: Data) {
            guard let run = try? PiDeskJSON.decoder.decode(Run.self, from: record) else {
                logger.warn("Skipping malformed runs.jsonl entry")
                return
            }
            if byID[run.id] == nil { order.append(run.id) }
            byID[run.id] = run
        }
        for record in framer.append(data) { ingest(record) }
        if let trailing = framer.finish() { ingest(trailing) }

        let ordered = order.compactMap { byID[$0] }
        return Array(ordered.suffix(maxInMemory))
    }

    private func appendLine(_ run: Run) {
        guard var line = try? PiDeskJSON.encoder.encode(run) else { return }
        line.append(0x0A)
        _ = try? PiDeskFile.ensureDirectory(fileURL.deletingLastPathComponent())
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }

        writesSinceRotationCheck += 1
        if writesSinceRotationCheck >= 50 {
            writesSinceRotationCheck = 0
            rotateIfNeeded()
        }
    }

    /// Keeps only the in-memory view's worth of history on disk once the file grows past the
    /// bound, so `runs.jsonl` cannot grow forever on a long-lived daemon.
    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxFileBytes else { return }
        var rewritten = Data()
        for run in recent {
            guard var line = try? PiDeskJSON.encoder.encode(run) else { continue }
            line.append(0x0A)
            rewritten.append(line)
        }
        try? PiDeskFile.writeAtomic(rewritten, to: fileURL)
        logger.info("Rotated runs.jsonl (was over \(maxFileBytes) bytes).")
    }
}
