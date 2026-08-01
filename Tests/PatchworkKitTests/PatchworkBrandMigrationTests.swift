import Foundation
import XCTest
@testable import PatchworkKit

final class PatchworkBrandMigrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("patchwork-brand-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testCopiesOnlyOwnedPersistentFilesAndCacheWithoutOverwritingPatchworkData() throws {
        let legacySupport = home.appendingPathComponent("Library/Application Support/Pi Desktop")
        let support = home.appendingPathComponent("Library/Application Support/Patchwork")
        try FileManager.default.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("old state".utf8).write(to: legacySupport.appendingPathComponent("state.json"))
        try Data("old schedules".utf8).write(to: legacySupport.appendingPathComponent("schedules.json"))
        try Data("socket".utf8).write(to: legacySupport.appendingPathComponent("daemon.sock"))
        try Data("new state".utf8).write(to: support.appendingPathComponent("state.json"))

        let legacyCache = home.appendingPathComponent("Library/Caches/Pi Desktop")
        try FileManager.default.createDirectory(at: legacyCache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: legacyCache.appendingPathComponent("summary.json"))

        let report = PatchworkBrandMigration.run(
            homeDirectory: home,
            commandRunner: { _, _ in XCTFail("No launch item should be touched"); return 1 }
        )

        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("state.json")), "new state")
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("schedules.json")), "old schedules")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("daemon.sock").path))
        XCTAssertEqual(report.copiedSupportFiles, ["schedules.json"])
        XCTAssertTrue(report.copiedCacheDirectory)
        XCTAssertEqual(
            try String(contentsOf: home.appendingPathComponent("Library/Caches/Patchwork/summary.json")),
            "cache"
        )
    }

    func testRetiresOnlyARecognizedLegacyLaunchAgent() throws {
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist = launchAgents.appendingPathComponent("dev.pi.desktop.daemon.plist")
        try Data("<plist><string>dev.pi.desktop.daemon</string></plist>".utf8).write(to: plist)
        var command: [String] = []

        let report = PatchworkBrandMigration.run(
            homeDirectory: home,
            commandRunner: { executable, arguments in command = [executable] + arguments; return 0 }
        )

        XCTAssertTrue(report.retiredLaunchAgent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(command.first, "/bin/launchctl")
        XCTAssertTrue(command.contains("bootout"))
        XCTAssertTrue(command.last?.hasSuffix("/dev.pi.desktop.daemon") == true)
    }
}
