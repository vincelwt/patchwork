import Foundation
import PiDeskKit

/// Backs the daemon's own `archived`/`unread` writes (`POST /v1/threads/{id}/archive` and
/// `.../read`) in a file the daemon exclusively owns, deliberately **not** `state.json`.
///
/// `state.json` is the app's: `AppPersistence` loads it once into memory and saves with a blind
/// `try? data.write(...)` on every change, with no merge-before-write. If the daemon wrote to
/// that same file, a change made here could be silently clobbered the next time the app (with
/// its own, now-stale in-memory copy) saves \u2014 a real lost-update race, not a hypothetical one.
/// Keeping a separate overlay file avoids that entirely; `ThreadStore` merges it with
/// `AppStatePeek`'s read-only view of `state.json` when answering `archived`/`unread`.
///
/// The merge is intentionally asymmetric: this can archive/unarchive and mark read/unread
/// independently, but a thread the *app* archived stays archived here too (a union, not an
/// override) \u2014 the daemon has no way to safely retract an app-owned flag it does not write.
actor DaemonOverlayStore {
    private struct ReadOverride: Codable, Sendable {
        var unread: Bool
        var markedAt: Date
    }

    private struct State: Codable, Sendable {
        var archivedThreadIDs: Set<String> = []
        /// Keyed by the thread's standardized file path, matching the app's own key choice for
        /// `lastReadAt` in `state.json`.
        var readOverrides: [String: ReadOverride] = [:]
        /// Worktree execution cwd → the exact source cwd supplied by the caller. Kept outside
        /// app-owned state.json so daemon and app writes cannot clobber each other.
        var managedWorktreeProjects: [String: String] = [:]
        /// Conversations created by a Pi Desktop remote surface. The Mac app reads this bounded
        /// overlay and treats them exactly like conversations it started in its own window.
        var desktopStartedThreadPaths: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            archivedThreadIDs = try container.decodeIfPresent(Set<String>.self, forKey: .archivedThreadIDs) ?? []
            readOverrides = try container.decodeIfPresent([String: ReadOverride].self, forKey: .readOverrides) ?? [:]
            let worktrees = try container.decodeIfPresent(
                [String: String].self, forKey: .managedWorktreeProjects
            ) ?? [:]
            managedWorktreeProjects = Dictionary(uniqueKeysWithValues: worktrees
                .sorted { $0.key < $1.key }
                .suffix(2_000))
            desktopStartedThreadPaths = Set((try container.decodeIfPresent(
                Set<String>.self, forKey: .desktopStartedThreadPaths
            ) ?? []).sorted().suffix(5_000).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
        }
    }

    private let fileURL: URL
    private var state: State

    init(fileURL: URL = PiDeskPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")) {
        self.fileURL = fileURL
        state = PiDeskFile.readIfPresent(State.self, from: fileURL) ?? State()
    }

    /// A plain-value copy for a caller (like `ThreadStore`, scanning every thread on every
    /// request) that wants to check many ids/paths without one actor hop per check.
    struct Snapshot: Sendable {
        var archivedThreadIDs: Set<String>
        var readOverrides: [String: (unread: Bool, markedAt: Date)]
        var managedWorktreeProjects: [String: String]
        var desktopStartedThreadPaths: Set<String>

        func isArchived(_ threadID: String) -> Bool { archivedThreadIDs.contains(threadID) }

        func unreadOverride(path: String, updatedAt: Date) -> Bool? {
            guard let override = readOverrides[path], override.markedAt >= updatedAt else { return nil }
            return override.unread
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            archivedThreadIDs: state.archivedThreadIDs,
            readOverrides: state.readOverrides.mapValues { ($0.unread, $0.markedAt) },
            managedWorktreeProjects: state.managedWorktreeProjects,
            desktopStartedThreadPaths: state.desktopStartedThreadPaths
        )
    }

    func isArchived(_ threadID: String) -> Bool { state.archivedThreadIDs.contains(threadID) }

    func setArchived(_ archived: Bool, threadID: String) throws {
        if archived { state.archivedThreadIDs.insert(threadID) } else { state.archivedThreadIDs.remove(threadID) }
        try persist()
    }

    /// `nil` means "no opinion, fall back to the app-state-derived computation" \u2014 either there
    /// is no override, or the thread changed again after it was recorded (matching the app's own
    /// `lastReadAt` semantics: a session that changes after being marked read is unread again).
    func unreadOverride(path: String, currentUpdatedAt: Date) -> Bool? {
        guard let override = state.readOverrides[path], override.markedAt >= currentUpdatedAt else { return nil }
        return override.unread
    }

    func setUnread(_ unread: Bool, path: String) throws {
        state.readOverrides[path] = ReadOverride(unread: unread, markedAt: Date())
        try persist()
    }

    func setManagedWorktreeProject(_ project: URL, for worktree: URL) throws {
        let worktreePath = worktree.standardizedFileURL.path
        state.managedWorktreeProjects[worktreePath] = project.standardizedFileURL.path
        let overflow = state.managedWorktreeProjects.count - 2_000
        if overflow > 0 {
            for key in state.managedWorktreeProjects.keys.filter({ $0 != worktreePath }).sorted().prefix(overflow) {
                state.managedWorktreeProjects.removeValue(forKey: key)
            }
        }
        try persist()
    }

    func recordDesktopStartedThread(path: String) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !standardized.isEmpty, !state.desktopStartedThreadPaths.contains(standardized) else { return }
        state.desktopStartedThreadPaths.insert(standardized)
        let overflow = state.desktopStartedThreadPaths.count - 5_000
        if overflow > 0 {
            for path in state.desktopStartedThreadPaths.filter({ $0 != standardized }).sorted().prefix(overflow) {
                state.desktopStartedThreadPaths.remove(path)
            }
        }
        try persist()
    }

    private func persist() throws {
        try PiDeskFile.writeAtomic(state, to: fileURL)
    }
}
