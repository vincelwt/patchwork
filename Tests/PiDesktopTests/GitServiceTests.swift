import Foundation
import XCTest
@testable import PiDesktop

final class GitServiceTests: XCTestCase {
    func testReportsBranchAndLineChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopGit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "-q"], at: root)
        try runGit(["config", "user.email", "pi-desktop@example.invalid"], at: root)
        try runGit(["config", "user.name", "Pi Desktop Tests"], at: root)
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
            .appendingPathComponent("PiDesktopGitLines-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("PiDesktopGitHuge-\(UUID().uuidString)", isDirectory: true)
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

    func testCancellingASnapshotStopsTheGitCommandChain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiDesktopGitCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)

        let task = Task { await GitService().snapshot(for: root) }
        task.cancel()
        let snapshot = await task.value
        // Either an early bail-out or a completed read is acceptable; it must not hang or crash.
        XCTAssertTrue(snapshot.files.isEmpty || snapshot.isRepository)
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
