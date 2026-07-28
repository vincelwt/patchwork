import Foundation

protocol GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot
    /// Whether `directory` resolves inside a *linked* git worktree rather than the main
    /// checkout, and which one. `nil` when the folder is not a repository, is the main checkout,
    /// or detection otherwise fails — always a silent degrade, never a surfaced error.
    func worktreeInfo(for directory: URL) async -> GitWorktreeInfo?
}

/// Defaulted so existing conformers (test fakes that only exercise `snapshot(for:)`) never need
/// to change for a feature they do not test.
extension GitStatusProviding {
    func worktreeInfo(for directory: URL) async -> GitWorktreeInfo? { nil }
}

/// Present only when the inspected directory is a linked worktree. `name`/`mainName` are last
/// path components, sized for a compact inspector row; full paths back its tooltip.
struct GitWorktreeInfo: Hashable, Sendable {
    let path: String
    let branch: String?
    let mainWorktreePath: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var mainName: String { URL(fileURLWithPath: mainWorktreePath).lastPathComponent }
}

/// Finds explicit workspace moves in tool calls. Reads are intentionally ignored: inspecting a
/// file elsewhere does not move the conversation, while an explicit cwd or edited file does.
enum ConversationWorkspaceDetector {
    private static let directoryKeys: Set<String> = [
        "cwd", "workdir", "workingdirectory", "working_directory", "worktreepath", "worktree_path"
    ]
    private static let fileKeys: Set<String> = ["path", "file", "file_path"]
    private static let shellDirectoryPattern = try! NSRegularExpression(
        pattern: #"(?:^|[;&|]\s*)(?:cd|git\s+-C)\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))"#
    )

    static func latestDirectory(in messages: [ChatMessage], relativeTo base: URL) -> URL? {
        for message in messages.reversed() {
            for block in message.blocks.reversed() {
                guard case let .toolCall(call) = block.kind,
                      let directory = directory(toolName: call.name, arguments: call.arguments, relativeTo: base)
                else { continue }
                return directory
            }
        }
        return nil
    }

    static func directory(toolName: String, arguments: JSONValue, relativeTo base: URL) -> URL? {
        let name = toolName.split(separator: ".").last.map(String.init)?.lowercased() ?? toolName.lowercased()
        if let cwd = string(in: arguments, keys: directoryKeys) {
            return resolved(cwd, relativeTo: base, isFile: false)
        }
        if ["edit", "write", "patch", "apply_patch"].contains(name),
           let path = string(in: arguments, keys: fileKeys) {
            return resolved(path, relativeTo: base, isFile: true)
        }
        guard name == "bash", let command = arguments["command"]?.stringValue,
              let path = shellDirectory(in: String(command.prefix(20_000))) else { return nil }
        return resolved(path, relativeTo: base, isFile: false)
    }

    private static func string(in arguments: JSONValue, keys: Set<String>) -> String? {
        arguments.objectValue?.first { keys.contains($0.key.lowercased()) }?.value.stringValue
    }

    private static func shellDirectory(in command: String) -> String? {
        let matches = shellDirectoryPattern.matches(
            in: command,
            range: NSRange(command.startIndex..., in: command)
        )
        guard let match = matches.last else { return nil }
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: command) else { continue }
            return String(command[range])
        }
        return nil
    }

    private static func resolved(_ raw: String, relativeTo base: URL, isFile: Bool) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4_096,
              !clean.contains("\0"), !clean.contains("$"), !clean.contains("`") else { return nil }
        let path = (clean as NSString).expandingTildeInPath
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: !isFile)
            : base.standardizedFileURL.appendingPathComponent(path, isDirectory: !isFile)
        return (isFile ? url.deletingLastPathComponent() : url).standardizedFileURL
    }
}

struct GitService: GitStatusProviding {
    /// Cancellation is propagated into the detached worker, which checks it between git
    /// invocations so an abandoned refresh stops instead of running the full command chain.
    func snapshot(for directory: URL) async -> GitSnapshot {
        let worker = Task.detached(priority: .utility) {
            Self.readSnapshot(for: directory)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Cancellation is propagated the same way `snapshot(for:)` does.
    func worktreeInfo(for directory: URL) async -> GitWorktreeInfo? {
        let worker = Task.detached(priority: .utility) {
            Self.readWorktreeInfo(for: directory)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// `git rev-parse --git-dir` differing from `--git-common-dir` is the one reliable signal for
    /// "this is a linked worktree, not the main checkout": every worktree of a repo shares one
    /// common dir, but a linked worktree's own git-dir lives under
    /// `<main>/.git/worktrees/<name>`, while the main checkout (or a repo that has never used
    /// worktrees) reports the same path for both. `worktree list --porcelain` then supplies the
    /// human-facing path/branch once that signal fires.
    private static func readWorktreeInfo(for directory: URL) -> GitWorktreeInfo? {
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let gitDirResult = run(["-C", directory.path, "rev-parse", "--git-dir"])
        let commonDirResult = run(["-C", directory.path, "rev-parse", "--git-common-dir"])
        guard gitDirResult.status == 0, commonDirResult.status == 0 else { return nil } // Not a repository.

        let gitDir = resolvedGitPath(gitDirResult.output, relativeTo: directory)
        let commonDir = resolvedGitPath(commonDirResult.output, relativeTo: directory)
        guard gitDir != commonDir else { return nil } // Main checkout, or a repo with no worktrees.

        let mainWorktreePath = URL(fileURLWithPath: commonDir).deletingLastPathComponent().path
        let topLevel = run(["-C", directory.path, "rev-parse", "--show-toplevel"])
        let worktreePath = topLevel.status == 0
            ? resolvedGitPath(topLevel.output, relativeTo: directory)
            : directory.resolvingSymlinksInPath().path
        guard !Task.isCancelled else { return nil }
        let list = run(["-C", directory.path, "worktree", "list", "--porcelain"])
        let branch = list.status == 0
            ? matchingWorktreeEntry(
                in: list.output,
                containing: URL(fileURLWithPath: worktreePath, isDirectory: true)
            )?.branch
            : nil
        return GitWorktreeInfo(path: worktreePath, branch: branch, mainWorktreePath: mainWorktreePath)
    }

    /// `--git-dir`/`--git-common-dir` can come back relative (e.g. `../../.git`) or absolute
    /// depending on how deep `directory` is inside the checkout, and git itself always resolves
    /// symlinks in what it reports; resolving them here too keeps the equality check honest even
    /// when `directory` was reached through a symlinked ancestor (e.g. macOS's `/tmp`).
    private static func resolvedGitPath(_ raw: String, relativeTo directory: URL) -> String {
        URL(fileURLWithPath: raw.trimmed, relativeTo: directory).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Parses `git worktree list --porcelain` (records are `worktree <path>` / `HEAD <sha>` /
    /// either `branch refs/heads/<name>` or `detached`, separated by a blank line) and returns
    /// the record whose path is `directory` itself or an ancestor of it — the session's cwd can
    /// be a subdirectory of the worktree root rather than the root. Exposed (not private) so it
    /// can be exercised directly against literal porcelain text, not only through a real repo.
    static func matchingWorktreeEntry(in porcelain: String, containing directory: URL) -> (path: String, branch: String?)? {
        let target = directory.resolvingSymlinksInPath().path
        var best: (path: String, branch: String?)?
        var candidatePath: String?
        var candidateBranch: String?

        func flush() {
            defer { candidatePath = nil; candidateBranch = nil }
            guard let path = candidatePath, target == path || target.hasPrefix(path + "/") else { return }
            if path.count > (best?.path.count ?? -1) { best = (path, candidateBranch) }
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                candidatePath = URL(fileURLWithPath: String(line.dropFirst("worktree ".count))).resolvingSymlinksInPath().path
            } else if line.hasPrefix("branch refs/heads/") {
                candidateBranch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return best
    }

    private static func readSnapshot(for directory: URL) -> GitSnapshot {
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: directory.path),
              run(["-C", directory.path, "rev-parse", "--is-inside-work-tree"]).status == 0
        else { return .none }

        var snapshot = GitSnapshot(isRepository: true)
        guard !Task.isCancelled else { return snapshot }
        let branchResult = run(["-C", directory.path, "symbolic-ref", "--quiet", "--short", "HEAD"])
        if branchResult.status == 0 {
            snapshot.branch = branchResult.output.trimmed.nonEmpty
        } else {
            let commit = run(["-C", directory.path, "rev-parse", "--short", "HEAD"])
            snapshot.branch = commit.output.trimmed.nonEmpty
            snapshot.isDetached = true
        }

        guard !Task.isCancelled else { return snapshot }
        let status = run(["-C", directory.path, "status", "--porcelain=v1"])
        let statusLines = status.output.split(separator: "\n", omittingEmptySubsequences: true)
        if !statusLines.isEmpty {
            let staged = statusLines.filter { $0.first != " " && $0.first != "?" }.count
            snapshot.statusHint = staged > 0
                ? "\(statusLines.count) changed · \(staged) staged"
                : "\(statusLines.count) changed"
        } else {
            snapshot.statusHint = "Clean"
        }

        guard !Task.isCancelled else { return snapshot }
        let diff = run(["-C", directory.path, "diff", "--numstat", "HEAD", "--"])
        if diff.status == 0 {
            snapshot.files = parseNumstat(diff.output)
        } else {
            // Unborn branches do not have HEAD yet; still report working-tree changes.
            let fallback = run(["-C", directory.path, "diff", "--numstat", "--"])
            snapshot.files = parseNumstat(fallback.output)
        }

        guard !Task.isCancelled else { return snapshot }
        let untracked = run(["-C", directory.path, "ls-files", "--others", "--exclude-standard", "-z"])
        if untracked.status == 0 {
            let paths = untracked.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            var existing = Set(snapshot.files.map(\.path))
            for path in paths where !existing.contains(path) {
                if Task.isCancelled { break }
                existing.insert(path)
                let fileURL = directory.appendingPathComponent(path)
                let classification = classifyUntrackedFile(fileURL)
                snapshot.files.append(GitFileChange(
                    path: path,
                    additions: classification.lines ?? 0,
                    deletions: 0,
                    isBinary: classification.isBinary,
                    isUntracked: true,
                    linesUnavailable: classification.lines == nil && !classification.isBinary
                ))
            }
        }

        snapshot.files.sort {
            ($0.additions + $0.deletions, $0.path) > ($1.additions + $1.deletions, $1.path)
        }
        return snapshot
    }

    private static func parseNumstat(_ output: String) -> [GitFileChange] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let binary = parts[0] == "-" || parts[1] == "-"
            return GitFileChange(
                path: String(parts[2]),
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0,
                isBinary: binary,
                isUntracked: false
            )
        }
    }

    /// Byte ceiling for exact line counting. Larger text files are still reported as text,
    /// but with an unavailable line count rather than being mislabelled binary.
    static let exactLineCountByteLimit = 4 * 1_024 * 1_024
    private static let binarySniffPrefix = 64 * 1_024

    /// `lines == nil` with `isBinary == false` means "text, LOC unavailable".
    static func classifyUntrackedFile(_ url: URL) -> (lines: Int?, isBinary: Bool) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return (nil, true) }

        if size > exactLineCountByteLimit {
            // Sniff only a prefix: a huge UTF-8 source file is text, not binary.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, true) }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: binarySniffPrefix), !prefix.contains(0) else {
                return (nil, true)
            }
            return (nil, false)
        }

        guard let data = try? Data(contentsOf: url) else { return (nil, true) }
        // Empty files are valid text. NUL or invalid UTF-8 is treated as binary.
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return (nil, true) }
        guard !data.isEmpty else { return (0, false) }
        let newlines = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        // A trailing newline terminates the last line; without one the final partial line counts once.
        return (newlines + (data.last == 0x0A ? 0 : 1), false)
    }

    /// stderr goes to the null device so a chatty git invocation can never fill a pipe and
    /// deadlock the worker, and a hard deadline guarantees the call returns.
    private static func run(_ arguments: [String], timeout: TimeInterval = 15) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
