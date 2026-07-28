import PiDeskKit
import XCTest
@testable import PiDeskCLI

final class DaemonModeClassifierTests: XCTestCase {
    func testLaunchAgentWinsEvenWhenCurrentlyUnreachable() {
        XCTAssertEqual(
            DaemonModeClassifier.classify(launchAgentLoaded: true, healthReachable: false, ownedByApp: true),
            .launchAgent
        )
    }

    func testLaunchAgentWinsOverAppOwnership() {
        XCTAssertEqual(
            DaemonModeClassifier.classify(launchAgentLoaded: true, healthReachable: true, ownedByApp: true),
            .launchAgent
        )
    }

    func testNotRunningWhenNothingIsReachable() {
        XCTAssertEqual(
            DaemonModeClassifier.classify(launchAgentLoaded: false, healthReachable: false, ownedByApp: false),
            .notRunning
        )
    }

    func testAppManagedWhenReachableAndOwned() {
        XCTAssertEqual(
            DaemonModeClassifier.classify(launchAgentLoaded: false, healthReachable: true, ownedByApp: true),
            .appManaged
        )
    }

    func testExternalWhenReachableButNotOwned() {
        XCTAssertEqual(
            DaemonModeClassifier.classify(launchAgentLoaded: false, healthReachable: true, ownedByApp: false),
            .external
        )
    }
}

final class DaemonOwnershipTests: XCTestCase {
    func testNoRecordIsNeverLive() {
        XCTAssertFalse(DaemonOwnership.isLive(nil))
    }

    func testDeadPidRecordIsNotLive() {
        let record = DaemonOwnerRecord(pid: 4242, startedAt: Date())
        XCTAssertFalse(DaemonOwnership.isLive(record, isAlive: { _ in false }))
    }

    func testAlivePidRecordIsLive() {
        let record = DaemonOwnerRecord(pid: 4242, startedAt: Date())
        XCTAssertTrue(DaemonOwnership.isLive(record, isAlive: { _ in true }))
    }

    func testRoundTripsThroughDisk() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("daemon-owner.json")
        let record = DaemonOwnerRecord(pid: 999, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try PiDeskFile.writeAtomic(record, to: url)
        XCTAssertEqual(DaemonOwnership.read(from: url), record)
    }

    func testMissingFileReadsAsNil() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(DaemonOwnership.read(from: dir.appendingPathComponent("nope.json")))
    }
}
