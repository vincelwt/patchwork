import Foundation
import SQLite3

/// Codex's own name for each thread.
///
/// A rollout file does not contain the thread's name: Codex keeps it in a small state database
/// beside the sessions and shows that in its own picker. Without it every Codex conversation
/// here fell back to its first user turn, which for Codex is scaffolding rather than the user
/// talking, so the sidebar filled with identically-named rows.
///
/// This is a strictly read-only reader over a file another program owns. It opens with
/// `mode=ro`, never writes, never migrates, and degrades to "no titles" on any surprise — a
/// schema change, a locked database, a version of Codex that stores this elsewhere. The names
/// are a nicety; losing them must never cost a conversation.
public final class CodexThreadTitles: @unchecked Sendable {
    public static let shared = CodexThreadTitles()

    /// Codex names the file for its schema generation (`state_5.sqlite`), so a future version
    /// lands beside this one rather than migrating it. The highest generation present wins.
    static let filePrefix = "state_"
    static let fileSuffix = ".sqlite"
    /// A machine with years of history has thousands of threads; this is generous for a sidebar
    /// and keeps a pathological database from being read into memory wholesale.
    static let rowLimit = 20_000

    private let directory: URL
    private let lock = NSLock()
    private var cached: [String: String] = [:]
    private struct DatabaseFingerprint: Equatable {
        let path: String
        let modified: Date
        let size: Int64
        let walModified: Date
        let walSize: Int64
    }
    private var loadedFrom: DatabaseFingerprint?
    private var lastAttempt: Date?
    /// A failed read is not retried on every sidebar refresh; a database being written to is a
    /// normal transient state, not something to hammer.
    private static let retryInterval: TimeInterval = 30

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Codex's title for a thread id, or nil when it has none this build can read.
    public func title(forThreadID threadID: String) -> String? {
        guard !threadID.isEmpty else { return nil }
        return refreshedTitles()[threadID]
    }

    /// One current title map for a whole catalog pass. Callers should reuse it across rows.
    public func snapshot() -> [String: String] { refreshedTitles() }

    /// The thread id Codex uses, taken from its rollout filename
    /// (`rollout-<ISO8601>-<threadId>.jsonl`). The timestamp itself contains dashes, so the id
    /// is recovered by its own shape rather than by splitting on separators.
    public static func threadID(fromRolloutPath path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-") else { return nil }
        // A UUID is 36 characters: 8-4-4-4-12.
        let candidate = String(name.suffix(36))
        let groups = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12],
              candidate.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return candidate
    }

    private func refreshedTitles() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        guard let database = newestDatabase() else {
            cached = [:]
            loadedFrom = nil
            return cached
        }
        // Re-read only when the file actually changed. Codex writes constantly, so this is an
        // mtime/size check rather than a query per sidebar refresh.
        if loadedFrom == database {
            return cached
        }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.retryInterval, cached.isEmpty {
            return cached
        }
        lastAttempt = Date()

        guard let titles = Self.readTitles(at: database.path) else { return cached }
        cached = titles
        loadedFrom = database
        return cached
    }

    private func newestDatabase() -> DatabaseFingerprint? {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]
        ) else { return nil }

        let candidates = entries.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(Self.filePrefix) && name.hasSuffix(Self.fileSuffix)
        }
        // Highest schema generation, then newest, so a fresh Codex release is picked up without
        // this needing to know its number.
        guard let newest = candidates.max(by: { lhs, rhs in
            let left = Self.generation(of: lhs.lastPathComponent)
            let right = Self.generation(of: rhs.lastPathComponent)
            if left != right { return left < right }
            let leftDate = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }) else { return nil }

        let values = try? newest.resourceValues(forKeys: Set(keys))
        let wal = URL(fileURLWithPath: newest.path + "-wal")
        let walValues = try? wal.resourceValues(forKeys: Set(keys))
        return DatabaseFingerprint(
            path: newest.path,
            modified: values?.contentModificationDate ?? .distantPast,
            size: Int64(values?.fileSize ?? 0),
            walModified: walValues?.contentModificationDate ?? .distantPast,
            walSize: Int64(walValues?.fileSize ?? 0)
        )
    }

    static func generation(of filename: String) -> Int {
        let middle = filename.dropFirst(filePrefix.count).dropLast(fileSuffix.count)
        return Int(middle) ?? -1
    }

    /// One read-only pass. `nil` means "could not read", which keeps whatever was cached rather
    /// than blanking every title because Codex happened to be mid-write.
    static func readTitles(at path: String) -> [String: String]? {
        var handle: OpaquePointer?
        // `mode=ro` on a URI filename: no journal recovery, no write, no lock escalation. The
        // WAL is still read, so threads created moments ago are visible.
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 200)

        // `name` is the user's own rename and wins; `title` is what Codex generated. Both are
        // optional in the schema, and a row with neither simply contributes nothing.
        let sql = """
        SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, '')) AS label
        FROM threads WHERE label IS NOT NULL LIMIT \(rowLimit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var titles: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                  let labelBytes = sqlite3_column_text(statement, 1) else { continue }
            let label = String(cString: labelBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            // Codex stores the whole first message as a fallback title, newlines and all; a
            // sidebar row shows one line, so it is reduced to its first here rather than at
            // every call site.
            guard let headline = label.split(separator: "\n").first(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) else { continue }
            titles[String(cString: idBytes)] = String(headline.trimmingCharacters(in: .whitespaces).prefix(300))
        }
        return titles
    }
}
