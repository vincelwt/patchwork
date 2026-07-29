import Foundation

/// App-created git worktrees for conversations. They live under `~/.pi/worktrees` so a project
/// folder never accumulates scratch checkouts, and every path this app deletes is provably one
/// it created (`isManaged`).
enum WorktreeService {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi", isDirectory: true)
        .appendingPathComponent("worktrees", isDirectory: true)
        .standardizedFileURL

    /// The one guard every destructive path goes through: only directories inside `root` are
    /// ever removed, so a real project checkout can never be deleted by retention.
    static func isManaged(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    /// Git failures are surfaced as one already-user-readable line, never a raw stderr dump.
    struct Failure: Error { let message: String }

    static func create(from repository: URL, now: Date = Date()) async -> Result<URL, Failure> {
        await Task.detached(priority: .userInitiated) { createSync(from: repository, now: now) }.value
    }

    /// Non-force on purpose: git refuses to remove a worktree that still holds uncommitted work,
    /// which is exactly the outcome retention wants. The branch always survives either way.
    @discardableResult
    static func remove(at path: URL) async -> Bool {
        await Task.detached(priority: .utility) { removeSync(at: path) }.value
    }

    /// `<repo>-<timestamp>`; the timestamp is what keeps repeated worktrees off one repo unique.
    static func slug(forRepositoryNamed name: String, now: Date) -> String {
        "\(name)-\(stampFormatter.string(from: now))"
    }

    /// Branch off the repository's main line rather than whatever is checked out, so a worktree
    /// never inherits another task's in-progress branch.
    static func baseRef(candidates: [String], exists: (String) -> Bool) -> String {
        candidates.first(where: exists) ?? "HEAD"
    }

    private static let mainLineCandidates = ["origin/main", "origin/master", "main", "master"]

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func createSync(from repository: URL, now: Date) -> Result<URL, Failure> {
        let topLevel = GitService.run(["-C", repository.path, "rev-parse", "--show-toplevel"])
        let repositoryPath = topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard topLevel.status == 0, !repositoryPath.isEmpty else {
            return .failure(Failure(message: "\(repository.lastPathComponent) is not a git repository."))
        }
        let name = URL(fileURLWithPath: repositoryPath).lastPathComponent
        let path = root.appendingPathComponent(slug(forRepositoryNamed: name, now: now), isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            return .failure(Failure(message: "Could not create \(root.path)."))
        }
        let base = baseRef(candidates: mainLineCandidates) { candidate in
            GitService.run(["-C", repositoryPath, "rev-parse", "--verify", "--quiet", candidate]).status == 0
        }
        let branch = "pi/\(path.lastPathComponent)"
        let added = GitService.run(["-C", repositoryPath, "worktree", "add", "-b", branch, path.path, base])
        guard added.status == 0 else { return .failure(Failure(message: "Could not create a worktree off \(base).")) }
        return .success(path.standardizedFileURL)
    }

    private static func removeSync(at path: URL) -> Bool {
        guard isManaged(path), FileManager.default.fileExists(atPath: path.path) else { return false }
        // `worktree remove` has to run from another checkout of the same repository; the common
        // git dir's parent is the main one.
        let common = GitService.run(["-C", path.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let commonPath = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard common.status == 0, !commonPath.isEmpty else { return false }
        let main = URL(fileURLWithPath: commonPath).deletingLastPathComponent().path
        return GitService.run(["-C", main, "worktree", "remove", path.path]).status == 0
    }
}

/// Finds the pull/merge request a conversation opened, so the header can link straight to it.
enum PullRequestLink {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https://(?:github\.com|gitlab\.com)/[\w.\-]+/[\w.\-]+/(?:pull|merge_requests|-/merge_requests)/(\d+)"#
    )
    /// Bounds: a transcript can be enormous, and a PR is announced near the end of the work.
    private static let scannedMessageLimit = 200
    private static let scannedCharacterLimit = 20_000

    /// The most recently mentioned link wins, so a conversation that opens a second PR points at
    /// the second one.
    static func latest(in messages: [ChatMessage]) -> URL? {
        for message in messages.suffix(scannedMessageLimit).reversed() {
            guard let url = firstLink(in: String(message.textContent.prefix(scannedCharacterLimit))) else { continue }
            return url
        }
        return nil
    }

    /// The last match in one blob: `gh pr create` prints the URL after any earlier context.
    static func firstLink(in text: String) -> URL? {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    /// `#482` for the toolbar chip.
    static func number(in url: URL) -> String? {
        url.pathComponents.last.flatMap { Int($0) }.map { "#\($0)" }
    }
}
