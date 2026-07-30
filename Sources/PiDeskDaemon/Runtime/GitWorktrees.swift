import Foundation
import PiDeskKit

/// Read-only git worktree discovery for `GET /v1/worktrees`, so the web remote can start a thread
/// in a checkout that already exists on the Mac. It never creates, moves, or removes anything:
/// `git worktree list` is the only subcommand used, and the app's own `WorktreeService` stays the
/// only thing that writes worktrees.
///
/// Not shared with `Sources/PiDesktop/GitService.swift`: that lives in an executable target this
/// one cannot import, and porting the whole status snapshot for one `list` call would be far more
/// code than the parser below.
enum GitWorktrees {
    /// A repository with more checkouts than this is not a picker any more; the list is truncated
    /// rather than allowed to grow a response without bound.
    static let maxEntries = 64
    /// `worktree list --porcelain` on a healthy repo is a few hundred bytes per checkout. This is
    /// the ceiling on what is read into memory: reading stops at it while `git` is still running,
    /// rather than after the whole stream has already been buffered.
    static let maxOutputBytes = 256 * 1_024
    static let timeout: TimeInterval = 5

    static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    /// Every checkout of the repository containing `directory`, main first. An empty list means
    /// "not a repository, or git is unavailable"; both are ordinary answers here, not errors.
    static func list(for directory: URL, now: Date = Date()) -> [GitWorktreeEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        // The main checkout is the parent of the common git dir; every linked worktree shares it.
        let common = run(["-C", directory.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.status == 0 else { return [] }
        let commonPath = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonPath.isEmpty else { return [] }
        let mainPath = URL(fileURLWithPath: commonPath).deletingLastPathComponent().resolvingSymlinksInPath().path

        let listed = run(["-C", directory.path, "worktree", "list", "--porcelain"])
        guard listed.status == 0 else { return [] }
        return parse(listed.output, mainPath: mainPath)
    }

    /// Parses `git worktree list --porcelain`: records are `worktree <path>`, `HEAD <sha>`, then
    /// either `branch refs/heads/<name>`, `detached`, or `bare`, separated by a blank line.
    /// Exposed so it can be exercised against literal porcelain text rather than only a real repo.
    static func parse(_ porcelain: String, mainPath: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var path: String?
        var branch: String?
        var bare = false

        func flush() {
            defer { path = nil; branch = nil; bare = false }
            guard let path, !path.isEmpty, !bare, entries.count < maxEntries else { return }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let resolved = url.resolvingSymlinksInPath().path
            entries.append(GitWorktreeEntry(
                path: url.standardizedFileURL.path,
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                branch: branch,
                isMain: resolved == mainPath
            ))
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush() }
            else if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
            else if line == "bare" { bare = true }
        }
        flush()
        // Main checkout first: it is the default choice in the picker, and git already lists it
        // first on a healthy repo. This only makes that ordering guaranteed rather than assumed.
        return entries.sorted { lhs, rhs in
            lhs.isMain == rhs.isMain ? lhs.path < rhs.path : lhs.isMain
        }
    }

    /// One bounded `git` invocation: fixed executable, no shell, capped output, and a watchdog
    /// that terminates a hung process rather than parking a request handler on it.
    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return (127, "") }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // `GIT_OPTIONAL_LOCKS=0` keeps a read-only query from taking the index lock out from
        // under whatever the user is doing in that checkout.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        // Nothing reads git's diagnostics, and an unread `Pipe` would let a chatty failure fill
        // its buffer and block the child forever.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (127, "") }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let reader = stdout.fileHandleForReading
        let data = drain(reader, limit: maxOutputBytes)
        if data.count >= maxOutputBytes {
            // Past the ceiling nothing is draining the pipe any more, so git would block on its
            // next write instead of exiting. Stop it, then close the read end.
            process.terminate()
            try? reader.close()
        }
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Reads at most `limit` bytes from a handle that may still be being written to, in bounded
    /// chunks, stopping at EOF or the limit, never buffering the whole stream first.
    static func drain(_ handle: FileHandle, limit: Int) -> Data {
        var data = Data()
        while data.count < limit {
            let want = min(64 * 1_024, limit - data.count)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }
}
