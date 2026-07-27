import Foundation
import PiDeskKit

/// A read-only, best-effort peek at the app's `state.json`, purely to answer `Thread.archived`/
/// `Thread.unread` the same way the app itself would. The daemon never writes this file \u2014
/// `state.json` stays exactly as documented, "existing app state \u2026 unchanged", with the app as
/// its sole writer \u2014 and tolerates it being absent, mid-write, or from a future app version
/// with fields this build does not know about.
///
/// `unread` provides the persisted part of the app's own `WorkspaceOrganization.isUnread(_:)`
/// (`Sources/PiDesktop/WorkspaceOrganization.swift`, not importable from here): a manually marked
/// unread session wins, otherwise latest/last-seen completion IDs decide. `lastReadAt` is only
/// the backward-compatible fallback for state the app has not migrated yet. `ThreadStore`
/// separately suppresses unread while running; the selected-UI carve-out has no daemon equivalent.
enum AppStatePeek {
    struct Snapshot: Decodable, Sendable {
        var archivedSessionIDs: Set<String> = []
        var manuallyUnreadSessionPaths: Set<String> = []
        var latestCompletedEntryIDBySessionPath: [String: String] = [:]
        var lastSeenCompletedEntryIDBySessionPath: [String: String] = [:]
        var lastReadAt: [String: Date] = [:]
        /// App-owned organisational folders, exposed read-only by `GET /v1/folders`. Absent in
        /// state written before folders existed, which decodes as "no folders", not as a failure.
        var virtualFolders: [StoredVirtualFolder] = []
        var virtualFolderAssignments: [String: String] = [:]

        private enum CodingKeys: String, CodingKey {
            case archivedSessionIDs, manuallyUnreadSessionPaths
            case latestCompletedEntryIDBySessionPath, lastSeenCompletedEntryIDBySessionPath, lastReadAt
            case virtualFolders, virtualFolderAssignments
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            archivedSessionIDs = try container.decodeIfPresent(Set<String>.self, forKey: .archivedSessionIDs) ?? []
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
        }

        /// The cycle-safe, depth-capped projection `GET /v1/folders` returns. Assignment keys are
        /// standardized the same way `ThreadStore` standardizes `Thread.path`, so a client can
        /// look one up directly by the path it already has.
        var folderTree: FolderTreeResponse {
            let standardized = Dictionary(
                virtualFolderAssignments.map { (URL(fileURLWithPath: $0.key).standardizedFileURL.path, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            return FolderTree.response(folders: virtualFolders, assignments: standardized)
        }

        func isArchived(sessionID: String) -> Bool { archivedSessionIDs.contains(sessionID) }

        func isUnread(path: String, latestCompletionID: String?, modifiedAt: Date) -> Bool {
            if manuallyUnreadSessionPaths.contains(path) { return true }
            if let latest = latestCompletionID ?? latestCompletedEntryIDBySessionPath[path] {
                return lastSeenCompletedEntryIDBySessionPath[path] != latest
            }
            guard let viewed = lastReadAt[path] else { return false }
            return modifiedAt > viewed
        }
    }

    static func load(from url: URL = AppStatePeek.defaultURL()) -> Snapshot {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Snapshot() }
        // The app writes this file with a plain, default-configured `JSONEncoder` (no ISO 8601
        // strategy), so `Date` fields are `.deferredToDate` (seconds since the 2001 reference
        // date) \u2014 a plain decoder matches that; `PiDeskJSON.decoder` would reject every date.
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    static func defaultURL() -> URL {
        PiDeskPaths.supportDirectory.appendingPathComponent("state.json")
    }
}
