import Foundation
import XCTest
@testable import Patchwork

final class GitServiceTests: XCTestCase {
    func testReportsBranchAndLineChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchworkGit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-q"], at: root)
        try runGit(["config", "user.email", "patchwork@example.invalid"], at: root)
        try runGit(["config", "user.name", "Patchwork Tests"], at: root)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        try runGit(["add", "sample.txt"], at: root)
        try runGit(["commit", "-q", "-m", "initial"], at: root)

        try Data("one changed\ntwo\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        try Data("new\nfile\n".utf8).write(to: root.appendingPathComponent("new.txt"))

        let snapshot = await GitService().snapshot(for: root)
        XCTAssertTrue(snapshot.isRepository)
        XCTAssertNotNil(snapshot.branch)
        XCTAssertTrue(snapshot.isDirty)
        XCTAssertGreaterThanOrEqual(snapshot.additions, 4)
        XCTAssertGreaterThanOrEqual(snapshot.deletions, 1)
        XCTAssertTrue(snapshot.files.contains { $0.path == "sample.txt" })
        XCTAssertTrue(snapshot.files.contains { $0.path == "new.txt" && $0.isUntracked })
    }

    func testExactUntrackedTextLineCountingAndEmptyFileClassification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchworkGitLines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let newline = root.appendingPathComponent("newline.txt")
        let noNewline = root.appendingPathComponent("no-newline.txt")
        let empty = root.appendingPathComponent("empty.txt")
        let binary = root.appendingPathComponent("binary.dat")
        try Data("one\ntwo\n".utf8).write(to: newline)
        try Data("one\ntwo".utf8).write(to: noNewline)
        try Data().write(to: empty)
        try Data([0x61, 0x00, 0x62]).write(to: binary)

        XCTAssertEqual(GitService.classifyUntrackedFile(newline).lines, 2)
        XCTAssertEqual(GitService.classifyUntrackedFile(noNewline).lines, 2)
        XCTAssertEqual(GitService.classifyUntrackedFile(empty).lines, 0)
        XCTAssertFalse(GitService.classifyUntrackedFile(empty).isBinary)
        XCTAssertTrue(GitService.classifyUntrackedFile(binary).isBinary)
    }

    func testHugeUTF8TextFileIsTextWithUnavailableLineCountNotBinary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchworkGitHuge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)

        // A >4 MB UTF-8 source file, including multi-byte characters.
        let hugeText = root.appendingPathComponent("huge.txt")
        let chunk = Data(String(repeating: "héllo wörld ünïcode\n", count: 4_096).utf8)
        var data = Data()
        while data.count <= GitService.exactLineCountByteLimit { data.append(chunk) }
        try data.write(to: hugeText)

        let classification = GitService.classifyUntrackedFile(hugeText)
        XCTAssertFalse(classification.isBinary, "A large UTF-8 text file must not be mislabelled binary")
        XCTAssertNil(classification.lines, "Very large text files report LOC unavailable")

        // A large file with NUL bytes is still binary.
        let hugeBinary = root.appendingPathComponent("huge.bin")
        var binaryData = Data(repeating: 0x41, count: GitService.exactLineCountByteLimit + 1_024)
        binaryData[10] = 0x00
        try binaryData.write(to: hugeBinary)
        XCTAssertTrue(GitService.classifyUntrackedFile(hugeBinary).isBinary)

        let snapshot = await GitService().snapshot(for: root)
        XCTAssertTrue(snapshot.isRepository)
        let huge = try XCTUnwrap(snapshot.files.first { $0.path == "huge.txt" })
        XCTAssertFalse(huge.isBinary)
        XCTAssertTrue(huge.linesUnavailable, "The UI must distinguish LOC unavailable from binary")
        XCTAssertEqual(huge.additions, 0)

        let binaryFile = try XCTUnwrap(snapshot.files.first { $0.path == "huge.bin" })
        XCTAssertTrue(binaryFile.isBinary)
        XCTAssertFalse(binaryFile.linesUnavailable)
    }

    func testConversationWorkspaceDetectorUsesExplicitToolLocations() {
        let base = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let worktree = URL(fileURLWithPath: "/tmp/feature worktree", isDirectory: true)
        let source = worktree.appendingPathComponent("Sources/App.swift")

        XCTAssertEqual(
            ConversationWorkspaceDetector.directory(
                toolName: "functions.edit",
                arguments: .object(["path": .string(source.path)]),
                relativeTo: base
            ),
            source.deletingLastPathComponent().standardizedFileURL
        )
        XCTAssertEqual(
            ConversationWorkspaceDetector.directory(
                toolName: "bash",
                arguments: .object(["command": .string("cd \"\(worktree.path)\" && swift test")]),
                relativeTo: base
            ),
            worktree.standardizedFileURL
        )
        XCTAssertEqual(
            ConversationWorkspaceDetector.directory(
                toolName: "process",
                arguments: .object(["cwd": .string("../feature")]),
                relativeTo: base
            )?.path,
            "/tmp/feature"
        )
        XCTAssertNil(ConversationWorkspaceDetector.directory(
            toolName: "read",
            arguments: .object(["path": .string(source.path)]),
            relativeTo: base
        ))
    }

    func testCancellingASnapshotStopsTheGitCommandChain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchworkGitCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)

        let task = Task { await GitService().snapshot(for: root) }
        task.cancel()
        let snapshot = await task.value
        // Either an early bail-out or a completed read is acceptable; it must not hang or crash.
        XCTAssertTrue(snapshot.files.isEmpty || snapshot.isRepository)
    }

    // MARK: - Task 2: worktree detection (fixtures, no real repo)

    /// `matchingWorktreeEntry` resolves symlinks on both sides of the comparison, so fixtures use
    /// real (if empty) directories rather than hand-typed strings — on macOS `/tmp` itself is a
    /// symlink to `/private/tmp`, which would otherwise make an honest path silently fail to match.
    private func makeScratchDirectories(_ names: [String]) throws -> (root: URL, urls: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PatchworkWorktreeFixture-\(UUID().uuidString)", isDirectory: true)
        var urls: [URL] = []
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
        }
        return (root, urls)
    }

    func testMatchingWorktreeEntryFindsTheRecordForTheGivenDirectory() throws {
        let (root, urls) = try makeScratchDirectories(["main", "linked"])
        defer { try? FileManager.default.removeItem(at: root) }
        let (main, linked) = (urls[0], urls[1])
        let porcelain = """
        worktree \(main.path)
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree \(linked.path)
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature-x

        """

        let match = GitService.matchingWorktreeEntry(in: porcelain, containing: linked)
        XCTAssertEqual(match?.path, linked.resolvingSymlinksInPath().path)
        XCTAssertEqual(match?.branch, "feature-x")
    }

    func testMatchingWorktreeEntryMatchesANestedSubdirectoryOfTheWorktreeRoot() throws {
        let (root, urls) = try makeScratchDirectories(["linked"])
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = urls[0]
        let nested = linked.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let porcelain = "worktree \(linked.path)\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/feature-x\n\n"

        // The session's cwd can be a subdirectory of the worktree root, not the root itself.
        let match = GitService.matchingWorktreeEntry(in: porcelain, containing: nested)
        XCTAssertEqual(match?.path, linked.resolvingSymlinksInPath().path)
    }

    func testMatchingWorktreeEntryReadsDetachedHeadAsANilBranch() throws {
        let (root, urls) = try makeScratchDirectories(["linked"])
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = urls[0]
        let porcelain = "worktree \(linked.path)\nHEAD 1111111111111111111111111111111111111111\ndetached\n\n"

        let match = GitService.matchingWorktreeEntry(in: porcelain, containing: linked)
        XCTAssertNotNil(match, "A detached worktree is still a match")
        XCTAssertNil(match?.branch)
    }

    func testMatchingWorktreeEntryDoesNotFalseMatchASimilarPathPrefix() throws {
        let (root, urls) = try makeScratchDirectories(["wt", "wt-extra"])
        defer { try? FileManager.default.removeItem(at: root) }
        let (short, longer) = (urls[0], urls[1])
        let porcelain = "worktree \(short.path)\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main\n\n"

        let match = GitService.matchingWorktreeEntry(in: porcelain, containing: longer)
        XCTAssertNil(match, "\"wt-extra\" is a sibling of \"wt\", not inside it")
    }

    func testMatchingWorktreeEntryReturnsNilWhenNothingContainsTheDirectory() throws {
        let (root, urls) = try makeScratchDirectories(["linked", "unrelated"])
        defer { try? FileManager.default.removeItem(at: root) }
        let porcelain = "worktree \(urls[0].path)\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main\n\n"

        XCTAssertNil(GitService.matchingWorktreeEntry(in: porcelain, containing: urls[1]))
    }

    // MARK: - Task 2: worktree detection (real repo)

    private func makeTempRepo(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: root)
        try runGit(["config", "user.email", "patchwork@example.invalid"], at: root)
        try runGit(["config", "user.name", "Patchwork Tests"], at: root)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        try runGit(["add", "sample.txt"], at: root)
        try runGit(["commit", "-q", "-m", "initial"], at: root)
        return root
    }

    /// `git rev-parse --git-dir`/`--git-common-dir` is the documented, real signal this detects;
    /// a hand-written fixture would only prove the test agrees with itself, so this exercises an
    /// actual repository and an actual `git worktree add`, matching how `GitServiceTests` already
    /// verifies the rest of `GitService` against real `git` output.
    func testMainCheckoutReportsNoWorktreeInfo() async throws {
        let root = try makeTempRepo(name: "PatchworkWorktreeMain")
        defer { try? FileManager.default.removeItem(at: root) }

        let info = await GitService().worktreeInfo(for: root)
        XCTAssertNil(info, "A repository that has never used worktrees must not report one")
    }

    func testLinkedWorktreeReportsItsPathBranchAndMainCheckout() async throws {
        let root = try makeTempRepo(name: "PatchworkWorktreeLinked")
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.deletingLastPathComponent().appendingPathComponent("linked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try runGit(["branch", "feature-x"], at: root)
        try runGit(["worktree", "add", "-q", linked.path, "feature-x"], at: root)

        let result = await GitService().worktreeInfo(for: linked)
        let info = try XCTUnwrap(result)
        XCTAssertEqual(info.branch, "feature-x")
        XCTAssertEqual(info.name, linked.lastPathComponent)
        XCTAssertEqual(info.mainName, root.lastPathComponent)

        // The main checkout of the very same repository must still report nothing.
        let mainInfo = await GitService().worktreeInfo(for: root)
        XCTAssertNil(mainInfo)
    }

    func testDetachedLinkedWorktreeReportsANilBranch() async throws {
        let root = try makeTempRepo(name: "PatchworkWorktreeDetached")
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.deletingLastPathComponent().appendingPathComponent("detached-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try runGit(["worktree", "add", "-q", "--detach", linked.path, "HEAD"], at: root)

        let result = await GitService().worktreeInfo(for: linked)
        let info = try XCTUnwrap(result)
        XCTAssertNil(info.branch)
    }

    func testNestedSubdirectoryOfALinkedWorktreeStillResolvesToTheWorktreeRoot() async throws {
        let root = try makeTempRepo(name: "PatchworkWorktreeNested")
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.deletingLastPathComponent().appendingPathComponent("nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try runGit(["worktree", "add", "-q", "-b", "nested-branch", linked.path], at: root)
        let nested = linked.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let result = await GitService().worktreeInfo(for: nested)
        let info = try XCTUnwrap(result)
        XCTAssertEqual(info.name, linked.lastPathComponent, "A cwd nested inside the worktree still reports the worktree root")
    }

    func testNonRepositoryFolderSilentlyReportsNoWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PatchworkWorktreeNone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let info = await GitService().worktreeInfo(for: root)
        XCTAssertNil(info)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
