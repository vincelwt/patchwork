import Foundation

/// Read-only projection of the daemon-owned thread overlay. Pi Desktop merges archive flags and
/// worktree mappings into its presentation without letting the daemon race `state.json` writes.
public enum DaemonWorktreeProjects {
    public struct Snapshot: Sendable {
        public var archivedThreadIDs: Set<String>
        public var managedWorktreeProjects: [String: String]
    }

    private struct Payload: Decodable {
        var archivedThreadIDs: Set<String>?
        var managedWorktreeProjects: [String: String]?
    }

    public static func loadSnapshot(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> Snapshot {
        guard let data = FileManager.default.contents(atPath: url.path),
              data.count <= 8 * 1_024 * 1_024,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Snapshot(archivedThreadIDs: [], managedWorktreeProjects: [:])
        }
        var projects: [String: String] = [:]
        for (worktree, project) in (payload.managedWorktreeProjects ?? [:]).sorted(by: { $0.key < $1.key }).suffix(2_000) {
            projects[URL(fileURLWithPath: worktree).standardizedFileURL.path] =
                URL(fileURLWithPath: project).standardizedFileURL.path
        }
        return Snapshot(
            archivedThreadIDs: payload.archivedThreadIDs ?? [],
            managedWorktreeProjects: projects
        )
    }

    public static func load(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> [String: String] {
        loadSnapshot(from: url).managedWorktreeProjects
    }
}
