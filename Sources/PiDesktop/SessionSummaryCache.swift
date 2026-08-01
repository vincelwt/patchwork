import Foundation
import PiDeskKit

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

    /// v7 stores transcript-derived names only, so external title changes never stale the cache.
    static let version = 7
    static let maximumRetainedEntries = 5_000
    static let maximumPayloadBytes = 16 * 1_024 * 1_024
    private static let pruneBatchSize = 256
    private let fileURL: URL
    private var entries: [String: Entry]
    /// Legacy entries can paint immediately, but miss normal lookups once so v7 metadata is filled
    /// during the ordinary background discovery pass.
    private var stalePaths: Set<String>
    private var isDirty: Bool
    private(set) var hitCount = 0
    private(set) var missCount = 0

    init(fileURL: URL? = nil) {
        let manager = FileManager.default
        let defaultDirectory = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pi Desktop", isDirectory: true)
        self.fileURL = fileURL ?? defaultDirectory.appendingPathComponent("session-summaries-v7.json")

        if let data = Self.boundedData(from: self.fileURL),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version == Self.version {
            entries = Self.newestEntries(envelope.entries, limit: Self.maximumRetainedEntries)
            stalePaths = []
            isDirty = entries.count != envelope.entries.count
        } else {
            let legacyURL = self.fileURL.deletingLastPathComponent()
                .appendingPathComponent("session-summaries-v6.json")
            if let data = Self.boundedData(from: legacyURL),
               let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.version == 6 {
                entries = Self.newestEntries(envelope.entries, limit: Self.maximumRetainedEntries)
                stalePaths = Set(entries.keys)
                isDirty = true
            } else {
                entries = [:]
                stalePaths = []
                isDirty = false
            }
        }
    }

    func summary(
        for fingerprint: SessionFileFingerprint,
        archivedIDs: Set<String>,
        expectedAgent: AgentKind? = nil
    ) -> SessionSummary? {
        guard !stalePaths.contains(fingerprint.path),
              var summary = entries[fingerprint.path]?.summary,
              entries[fingerprint.path]?.fingerprint == fingerprint,
              expectedAgent.map({ $0 == summary.agent }) ?? true else {
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
        isDirty = true
        if entries.count > Self.maximumRetainedEntries + Self.pruneBatchSize {
            entries = Self.newestEntries(entries, limit: Self.maximumRetainedEntries)
            stalePaths.formIntersection(entries.keys)
        }
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
        if entries.count != previous { isDirty = true }
        return previous - entries.count
    }

    func persist() throws {
        entries = Self.newestEntries(entries, limit: Self.maximumRetainedEntries)
        stalePaths.formIntersection(entries.keys)
        guard isDirty else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try payloadWithinByteLimit()
        try data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    func contains(path: String) -> Bool { entries[path] != nil }
    func count() -> Int { entries.count }

    private func payloadWithinByteLimit() throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(Envelope(version: Self.version, entries: entries))
        guard data.count > Self.maximumPayloadBytes else { return data }

        let ordered = Self.orderedNewest(entries)
        var lower = 0
        var upper = ordered.count
        var bestEntries: [String: Entry] = [:]
        var bestData = try encoder.encode(Envelope(version: Self.version, entries: [:]))
        while lower <= upper {
            let count = (lower + upper) / 2
            let candidate = Dictionary(uniqueKeysWithValues: ordered.prefix(count))
            let candidateData = try encoder.encode(Envelope(version: Self.version, entries: candidate))
            if candidateData.count <= Self.maximumPayloadBytes {
                bestEntries = candidate
                bestData = candidateData
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        entries = bestEntries
        stalePaths.formIntersection(entries.keys)
        data = bestData
        return data
    }

    private static func newestEntries(
        _ entries: [String: Entry], limit: Int
    ) -> [String: Entry] {
        guard entries.count > limit else { return entries }
        return Dictionary(uniqueKeysWithValues: orderedNewest(entries).prefix(max(0, limit)))
    }

    private static func orderedNewest(_ entries: [String: Entry]) -> [(String, Entry)] {
        entries.sorted {
            if $0.value.summary.modifiedAt != $1.value.summary.modifiedAt {
                return $0.value.summary.modifiedAt > $1.value.summary.modifiedAt
            }
            return $0.key < $1.key
        }
    }

    private static func boundedData(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumPayloadBytes + 1),
              data.count <= maximumPayloadBytes else { return nil }
        return data
    }
}
