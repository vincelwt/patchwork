import CoreServices
import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

final class SessionCatalogMonitorTests: XCTestCase {
    private let piRoot = SessionObservationRoot(
        agent: .pi, url: URL(fileURLWithPath: "/tmp/pi-sessions")
    )
    private let codexRoot = SessionObservationRoot(
        agent: .codex, url: URL(fileURLWithPath: "/tmp/codex-sessions")
    )

    func testOrdinaryTranscriptAppendsNeverRescanTheCatalog() {
        let change = SessionCatalogMonitor.classify(
            paths: ["/tmp/pi-sessions/project/thread.jsonl"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)],
            roots: [piRoot]
        )

        XCTAssertTrue(change.candidatePaths.isEmpty)
        XCTAssertEqual(change.activityPaths, ["/tmp/pi-sessions/project/thread.jsonl"])
        XCTAssertFalse(change.requiresFullScan)
    }

    func testCreatedFilesRespectEachAgentsDepthAndFilenameRules() {
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let paths = [
            "/tmp/pi-sessions/project/thread.jsonl",
            "/tmp/codex-sessions/2026/08/01/rollout-valid.jsonl",
            "/tmp/codex-sessions/2026/08/01/not-a-rollout.jsonl",
            "/tmp/codex-sessions/2026/08/01/deeper/rollout-too-deep.jsonl"
        ]
        let change = SessionCatalogMonitor.classify(
            paths: paths,
            flags: Array(repeating: created, count: paths.count),
            roots: [piRoot, codexRoot]
        )

        XCTAssertEqual(change.candidatePaths, [paths[0], paths[1]])
        XCTAssertEqual(change.activityPaths, [paths[0], paths[1]])
        XCTAssertFalse(change.requiresFullScan)
    }

    func testRemovalAndDroppedEventsForceAuthoritativeReconciliation() {
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        let change = SessionCatalogMonitor.classify(
            paths: [
                "/tmp/pi-sessions/project/thread.jsonl",
                "/tmp/pi-sessions"
            ],
            flags: [removed, dropped],
            roots: [piRoot]
        )

        XCTAssertTrue(change.requiresFullScan)
        XCTAssertEqual(change.candidatePaths, ["/tmp/pi-sessions/project/thread.jsonl"])
    }

    func testFileRenameForcesRemovalReconciliationEvenWhenTheDestinationIsValid() {
        let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let path = "/tmp/pi-sessions/project/renamed.jsonl"
        let change = SessionCatalogMonitor.classify(paths: [path], flags: [renamed], roots: [piRoot])

        XCTAssertEqual(change.candidatePaths, [path])
        XCTAssertTrue(change.requiresFullScan)
    }

    func testCustomRootObservationOnlyClassifiesTheOwnedExactFile() {
        let owned = "/tmp/custom-root/owned.jsonl"
        let root = SessionObservationRoot(
            agent: .pi,
            url: URL(fileURLWithPath: "/tmp/custom-root"),
            exactFilePath: owned
        )
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)

        let change = SessionCatalogMonitor.classify(
            paths: [owned, "/tmp/custom-root/sibling.jsonl"],
            flags: [removed, created], roots: [root]
        )

        XCTAssertEqual(change.candidatePaths, [owned])
        XCTAssertTrue(change.requiresFullScan)
        XCTAssertTrue(change.activityPaths.isEmpty)
    }
}
