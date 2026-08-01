import Foundation
import XCTest
@testable import Patchwork

final class CommandLineToolInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("patchwork-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPlainFileAtTheDestinationReadsAsNotOurs() throws {
        // A real binary at the destination is the user's, not ours. The installer classifies it
        // by asking for a symlink target, which throws for a plain file — pin that, since the
        // whole "never clobber" rule rests on it.
        let occupied = directory.appendingPathComponent("patchwork")
        try Data("#!/bin/sh\n".utf8).write(to: occupied)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path))
    }

    func testASymlinkIntoAnAppBundleReadsAsOurs() throws {
        let target = directory.appendingPathComponent("Patchwork.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let tool = target.appendingPathComponent("patchwork")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        let link = directory.appendingPathComponent("patchwork-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertTrue(resolved.contains("Patchwork.app/Contents/Helpers/"))
    }

    func testTheDestinationSitsBesidePiItself() {
        XCTAssertTrue(CommandLineToolInstaller.destination.path.hasSuffix("/.local/bin/patchwork"))
        XCTAssertEqual(
            CommandLineToolInstaller.destinationDirectory.lastPathComponent,
            "bin"
        )
    }

    func testOutsideAPackagedAppInstallationIsHonestlyUnavailable() {
        // The test host is not a `.app`, so there is no bundled helper to link.
        XCTAssertNil(CommandLineToolInstaller.bundledTool)
        XCTAssertEqual(CommandLineToolInstaller.state(), .unavailable)
        XCTAssertThrowsError(try CommandLineToolInstaller.install()) { error in
            XCTAssertEqual(error as? CommandLineToolInstaller.InstallError, .notPackaged)
        }
    }

    func testOwnedLegacySymlinkMigratesWithoutTouchingOtherFiles() throws {
        let oldHelper = directory.appendingPathComponent("Pi Desktop.app/Contents/Helpers", isDirectory: true)
        let newHelper = directory.appendingPathComponent("Patchwork.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHelper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newHelper, withIntermediateDirectories: true)
        let oldTool = oldHelper.appendingPathComponent("pidesk")
        let newTool = newHelper.appendingPathComponent("patchwork")
        try Data("old".utf8).write(to: oldTool)
        try Data("new".utf8).write(to: newTool)
        let legacy = directory.appendingPathComponent("pidesk")
        let destination = directory.appendingPathComponent("patchwork")
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: oldTool)

        XCTAssertTrue(CommandLineToolInstaller.migrateLegacyInstallation(
            legacy: legacy,
            destination: destination,
            bundledTool: newTool
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
        XCTAssertEqual(URL(fileURLWithPath: target).standardizedFileURL, newTool.standardizedFileURL)
    }
}
