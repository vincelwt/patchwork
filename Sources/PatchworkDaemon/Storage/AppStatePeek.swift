import Foundation
import PatchworkKit

/// A read-only, best-effort peek at the app's `state.json`, purely to answer `Thread.archived`/
/// `Thread.unread` the same way the app itself would. The daemon never writes this file \u2014
/// `state.json` stays exactly as documented, "existing app state \u2026 unchanged", with the app as
/// its sole writer \u2014 and tolerates it being absent, mid-write, or from a future app version
/// with fields this build does not know about.
///
/// `unread` provides the persisted part of the app's own `WorkspaceOrganization.isUnread(_:)`
/// (`Sources/Patchwork/WorkspaceOrganization.swift`, not importable from here): a manually marked
/// unread session wins, otherwise latest/last-seen completion IDs decide. `lastReadAt` is only
/// the backward-compatible fallback for state the app has not migrated yet. `ThreadStore`
/// separately suppresses unread while running; the selected-UI carve-out has no daemon equivalent.
enum AppStatePeek {
    struct Snapshot: Decodable, Sendable {
        var archivedSessionIDs: Set<String> = []
        var archivedSessionPaths: Set<String> = []
        var archiveExemptSessionPaths: Set<String> = []
        /// Exact paths the app owns. These also act as bounded discovery seeds when Pi writes a
        /// conversation outside its default root through a cwd-specific `sessionDir` setting.
        var appStartedSessionPaths: Set<String> = []
        var manuallyUnreadSessionPaths: Set<String> = []
        var latestCompletedEntryIDBySessionPath: [String: String] = [:]
        var lastSeenCompletedEntryIDBySessionPath: [String: String] = [:]
        var lastReadAt: [String: Date] = [:]
        /// App-owned organisational folders, exposed read-only by `GET /v1/folders`. Absent in
        /// state written before folders existed, which decodes as "no folders", not as a failure.
        var virtualFolders: [StoredVirtualFolder] = []
        var virtualFolderAssignments: [String: String] = [:]
        var projectFolderAssignments: [String: String] = [:]
        var managedWorktreeProjects: [String: String] = [:]
        var showsForeignConversations = false
        var disabledAgents: Set<String> = []

        private enum CodingKeys: String, CodingKey {
            case archivedSessionIDs, archivedSessionPaths, archiveExemptSessionPaths
            case appStartedSessionPaths
            case manuallyUnreadSessionPaths
            case latestCompletedEntryIDBySessionPath, lastSeenCompletedEntryIDBySessionPath, lastReadAt
            case virtualFolders, virtualFolderAssignments, projectFolderAssignments
            case managedWorktreeProjects
            case showsForeignConversations, disabledAgents
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            archivedSessionIDs = ArchiveStateBounds.legacyIDs(try container.decodeIfPresent(
                Set<String>.self, forKey: .archivedSessionIDs
            ) ?? [])
            archivedSessionPaths = ArchiveStateBounds.standardizedPaths(try container.decodeIfPresent(
                Set<String>.self, forKey: .archivedSessionPaths
            ) ?? [])
            archiveExemptSessionPaths = ArchiveStateBounds.standardizedPaths(try container.decodeIfPresent(
                Set<String>.self, forKey: .archiveExemptSessionPaths
            ) ?? [])
            appStartedSessionPaths = ArchiveStateBounds.standardizedPaths(try container.decodeIfPresent(
                Set<String>.self, forKey: .appStartedSessionPaths
            ) ?? [])
            manuallyUnreadSessionPaths = try container.decodeIfPresent(Set<String>.self, forKey: .manuallyUnreadSessionPaths) ?? []
            latestCompletedEntryIDBySessionPath = try container.decodeIfPresent(
                [String: String].self, forKey: .latestCompletedEntryIDBySessionPath
            ) ?? [:]
            lastSeenCompletedEntryIDBySessionPath = try container.decodeIfPresent(
                [String: String].self, forKey: .lastSeenCompletedEntryIDBySessionPath
            ) ?? [:]
            lastReadAt = try container.decodeIfPresent([String: Date].self, forKey: .lastReadAt) ?? [:]
            // One malformed folder record must not cost the caller the whole tree, so folders are
            // decoded independently of everything above and default to empty on any failure.
            virtualFolders = (try? container.decodeIfPresent([StoredVirtualFolder].self, forKey: .virtualFolders)) ?? []
            virtualFolderAssignments = (try? container.decodeIfPresent([String: String].self, forKey: .virtualFolderAssignments)) ?? [:]
            projectFolderAssignments = (try? container.decodeIfPresent(
                [String: String].self, forKey: .projectFolderAssignments
            )) ?? [:]
            let worktrees = (try? container.decodeIfPresent(
                [String: String].self, forKey: .managedWorktreeProjects
            )) ?? [:]
            for (worktree, project) in worktrees.sorted(by: { $0.key < $1.key }).suffix(2_000) {
                managedWorktreeProjects[URL(fileURLWithPath: worktree).standardizedFileURL.path] =
                    URL(fileURLWithPath: project).standardizedFileURL.path
            }
            showsForeignConversations = try container.decodeIfPresent(
                Bool.self, forKey: .showsForeignConversations
            ) ?? false
            disabledAgents = try container.decodeIfPresent(Set<String>.self, forKey: .disabledAgents) ?? []
        }

        /// The cycle-safe, depth-capped projection `GET /v1/folders` returns. Assignment keys are
        /// standardized the same way `ThreadStore` standardizes `Thread.path`, so a client can
        /// look one up directly by the path it already has.
        var folderTree: FolderTreeResponse {
            let standardized = Dictionary(
                virtualFolderAssignments.map { (URL(fileURLWithPath: $0.key).standardizedFileURL.path, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            return FolderTree.response(
                folders: virtualFolders,
                assignments: standardized,
                projectAssignments: projectFolderAssignments
            )
        }

        func isArchived(sessionID: String, path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            return archivedSessionPaths.contains(path)
                || (archivedSessionIDs.contains(sessionID)
                    && !archiveExemptSessionPaths.contains(path))
        }

        func sidebarVisibility(desktopStartedThreadPaths: Set<String>) -> SidebarVisibility {
            SidebarVisibility(
                showsForeignConversations: showsForeignConversations,
                appStartedSessionPaths: appStartedSessionPaths,
                desktopStartedThreadPaths: desktopStartedThreadPaths,
                disabledAgents: Set(disabledAgents.compactMap(AgentKind.init(rawValue:)))
            )
        }

        func isUnread(path: String, latestCompletionID: String?, modifiedAt: Date) -> Bool {
            if manuallyUnreadSessionPaths.contains(path) { return true }
            if let latest = latestCompletionID ?? latestCompletedEntryIDBySessionPath[path] {
                return lastSeenCompletedEntryIDBySessionPath[path] != latest
            }
            guard let viewed = lastReadAt[path] else { return false }
            return modifiedAt > viewed
        }
    }

    /// The app's own `state.json` is a few hundred KB at worst. Reading it is unavoidable, but
    /// reading an arbitrarily large one is not: past this the daemon reports "no state" rather
    /// than pulling a corrupted or hostile file into memory on every folder request.
    static let maxStateBytes = ArchiveStateBounds.appStateByteLimit

    static func load(from url: URL = AppStatePeek.defaultURL()) -> Snapshot {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= maxStateBytes,
              let data = FileManager.default.contents(atPath: url.path) else { return Snapshot() }
        // The app writes this file with a plain, default-configured `JSONEncoder` (no ISO 8601
        // strategy), so `Date` fields are `.deferredToDate` (seconds since the 2001 reference
        // date) \u2014 a plain decoder matches that; `PatchworkJSON.decoder` would reject every date.
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    static func defaultURL() -> URL {
        PatchworkPaths.supportDirectory.appendingPathComponent("state.json")
    }
}
