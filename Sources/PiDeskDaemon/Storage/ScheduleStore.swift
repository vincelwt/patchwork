import Foundation
import PiDeskKit

/// Owns `schedules.json`: the one writer the doc requires. Loads defensively \u2014 a single
/// malformed entry is quarantined (skipped, recorded as a `HealthIssue`) rather than taking the
/// rest of the file, or daemon startup, down with it.
actor ScheduleStore {
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

    @discardableResult
    func upsert(_ schedule: Schedule) throws -> Schedule {
        schedules[schedule.id] = schedule
        try persist()
        return schedule
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        guard schedules.removeValue(forKey: id) != nil else { return false }
        try persist()
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

    private func persist() throws {
        try PiDeskFile.writeAtomic(Array(schedules.values), to: fileURL)
    }
}
