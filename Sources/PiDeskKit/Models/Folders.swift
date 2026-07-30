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
    /// Standardized real project path → virtual folder id. Absent from older daemons.
    public var projectAssignments: [String: String]

    public init(
        folders: [FolderNode],
        assignments: [String: String],
        projectAssignments: [String: String] = [:]
    ) {
        self.folders = folders
        self.assignments = assignments
        self.projectAssignments = projectAssignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([FolderNode].self, forKey: .folders) ?? []
        assignments = try container.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:]
        projectAssignments = try container.decodeIfPresent([String: String].self, forKey: .projectAssignments) ?? [:]
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
    /// The deepest folder the app's own sidebar renders (`PiTheme.sidebarMaxFolderDepth`): a
    /// folder *at* this depth is shown and its children are not, so the two agree on the boundary
    /// rather than the phone hiding a folder the Mac displays. A second, independent guard on top
    /// of the cycle check, so hand-edited state cannot make this recurse without bound.
    public static let maxDepth = 24

    public static func groupID(forFolderID id: String) -> String { "virtual:\(id)" }

    public static func folderID(fromGroupID groupID: String) -> String? {
        groupID.hasPrefix("virtual:") ? String(groupID.dropFirst("virtual:".count)) : nil
    }

    private static func normalizedProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func normalizedGroupID(_ groupID: String) -> String {
        folderID(fromGroupID: groupID) == nil ? normalizedProjectPath(groupID) : groupID
    }

    private static func rawParentGroupID(
        of groupID: String,
        folders: [StoredVirtualFolder],
        projectAssignments: [String: String]
    ) -> String? {
        if let id = folderID(fromGroupID: groupID) {
            return folders.first(where: { $0.id == id })?.parentID.map(normalizedGroupID)
        }
        let path = normalizedProjectPath(groupID)
        guard let id = projectAssignments[path], folders.contains(where: { $0.id == id }) else { return nil }
        return self.groupID(forFolderID: id)
    }

    private static func wouldCreateGroupCycle(
        moving groupID: String,
        into parentGroupID: String,
        folders: [StoredVirtualFolder],
        projectAssignments: [String: String]
    ) -> Bool {
        let movingID = normalizedGroupID(groupID)
        var current: String? = normalizedGroupID(parentGroupID)
        var visited: Set<String> = [movingID]
        while let node = current {
            guard visited.insert(node).inserted else { return true }
            current = rawParentGroupID(of: node, folders: folders, projectAssignments: projectAssignments)
        }
        return false
    }

    private static func effectiveParentID(
        ofGroupID groupID: String,
        folders: [StoredVirtualFolder],
        projectAssignments: [String: String]
    ) -> String? {
        let groupID = normalizedGroupID(groupID)
        guard let parent = rawParentGroupID(
            of: groupID, folders: folders, projectAssignments: projectAssignments
        ) else { return nil }
        if let id = folderID(fromGroupID: parent), !folders.contains(where: { $0.id == id }) { return nil }
        return wouldCreateGroupCycle(
            moving: groupID, into: parent, folders: folders, projectAssignments: projectAssignments
        ) ? nil : parent
    }

    /// Every virtual folder exactly once, depth-first through the alternating virtual/project
    /// tree. Project wrappers are traversed but do not consume virtual-folder depth.
    public static func nodes(
        from folders: [StoredVirtualFolder],
        projectAssignments: [String: String] = [:]
    ) -> [FolderNode] {
        var seenIDs: Set<String> = []
        let unique = folders.filter { seenIDs.insert($0.id).inserted }
        let virtualByGroupID = Dictionary(uniqueKeysWithValues: unique.map { (groupID(forFolderID: $0.id), $0) })
        var projectPaths = Set(projectAssignments.keys.map(normalizedProjectPath))
        for folder in unique {
            guard let parent = effectiveParentID(
                ofGroupID: groupID(forFolderID: folder.id),
                folders: unique,
                projectAssignments: projectAssignments
            ), folderID(fromGroupID: parent) == nil else { continue }
            projectPaths.insert(parent)
        }

        var childrenByParent: [String: [String]] = [:]
        for groupID in virtualByGroupID.keys {
            let parent = effectiveParentID(
                ofGroupID: groupID,
                folders: unique,
                projectAssignments: projectAssignments
            ) ?? ""
            childrenByParent[parent, default: []].append(groupID)
        }
        for path in projectPaths {
            let parent = effectiveParentID(
                ofGroupID: path,
                folders: unique,
                projectAssignments: projectAssignments
            ) ?? ""
            childrenByParent[parent, default: []].append(path)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort { lhs, rhs in
                guard let left = virtualByGroupID[lhs] else { return virtualByGroupID[rhs] == nil && lhs < rhs }
                guard let right = virtualByGroupID[rhs] else { return true }
                let leftDate = left.createdAt ?? .distantPast
                let rightDate = right.createdAt ?? .distantPast
                return leftDate == rightDate ? left.id < right.id : leftDate < rightDate
            }
        }

        func walk(parentGroupID: String, depth: Int) -> [FolderNode] {
            guard depth <= maxDepth else { return [] }
            return (childrenByParent[parentGroupID] ?? []).flatMap { groupID -> [FolderNode] in
                guard let folder = virtualByGroupID[groupID] else {
                    return walk(parentGroupID: groupID, depth: depth)
                }
                let node = FolderNode(
                    id: folder.id,
                    name: folder.name,
                    parentId: parentGroupID.isEmpty ? nil : parentGroupID,
                    depth: depth
                )
                return [node] + (depth == maxDepth ? [] : walk(
                    parentGroupID: groupID,
                    depth: depth + 1
                ))
            }
        }

        return walk(parentGroupID: "", depth: 0)
    }

    /// Drops assignments pointing at folders that were not rendered and project moves whose
    /// target is missing or cyclic.
    public static func response(
        folders: [StoredVirtualFolder],
        assignments: [String: String],
        projectAssignments: [String: String] = [:]
    ) -> FolderTreeResponse {
        let standardizedProjects = Dictionary(
            projectAssignments.map { (normalizedProjectPath($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let nodes = nodes(from: folders, projectAssignments: standardizedProjects)
        let valid = Set(nodes.map(\.id))
        let projects = standardizedProjects.filter { path, folderID in
            valid.contains(folderID) && effectiveParentID(
                ofGroupID: path,
                folders: folders,
                projectAssignments: standardizedProjects
            ) == groupID(forFolderID: folderID)
        }
        return FolderTreeResponse(
            folders: nodes,
            assignments: assignments.filter { valid.contains($0.value) },
            projectAssignments: projects
        )
    }
}
