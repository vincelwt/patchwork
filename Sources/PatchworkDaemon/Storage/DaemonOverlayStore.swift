import Foundation
import PatchworkKit

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
    enum ArchiveRestoreError: Error {
        case staleCheckpoint
    }

    enum PersistenceError: Error {
        case payloadTooLarge
    }

    struct ArchiveCheckpoint: Sendable {
        fileprivate let previousState: State
        fileprivate let committedRevision: UInt64
    }

    fileprivate typealias ReadOverride = DaemonWorktreeProjects.ReadOverride

    fileprivate struct State: Codable, Sendable {
        /// Legacy builds keyed archives only by session id. Retained for migration; all new writes
        /// use the standardized transcript path so copied/imported sessions remain independent.
        var archivedThreadIDs: Set<String> = []
        var archivedThreadPaths: Set<String> = []
        var archiveExemptThreadPaths: Set<String> = []
        /// Threads created through the shared control plane are desktop-owned even if the native
        /// app was not running when they were created.
        var managedThreadPaths: Set<String> = []
        /// Keyed by the thread's standardized file path, matching the app's own key choice for
        /// `lastReadAt` in `state.json`.
        var readOverrides: [String: ReadOverride] = [:]
        /// Worktree execution cwd → the exact source cwd supplied by the caller. Kept outside
        /// app-owned state.json so daemon and app writes cannot clobber each other.
        var managedWorktreeProjects: [String: String] = [:]
        /// Conversations created by a Patchwork remote surface. The Mac app reads this bounded
        /// overlay and treats them exactly like conversations it started in its own window.
        var desktopStartedThreadPaths: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            archivedThreadIDs = ArchiveStateBounds.legacyIDs(try container.decodeIfPresent(
                Set<String>.self, forKey: .archivedThreadIDs
            ) ?? [])
            archivedThreadPaths = ArchiveStateBounds.standardizedPaths(try container.decodeIfPresent(
                Set<String>.self, forKey: .archivedThreadPaths
            ) ?? [])
            archiveExemptThreadPaths = ArchiveStateBounds.standardizedPaths(try container.decodeIfPresent(
                Set<String>.self, forKey: .archiveExemptThreadPaths
            ) ?? [])
            managedThreadPaths = ArchiveStateBounds.standardizedPaths(try container.decodeIfPresent(
                Set<String>.self, forKey: .managedThreadPaths
            ) ?? [])
            let decodedOverrides = try container.decodeIfPresent(
                [String: ReadOverride].self, forKey: .readOverrides
            ) ?? [:]
            var standardizedOverrides: [String: ReadOverride] = [:]
            for (rawPath, value) in decodedOverrides {
                let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
                if let existing = standardizedOverrides[path], existing.markedAt >= value.markedAt {
                    continue
                }
                standardizedOverrides[path] = value
            }
            readOverrides = Dictionary(uniqueKeysWithValues: standardizedOverrides.sorted {
                if $0.value.markedAt != $1.value.markedAt {
                    return $0.value.markedAt < $1.value.markedAt
                }
                return $0.key < $1.key
            }.suffix(ArchiveStateBounds.itemLimit))
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
            managedThreadPaths = ArchiveStateBounds.standardizedPaths(
                managedThreadPaths.union(desktopStartedThreadPaths)
            )
        }
    }

    private let fileURL: URL
    private var state: State
    private var archiveRevision: UInt64 = 0

    init(fileURL: URL = PatchworkPaths.supportDirectory.appendingPathComponent("daemon-thread-overlay.json")) {
        self.fileURL = fileURL
        state = Self.loadState(from: fileURL) ?? State()
    }

    /// A plain-value copy for a caller (like `ThreadStore`, scanning every thread on every
    /// request) that wants to check many ids/paths without one actor hop per check.
    struct Snapshot: Sendable {
        var archivedThreadIDs: Set<String>
        var archivedThreadPaths: Set<String>
        var archiveExemptThreadPaths: Set<String>
        var managedThreadPaths: Set<String>
        var readOverrides: [String: (unread: Bool, markedAt: Date)]
        var managedWorktreeProjects: [String: String]
        var desktopStartedThreadPaths: Set<String>

        func isArchived(_ threadID: String, path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            return archivedThreadPaths.contains(path)
                || (archivedThreadIDs.contains(threadID)
                    && !archiveExemptThreadPaths.contains(path))
        }

        func unreadOverride(path: String, updatedAt: Date) -> Bool? {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let override = readOverrides[path], override.markedAt >= updatedAt else { return nil }
            return override.unread
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            archivedThreadIDs: state.archivedThreadIDs,
            archivedThreadPaths: state.archivedThreadPaths,
            archiveExemptThreadPaths: state.archiveExemptThreadPaths,
            managedThreadPaths: state.managedThreadPaths,
            readOverrides: state.readOverrides.mapValues { ($0.unread, $0.markedAt) },
            managedWorktreeProjects: state.managedWorktreeProjects,
            desktopStartedThreadPaths: state.desktopStartedThreadPaths
        )
    }

    func isArchived(_ threadID: String, path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return state.archivedThreadPaths.contains(path)
            || (state.archivedThreadIDs.contains(threadID)
                && !state.archiveExemptThreadPaths.contains(path))
    }

    @discardableResult
    func setArchived(_ archived: Bool, threadID: String, path: String) throws -> ArchiveCheckpoint {
        let previous = state
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if archived {
            state.archiveExemptThreadPaths.remove(standardizedPath)
            state.archivedThreadPaths.insert(standardizedPath)
        } else {
            state.archivedThreadPaths.remove(standardizedPath)
            if state.archivedThreadIDs.contains(threadID) {
                state.archiveExemptThreadPaths.insert(standardizedPath)
            } else {
                state.archiveExemptThreadPaths.remove(standardizedPath)
            }
        }
        if state.archiveExemptThreadPaths.count > ArchiveStateBounds.itemLimit {
            let overflow = state.archiveExemptThreadPaths.count - ArchiveStateBounds.itemLimit
            for stale in state.archiveExemptThreadPaths
                .filter({ $0 != standardizedPath }).sorted().prefix(overflow) {
                state.archiveExemptThreadPaths.remove(stale)
            }
        }
        if state.archivedThreadPaths.count > ArchiveStateBounds.itemLimit {
            let overflow = state.archivedThreadPaths.count - ArchiveStateBounds.itemLimit
            for stale in state.archivedThreadPaths
                .filter({ $0 != standardizedPath }).sorted().prefix(overflow) {
                state.archivedThreadPaths.remove(stale)
            }
        }
        do {
            try persist(preserving: [standardizedPath])
        } catch {
            state = previous
            throw error
        }
        archiveRevision &+= 1
        return ArchiveCheckpoint(
            previousState: previous,
            committedRevision: archiveRevision
        )
    }

    /// Restores every archive set touched by one committed mutation. A revision check prevents
    /// an older failed request from overwriting a newer archive action that interleaved with it.
    func restoreArchive(_ checkpoint: ArchiveCheckpoint) throws {
        guard archiveRevision == checkpoint.committedRevision else {
            throw ArchiveRestoreError.staleCheckpoint
        }
        let previous = state
        state = checkpoint.previousState
        do {
            try persist()
        } catch {
            state = previous
            throw error
        }
        archiveRevision &+= 1
    }

    func recordManagedThread(path: String) throws {
        let previous = state
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        state.managedThreadPaths.insert(standardizedPath)
        if state.managedThreadPaths.count > ArchiveStateBounds.itemLimit {
            let overflow = state.managedThreadPaths.count - ArchiveStateBounds.itemLimit
            for stale in state.managedThreadPaths
                .filter({ $0 != standardizedPath }).sorted().prefix(overflow) {
                state.managedThreadPaths.remove(stale)
            }
        }
        do {
            try persist(preserving: [standardizedPath])
        } catch {
            state = previous
            throw error
        }
    }

    /// `nil` means "no opinion, fall back to the app-state-derived computation" \u2014 either there
    /// is no override, or the thread changed again after it was recorded (matching the app's own
    /// `lastReadAt` semantics: a session that changes after being marked read is unread again).
    func unreadOverride(path: String, currentUpdatedAt: Date) -> Bool? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let override = state.readOverrides[path], override.markedAt >= currentUpdatedAt else { return nil }
        return override.unread
    }

    func setUnread(_ unread: Bool, path: String) throws {
        let previous = state
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        state.readOverrides[standardizedPath] = ReadOverride(unread: unread, markedAt: Date())
        let overflow = state.readOverrides.count - ArchiveStateBounds.itemLimit
        if overflow > 0 {
            let stale = state.readOverrides
                .filter { $0.key != standardizedPath }
                .sorted {
                    if $0.value.markedAt != $1.value.markedAt {
                        return $0.value.markedAt < $1.value.markedAt
                    }
                    return $0.key < $1.key
                }
                .prefix(overflow)
            for (path, _) in stale { state.readOverrides.removeValue(forKey: path) }
        }
        do {
            try persist(preserving: [standardizedPath])
        } catch {
            state = previous
            throw error
        }
    }

    func setManagedWorktreeProject(_ project: URL, for worktree: URL) throws {
        let previous = state
        let worktreePath = worktree.standardizedFileURL.path
        state.managedWorktreeProjects[worktreePath] = project.standardizedFileURL.path
        let overflow = state.managedWorktreeProjects.count - 2_000
        if overflow > 0 {
            for key in state.managedWorktreeProjects.keys.filter({ $0 != worktreePath }).sorted().prefix(overflow) {
                state.managedWorktreeProjects.removeValue(forKey: key)
            }
        }
        do {
            try persist(preserving: [worktreePath])
        } catch {
            state = previous
            throw error
        }
    }

    func recordDesktopStartedThread(path: String) throws {
        let previous = state
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !standardized.isEmpty else { return }
        state.desktopStartedThreadPaths.insert(standardized)
        state.managedThreadPaths.insert(standardized)
        let overflow = state.desktopStartedThreadPaths.count - 5_000
        if overflow > 0 {
            for path in state.desktopStartedThreadPaths.filter({ $0 != standardized }).sorted().prefix(overflow) {
                state.desktopStartedThreadPaths.remove(path)
            }
        }
        if state.managedThreadPaths.count > ArchiveStateBounds.itemLimit {
            let managedOverflow = state.managedThreadPaths.count - ArchiveStateBounds.itemLimit
            for stale in state.managedThreadPaths
                .filter({ $0 != standardized }).sorted().prefix(managedOverflow) {
                state.managedThreadPaths.remove(stale)
            }
        }
        do {
            try persist(preserving: [standardized])
        } catch {
            state = previous
            throw error
        }
    }

    private static func loadState(from url: URL) -> State? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: DaemonWorktreeProjects.maximumPayloadBytes + 1
        ), data.count <= DaemonWorktreeProjects.maximumPayloadBytes else { return nil }
        return try? PatchworkJSON.decoder.decode(State.self, from: data)
    }

    private func persist(preserving preservedPaths: Set<String> = []) throws {
        var data = try PatchworkJSON.encoder.encode(state)
        while data.count > DaemonWorktreeProjects.maximumPayloadBytes {
            let previousCounts = collectionCounts
            state.archivedThreadIDs = Self.reduced(
                state.archivedThreadIDs, preserving: [], target: state.archivedThreadIDs.count / 2
            )
            state.archivedThreadPaths = Self.reduced(
                state.archivedThreadPaths,
                preserving: preservedPaths,
                target: state.archivedThreadPaths.count / 2
            )
            state.archiveExemptThreadPaths = Self.reduced(
                state.archiveExemptThreadPaths,
                preserving: preservedPaths,
                target: state.archiveExemptThreadPaths.count / 2
            )
            state.managedThreadPaths = Self.reduced(
                state.managedThreadPaths,
                preserving: preservedPaths,
                target: state.managedThreadPaths.count / 2
            )
            state.desktopStartedThreadPaths = Self.reduced(
                state.desktopStartedThreadPaths,
                preserving: preservedPaths,
                target: state.desktopStartedThreadPaths.count / 2
            )
            state.readOverrides = Self.reducedReadOverrides(
                state.readOverrides,
                preserving: preservedPaths,
                target: state.readOverrides.count / 2
            )
            state.managedWorktreeProjects = Self.reducedProjects(
                state.managedWorktreeProjects,
                preserving: preservedPaths,
                target: state.managedWorktreeProjects.count / 2
            )
            guard collectionCounts != previousCounts else { throw PersistenceError.payloadTooLarge }
            data = try PatchworkJSON.encoder.encode(state)
        }
        try PatchworkFile.writeAtomic(data, to: fileURL)
    }

    private var collectionCounts: [Int] {
        [
            state.archivedThreadIDs.count,
            state.archivedThreadPaths.count,
            state.archiveExemptThreadPaths.count,
            state.managedThreadPaths.count,
            state.desktopStartedThreadPaths.count,
            state.readOverrides.count,
            state.managedWorktreeProjects.count,
        ]
    }

    private static func reduced(
        _ values: Set<String>, preserving: Set<String>, target: Int
    ) -> Set<String> {
        let required = values.intersection(preserving)
        let available = max(target, required.count) - required.count
        return required.union(values.subtracting(required).sorted().suffix(available))
    }

    private static func reducedReadOverrides(
        _ values: [String: ReadOverride], preserving: Set<String>, target: Int
    ) -> [String: ReadOverride] {
        let required = values.filter { preserving.contains($0.key) }
        let available = max(target, required.count) - required.count
        let retained = values.filter { !preserving.contains($0.key) }.sorted {
            if $0.value.markedAt != $1.value.markedAt {
                return $0.value.markedAt < $1.value.markedAt
            }
            return $0.key < $1.key
        }.suffix(available)
        return Dictionary(retained.map { ($0.key, $0.value) }, uniquingKeysWith: { _, newer in newer })
            .merging(required, uniquingKeysWith: { _, required in required })
    }

    private static func reducedProjects(
        _ values: [String: String], preserving: Set<String>, target: Int
    ) -> [String: String] {
        let required = values.filter { preserving.contains($0.key) }
        let available = max(target, required.count) - required.count
        let retained = values.filter { !preserving.contains($0.key) }
            .sorted { $0.key < $1.key }
            .suffix(available)
        return Dictionary(retained.map { ($0.key, $0.value) }, uniquingKeysWith: { _, newer in newer })
            .merging(required, uniquingKeysWith: { _, required in required })
    }
}
