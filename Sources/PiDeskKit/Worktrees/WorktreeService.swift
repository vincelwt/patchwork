import Foundation

/// Git worktrees created for Pi conversations. They live under `~/.pi/worktrees`, branch from
/// the repository's main line, and are removed non-force so uncommitted work always survives.
public enum WorktreeService {
    public static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi", isDirectory: true)
        .appendingPathComponent("worktrees", isDirectory: true)
        .standardizedFileURL

    public struct Failure: Error, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public static func isManaged(_ url: URL, root: URL = root) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    public static func create(
        from repository: URL,
        root: URL = root,
        now: Date = Date()
    ) async -> Result<URL, Failure> {
        await Task.detached(priority: .userInitiated) {
            createSync(from: repository, root: root.standardizedFileURL, now: now)
        }.value
    }

    @discardableResult
    public static func remove(at path: URL, root: URL = root) async -> Bool {
        await Task.detached(priority: .utility) {
            removeSync(at: path, root: root.standardizedFileURL)
        }.value
    }

    public static func slug(forRepositoryNamed name: String, now: Date) -> String {
        "\(name)-\(stampFormatter.string(from: now))"
    }

    public static func baseRef(candidates: [String], exists: (String) -> Bool) -> String {
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

    private static func createSync(from repository: URL, root: URL, now: Date) -> Result<URL, Failure> {
        let topLevel = runGit(["-C", repository.path, "rev-parse", "--show-toplevel"])
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
            runGit(["-C", repositoryPath, "rev-parse", "--verify", "--quiet", candidate]).status == 0
        }
        let branch = "pi/\(path.lastPathComponent)"
        let added = runGit(["-C", repositoryPath, "worktree", "add", "-b", branch, path.path, base])
        guard added.status == 0 else { return .failure(Failure(message: "Could not create a worktree off \(base).")) }
        return .success(path.standardizedFileURL)
    }

    private static func removeSync(at path: URL, root: URL) -> Bool {
        guard isManaged(path, root: root), FileManager.default.fileExists(atPath: path.path) else { return false }
        let common = runGit(["-C", path.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let commonPath = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard common.status == 0, !commonPath.isEmpty else { return false }
        let main = URL(fileURLWithPath: commonPath).deletingLastPathComponent().path
        return runGit(["-C", main, "worktree", "remove", path.path]).status == 0
    }

    private static func runGit(_ arguments: [String], timeout: TimeInterval = 15) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
