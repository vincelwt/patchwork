import Foundation

/// Read-only projection of the daemon-owned thread overlay. Patchwork merges this mapping into
/// its own presentation metadata without letting the daemon race `state.json` writes.
public enum DaemonWorktreeProjects {
    private struct Snapshot: Decodable {
        var managedWorktreeProjects: [String: String]?
    }

    public static func load(
        from url: URL = PatchworkPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: url.path),
              data.count <= 8 * 1_024 * 1_024,
              let values = try? JSONDecoder().decode(Snapshot.self, from: data).managedWorktreeProjects else { return [:] }
        var result: [String: String] = [:]
        for (worktree, project) in values.sorted(by: { $0.key < $1.key }).suffix(2_000) {
            result[URL(fileURLWithPath: worktree).standardizedFileURL.path] =
                URL(fileURLWithPath: project).standardizedFileURL.path
        }
        return result
    }
}
