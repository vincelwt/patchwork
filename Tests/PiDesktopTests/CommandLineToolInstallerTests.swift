import Foundation
import XCTest
@testable import PiDesktop

final class CommandLineToolInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pidesk-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPlainFileAtTheDestinationReadsAsNotOurs() throws {
        // A real binary at the destination is the user's, not ours. The installer classifies it
        // by asking for a symlink target, which throws for a plain file — pin that, since the
        // whole "never clobber" rule rests on it.
        let occupied = directory.appendingPathComponent("pidesk")
        try Data("#!/bin/sh\n".utf8).write(to: occupied)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path))
    }

    func testASymlinkIntoAnAppBundleReadsAsOurs() throws {
        let target = directory.appendingPathComponent("Pi Desktop.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let tool = target.appendingPathComponent("pidesk")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        let link = directory.appendingPathComponent("pidesk-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertTrue(resolved.contains("Pi Desktop.app/Contents/Helpers/"))
    }

    func testTheDestinationSitsBesidePiItself() {
        XCTAssertTrue(CommandLineToolInstaller.destination.path.hasSuffix("/.local/bin/pidesk"))
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
}
