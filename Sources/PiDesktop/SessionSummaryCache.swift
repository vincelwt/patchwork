import Foundation

struct SessionFileFingerprint: Hashable, Codable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: TimeInterval

    init(url: URL, values: URLResourceValues) {
        path = url.standardizedFileURL.path
        size = Int64(values.fileSize ?? 0)
        modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
}

actor SessionSummaryCache {
    private struct Entry: Codable {
        let fingerprint: SessionFileFingerprint
        let summary: SessionSummary
    }

    private struct Envelope: Codable {
        let version: Int
        var entries: [String: Entry]
    }

    /// v3 shortened the retained preview, so v2 payloads are intentionally discarded.
    static let version = 3
    private let fileURL: URL
    private var entries: [String: Entry]
    private(set) var hitCount = 0
    private(set) var missCount = 0

    init(fileURL: URL? = nil) {
        let manager = FileManager.default
        let defaultDirectory = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pi Desktop", isDirectory: true)
        self.fileURL = fileURL ?? defaultDirectory.appendingPathComponent("session-summaries-v3.json")

        if let data = try? Data(contentsOf: self.fileURL),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version == Self.version {
            entries = envelope.entries
        } else {
            entries = [:]
        }
    }

    func summary(for fingerprint: SessionFileFingerprint, archivedIDs: Set<String>) -> SessionSummary? {
        guard var summary = entries[fingerprint.path]?.summary,
              entries[fingerprint.path]?.fingerprint == fingerprint else {
            missCount += 1
            return nil
        }
        hitCount += 1
        summary.isArchived = archivedIDs.contains(summary.id)
        if summary.searchKey.isEmpty { summary.prepareSearchKey() }
        return summary
    }

    func store(_ summary: SessionSummary, fingerprint: SessionFileFingerprint) {
        var cached = summary
        cached.isArchived = false
        if cached.searchKey.isEmpty { cached.prepareSearchKey() }
        entries[fingerprint.path] = Entry(fingerprint: fingerprint, summary: cached)
    }

    /// Every cached summary whose file still exists, for immediate sidebar hydration at launch.
    /// The disk scan reconciles afterwards.
    func liveSummaries(archivedIDs: Set<String>) -> [SessionSummary] {
        let manager = FileManager.default
        return entries.compactMap { path, entry in
            guard manager.fileExists(atPath: path) else { return nil }
            var summary = entry.summary
            summary.isArchived = archivedIDs.contains(summary.id)
            if summary.searchKey.isEmpty { summary.prepareSearchKey() }
            return summary
        }
    }

    @discardableResult
    func pruneMissingFiles() -> Int {
        let previous = entries.count
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        return previous - entries.count
    }

    func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(version: Self.version, entries: entries))
        try data.write(to: fileURL, options: .atomic)
    }

    func contains(path: String) -> Bool { entries[path] != nil }
    func count() -> Int { entries.count }
}
