import Foundation
import PiDeskKit

/// Owns `schedules.json`: the one writer the doc requires. Loads defensively \u2014 a single
/// malformed entry is quarantined (skipped, recorded as a `HealthIssue`) rather than taking the
/// rest of the file, or daemon startup, down with it.
actor ScheduleStore {
    enum InsertResult: Sendable {
        case inserted(Schedule)
        case existing(Schedule)
    }
    private let fileURL: URL
    private let logger: DaemonLogger
    private var schedules: [String: Schedule] = [:]
    private(set) var quarantineIssues: [HealthIssue] = []

    init(fileURL: URL = PiDeskPaths.schedules, logger: DaemonLogger) {
        self.fileURL = fileURL
        self.logger = logger
        let loaded = Self.load(fileURL: fileURL, logger: logger)
        schedules = loaded.schedules
        quarantineIssues = loaded.issues
    }

    func all() -> [Schedule] {
        schedules.values.sorted { $0.createdAt < $1.createdAt }
    }

    func get(id: String) -> Schedule? { schedules[id] }

    /// Inserts exactly once under actor isolation. Idempotent HTTP creates cannot split an
    /// existence check and write across two actor turns, which would allow last-writer-wins.
    func insertIfAbsent(_ schedule: Schedule) throws -> InsertResult {
        if let existing = schedules[schedule.id] { return .existing(existing) }
        var updated = schedules
        updated[schedule.id] = schedule
        try persist(updated)
        schedules = updated
        return .inserted(schedule)
    }

    @discardableResult
    func upsert(_ schedule: Schedule) throws -> Schedule {
        var updated = schedules
        updated[schedule.id] = schedule
        try persist(updated)
        schedules = updated
        return schedule
    }

    /// Atomically transforms the latest in-memory value and only publishes it after the file
    /// write succeeds. Returning false leaves the schedule untouched (stale occurrence/version).
    @discardableResult
    func update(id: String, _ transform: (inout Schedule) -> Bool) throws -> Schedule? {
        guard var schedule = schedules[id], transform(&schedule) else { return nil }
        var updated = schedules
        updated[id] = schedule
        try persist(updated)
        schedules = updated
        return schedule
    }

    /// Compare-and-update for request handlers that derive several fields from one snapshot.
    /// A concurrent client must never let a stale validation overwrite a newer target, agent,
    /// or mode combination.
    @discardableResult
    func update(
        id: String,
        matching expected: Schedule,
        _ transform: (inout Schedule) -> Void
    ) throws -> Schedule? {
        guard var schedule = schedules[id], schedule == expected else { return nil }
        transform(&schedule)
        var updated = schedules
        updated[id] = schedule
        try persist(updated)
        schedules = updated
        return schedule
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        guard schedules[id] != nil else { return false }
        var updated = schedules
        updated.removeValue(forKey: id)
        try persist(updated)
        schedules = updated
        return true
    }

    /// A plain static function, not an instance method: an actor's `init` cannot synchronously
    /// call its own actor-isolated methods, so loading is computed here and assigned directly.
    private static func load(fileURL: URL, logger: DaemonLogger) -> (schedules: [String: Schedule], issues: [HealthIssue]) {
        guard let data = FileManager.default.contents(atPath: fileURL.path), !data.isEmpty else { return ([:], []) }

        if let all = try? PiDeskJSON.decoder.decode([Schedule].self, from: data) {
            return (Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }), [])
        }

        // The happy-path whole-array decode failed; isolate individual bad entries instead of
        // discarding every schedule over one corrupt one.
        guard let value = try? PiJSONValue.decode(data), let entries = value.arrayValue else {
            let issue = HealthIssue(code: "schedules_file_corrupt", message: "schedules.json is not a JSON array; starting with no schedules.")
            logger.error(issue.message)
            return ([:], [issue])
        }

        var loaded: [String: Schedule] = [:]
        var issues: [HealthIssue] = []
        for (index, entry) in entries.enumerated() {
            guard let entryData = try? PiDeskJSON.encoder.encode(entry),
                  let schedule = try? PiDeskJSON.decoder.decode(Schedule.self, from: entryData) else {
                let issue = HealthIssue(code: "schedule_quarantined", message: "schedules.json entry #\(index) is malformed and was skipped.")
                issues.append(issue)
                logger.error(issue.message)
                continue
            }
            loaded[schedule.id] = schedule
        }
        logger.warn("Loaded \(loaded.count) schedule(s); quarantined \(issues.count).")
        return (loaded, issues)
    }

    private func persist(_ schedules: [String: Schedule]) throws {
        try PiDeskFile.writeAtomic(Array(schedules.values), to: fileURL)
    }
}
