import Foundation
import PatchworkKit

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

    /// v6 adds the owning agent and the subsession flag, so older summaries are reparsed.
    static let version = 6
    private let fileURL: URL
    private var entries: [String: Entry]
    /// Legacy entries can paint immediately, but miss normal lookups once so v5 metadata is filled
    /// during the ordinary background discovery pass.
    private var stalePaths: Set<String>
    private(set) var hitCount = 0
    private(set) var missCount = 0

    init(fileURL: URL? = nil) {
        let defaultDirectory = PatchworkPaths.cacheDirectory
        self.fileURL = fileURL ?? defaultDirectory.appendingPathComponent("session-summaries-v6.json")

        if let data = try? Data(contentsOf: self.fileURL),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version == Self.version {
            entries = envelope.entries
            stalePaths = []
        } else {
            let legacyURL = self.fileURL.deletingLastPathComponent()
                .appendingPathComponent("session-summaries-v5.json")
            if let data = try? Data(contentsOf: legacyURL),
               let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.version == 5 {
                entries = envelope.entries
                stalePaths = Set(envelope.entries.keys)
            } else {
                entries = [:]
                stalePaths = []
            }
        }
    }

    func summary(for fingerprint: SessionFileFingerprint, archivedIDs: Set<String>) -> SessionSummary? {
        guard !stalePaths.contains(fingerprint.path),
              var summary = entries[fingerprint.path]?.summary,
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
        stalePaths.remove(fingerprint.path)
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
        stalePaths.formIntersection(entries.keys)
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
