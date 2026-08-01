import Foundation

/// Compatibility projection retained for clients that still distinguish remote-created threads.
public struct DaemonThreadOverlaySnapshot: Sendable {
    public var managedWorktreeProjects: [String: String]
    public var desktopStartedThreadPaths: Set<String>

    public init(
        managedWorktreeProjects: [String: String] = [:],
        desktopStartedThreadPaths: Set<String> = []
    ) {
        self.managedWorktreeProjects = managedWorktreeProjects
        self.desktopStartedThreadPaths = desktopStartedThreadPaths
    }
}

/// Read-only projection of the daemon-owned thread overlay. Pi Desktop merges this metadata into
/// its own presentation without letting the daemon race `state.json` writes.
public enum DaemonWorktreeProjects {
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024

    public struct ReadOverride: Codable, Sendable {
        public var unread: Bool
        public var markedAt: Date

        public init(unread: Bool, markedAt: Date) {
            self.unread = unread
            self.markedAt = markedAt
        }
    }

    public struct Snapshot: Sendable {
        public var archivedThreadIDs: Set<String>
        public var archivedThreadPaths: Set<String>
        public var archiveExemptThreadPaths: Set<String>
        public var managedThreadPaths: Set<String>
        public var managedWorktreeProjects: [String: String]
        public var readOverrides: [String: ReadOverride]
        public var desktopStartedThreadPaths: Set<String>

        public func isArchived(threadID: String, path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            return archivedThreadPaths.contains(path)
                || (archivedThreadIDs.contains(threadID)
                    && !archiveExemptThreadPaths.contains(path))
        }

        public func unreadOverride(path: String, updatedAt: Date) -> Bool? {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let value = readOverrides[path], value.markedAt >= updatedAt else { return nil }
            return value.unread
        }
    }

    private struct Payload: Decodable {
        var archivedThreadIDs: Set<String>?
        var archivedThreadPaths: Set<String>?
        var archiveExemptThreadPaths: Set<String>?
        var managedThreadPaths: Set<String>?
        var managedWorktreeProjects: [String: String]?
        var readOverrides: [String: ReadOverride]?
        var desktopStartedThreadPaths: Set<String>?
    }

    public static func loadSnapshot(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> Snapshot {
        guard let data = boundedData(from: url),
              let payload = try? PiDeskJSON.decoder.decode(Payload.self, from: data) else {
            return Snapshot(
                archivedThreadIDs: [], archivedThreadPaths: [], archiveExemptThreadPaths: [],
                managedThreadPaths: [], managedWorktreeProjects: [:], readOverrides: [:],
                desktopStartedThreadPaths: []
            )
        }
        var projects: [String: String] = [:]
        for (worktree, project) in (payload.managedWorktreeProjects ?? [:])
            .sorted(by: { $0.key < $1.key }).suffix(2_000) {
            projects[URL(fileURLWithPath: worktree).standardizedFileURL.path] =
                URL(fileURLWithPath: project).standardizedFileURL.path
        }
        var standardizedOverrides: [String: ReadOverride] = [:]
        for (rawPath, value) in payload.readOverrides ?? [:] {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            if let existing = standardizedOverrides[path], existing.markedAt >= value.markedAt {
                continue
            }
            standardizedOverrides[path] = value
        }
        let boundedOverrides = Dictionary(uniqueKeysWithValues: standardizedOverrides.sorted {
            if $0.value.markedAt != $1.value.markedAt {
                return $0.value.markedAt < $1.value.markedAt
            }
            return $0.key < $1.key
        }.suffix(ArchiveStateBounds.itemLimit))
        let desktopStartedPaths = ArchiveStateBounds.standardizedPaths(
            payload.desktopStartedThreadPaths ?? []
        )
        let managedPaths = ArchiveStateBounds.standardizedPaths(
            (payload.managedThreadPaths ?? []).union(desktopStartedPaths)
        )
        return Snapshot(
            archivedThreadIDs: ArchiveStateBounds.legacyIDs(payload.archivedThreadIDs ?? []),
            archivedThreadPaths: ArchiveStateBounds.standardizedPaths(payload.archivedThreadPaths ?? []),
            archiveExemptThreadPaths: ArchiveStateBounds.standardizedPaths(
                payload.archiveExemptThreadPaths ?? []
            ),
            managedThreadPaths: managedPaths,
            managedWorktreeProjects: projects,
            readOverrides: boundedOverrides,
            desktopStartedThreadPaths: desktopStartedPaths
        )
    }

    private static func boundedData(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumPayloadBytes + 1),
              data.count <= maximumPayloadBytes else { return nil }
        return data
    }

    public static func load(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> [String: String] {
        loadSnapshot(from: url).managedWorktreeProjects
    }
}

public enum DaemonThreadOverlay {
    public static func load(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> DaemonThreadOverlaySnapshot {
        let snapshot = DaemonWorktreeProjects.loadSnapshot(from: url)
        return DaemonThreadOverlaySnapshot(
            managedWorktreeProjects: snapshot.managedWorktreeProjects,
            desktopStartedThreadPaths: snapshot.desktopStartedThreadPaths
        )
    }
}
