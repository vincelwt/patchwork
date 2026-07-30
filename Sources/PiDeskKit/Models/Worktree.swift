import Foundation

/// One checkout of a git repository: the main one, or a linked worktree already created on the
/// Mac. This model is the read-only projection returned by `GET /v1/worktrees`.
public struct GitWorktreeEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    /// Last path component, for a phone-sized label.
    public var name: String
    /// Short branch name, absent for a detached or bare checkout.
    public var branch: String?
    /// True for the repository's main checkout, false for a linked worktree.
    public var isMain: Bool

    public init(path: String, name: String, branch: String? = nil, isMain: Bool = false) {
        self.path = path
        self.name = name
        self.branch = branch
        self.isMain = isMain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isMain = try container.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
    }
}

/// `GET /v1/worktrees?cwd=…`. A directory that is not a git repository answers with an empty
/// list, never an error: "no worktrees to choose from" is a normal answer, not a failure.
public struct WorktreeListResponse: Codable, Sendable {
    public var worktrees: [GitWorktreeEntry]

    public init(worktrees: [GitWorktreeEntry]) { self.worktrees = worktrees }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktrees = try container.decodeIfPresent([GitWorktreeEntry].self, forKey: .worktrees) ?? []
    }
}
