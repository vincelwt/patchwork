import Foundation

/// One app-owned virtual folder, flattened for the wire. `parentId` uses the app's own group-id
/// scheme (`Sources/PiDesktop/WorkspaceOrganization.swift`): `nil` is top level, a filesystem
/// path nests the folder inside that project group, and `"virtual:<uuid>"` nests it inside
/// another folder. It is always the *effective* parent — a dangling or cyclic parent has already
/// been resolved to top level here, so a client can render the tree without any cycle logic of
/// its own.
public struct FolderNode: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var depth: Int

    public init(id: String, name: String, parentId: String? = nil, depth: Int = 0) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.depth = depth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Folder"
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
    }
}

/// `GET /v1/folders` — the app's folder tree, read-only. `assignments` maps a session's JSONL
/// path to the folder id it was filed under; an assignment naming a folder that no longer exists
/// is dropped here rather than left for the client to notice.
public struct FolderTreeResponse: Codable, Sendable {
    public var folders: [FolderNode]
    public var assignments: [String: String]

    public init(folders: [FolderNode], assignments: [String: String]) {
        self.folders = folders
        self.assignments = assignments
    }
}

/// The raw persisted folder record, exactly as the app writes it into `state.json`.
public struct StoredVirtualFolder: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var createdAt: Date?

    public init(id: String, name: String, parentID: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Folder"
        // Folders persisted before nesting existed have no `parentID` key at all.
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        // The app writes `state.json` with a default `JSONEncoder`, so dates are seconds since
        // the 2001 reference date, not ISO 8601. Decoding is best-effort: ordering falls back to
        // file order rather than failing the whole tree.
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
    }
}

/// A Swift port of the exact hierarchy rules `WorkspaceOrganization` applies in the app, kept
/// here because `PiDesktop` is an executable target that `PiDeskKit` cannot import. The two must
/// agree: same group-id scheme, same cycle/dangling-parent fallback to top level, same
/// depth-first ordering, same independent max-depth guard.
public enum FolderTree {
    /// Deeper than the app's own sidebar ever renders; a second, independent guard on top of the
    /// cycle check, so hand-edited state cannot make this recurse without bound.
    public static let maxDepth = 24

    public static func groupID(forFolderID id: String) -> String { "virtual:\(id)" }

    public static func folderID(fromGroupID groupID: String) -> String? {
        groupID.hasPrefix("virtual:") ? String(groupID.dropFirst("virtual:".count)) : nil
    }

    /// Ancestor folder ids walking up through `parentID`, nearest first. Stops at top level, at a
    /// filesystem project, or at the first repeated id, so a corrupted cycle terminates.
    static func ancestorFolderIDs(of startID: String, in folders: [StoredVirtualFolder]) -> [String] {
        var chain: [String] = []
        var visited: Set<String> = [startID]
        var currentID = startID
        while let node = folders.first(where: { $0.id == currentID }),
              let parentGroupID = node.parentID,
              let parentFolderID = folderID(fromGroupID: parentGroupID) {
            guard visited.insert(parentFolderID).inserted else { break }
            chain.append(parentFolderID)
            currentID = parentFolderID
        }
        return chain
    }

    static func wouldCreateCycle(moving movedID: String, into newParentFolderID: String, in folders: [StoredVirtualFolder]) -> Bool {
        newParentFolderID == movedID || ancestorFolderIDs(of: newParentFolderID, in: folders).contains(movedID)
    }

    /// A dangling virtual parent, or an ancestor cycle, both degrade to top level.
    static func effectiveParentID(of folder: StoredVirtualFolder, in folders: [StoredVirtualFolder]) -> String? {
        guard let parentGroupID = folder.parentID else { return nil }
        guard let parentFolderID = folderID(fromGroupID: parentGroupID) else { return parentGroupID }
        guard folders.contains(where: { $0.id == parentFolderID }),
              !wouldCreateCycle(moving: folder.id, into: parentFolderID, in: folders) else { return nil }
        return parentGroupID
    }

    /// Every folder exactly once, depth-first: the top-level subtree first, then each filesystem
    /// project that hosts folders, in first-seen order — the same shape the app's flat folder
    /// pickers use. Folders unreachable within `maxDepth` are dropped rather than rendered at a
    /// misleading depth.
    public static func nodes(from folders: [StoredVirtualFolder]) -> [FolderNode] {
        // Duplicate ids would make `first(where:)` lookups ambiguous and could double-render a
        // subtree; the first occurrence wins, exactly like a dictionary insert would.
        var seenIDs: Set<String> = []
        let unique = folders.filter { seenIDs.insert($0.id).inserted }

        var childrenByParent: [String: [StoredVirtualFolder]] = [:]
        for folder in unique {
            childrenByParent[effectiveParentID(of: folder, in: unique) ?? "", default: []].append(folder)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort { lhs, rhs in
                let left = lhs.createdAt ?? .distantPast
                let right = rhs.createdAt ?? .distantPast
                return left == right ? lhs.id < rhs.id : left < right
            }
        }

        func walk(parentGroupID: String, depth: Int) -> [FolderNode] {
            guard depth < maxDepth else { return [] }
            return (childrenByParent[parentGroupID] ?? []).flatMap { folder -> [FolderNode] in
                [FolderNode(id: folder.id, name: folder.name, parentId: parentGroupID.isEmpty ? nil : parentGroupID, depth: depth)]
                    + walk(parentGroupID: groupID(forFolderID: folder.id), depth: depth + 1)
            }
        }

        var roots = [""]
        for folder in unique {
            guard let parent = effectiveParentID(of: folder, in: unique), folderID(fromGroupID: parent) == nil,
                  !roots.contains(parent) else { continue }
            roots.append(parent)
        }
        return roots.flatMap { walk(parentGroupID: $0, depth: 0) }
    }

    /// Drops assignments pointing at folders that were never rendered (deleted, duplicated away,
    /// or beyond `maxDepth`), so a client never files a thread under a folder it cannot show.
    public static func response(folders: [StoredVirtualFolder], assignments: [String: String]) -> FolderTreeResponse {
        let nodes = nodes(from: folders)
        let valid = Set(nodes.map(\.id))
        return FolderTreeResponse(folders: nodes, assignments: assignments.filter { valid.contains($0.value) })
    }
}
