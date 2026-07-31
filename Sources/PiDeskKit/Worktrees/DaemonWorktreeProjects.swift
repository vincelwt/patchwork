import Foundation

/// Read-only projection of the daemon-owned thread overlay. Pi Desktop merges this metadata into
/// its own presentation without letting the daemon race `state.json` writes.
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

public enum DaemonThreadOverlay {
    private struct Snapshot: Decodable {
        var managedWorktreeProjects: [String: String]?
        var desktopStartedThreadPaths: Set<String>?
    }

    public static func load(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> DaemonThreadOverlaySnapshot {
        guard let data = FileManager.default.contents(atPath: url.path),
              data.count <= 8 * 1_024 * 1_024,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return DaemonThreadOverlaySnapshot() }
        var projects: [String: String] = [:]
        for (worktree, project) in (snapshot.managedWorktreeProjects ?? [:]).sorted(by: { $0.key < $1.key }).suffix(2_000) {
            projects[URL(fileURLWithPath: worktree).standardizedFileURL.path] =
                URL(fileURLWithPath: project).standardizedFileURL.path
        }
        let paths = Set((snapshot.desktopStartedThreadPaths ?? []).sorted().suffix(5_000).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        return DaemonThreadOverlaySnapshot(
            managedWorktreeProjects: projects,
            desktopStartedThreadPaths: paths
        )
    }
}

/// Compatibility surface for callers that only need the worktree mapping.
public enum DaemonWorktreeProjects {
    public static func load(
        from url: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")
    ) -> [String: String] {
        DaemonThreadOverlay.load(from: url).managedWorktreeProjects
    }
}
