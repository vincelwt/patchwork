import XCTest
@testable import PiDeskKit

final class PiDeskPathsTests: XCTestCase {
    func testControlPlaneFilesLiveBesideAppStateAndNeverInsideSessionData() {
        XCTAssertTrue(PiDeskPaths.controlSocket.path.hasSuffix("Pi Desktop/daemon.sock"))
        XCTAssertTrue(PiDeskPaths.schedules.path.hasSuffix("Pi Desktop/schedules.json"))
        XCTAssertTrue(PiDeskPaths.submissionReplays.path.hasSuffix("Pi Desktop/submission-replays.json"))
        XCTAssertFalse(PiDeskPaths.supportDirectory.path.contains(".pi/agent/sessions"))
        XCTAssertTrue(PiDeskPaths.activityDirectory.path.hasSuffix(".pi/agent/desktop-activity"))
    }
}

final class HealthCompatibilityTests: XCTestCase {
    func testMissingMutationCapabilitiesDecodeAsUnsafeForAutomaticRetry() throws {
        let data = Data(#"{"ok":true,"version":"older","schedulesEnabled":true}"#.utf8)
        let health = try JSONDecoder().decode(HealthStatus.self, from: data)

        XCTAssertFalse(health.scheduleIdempotency)
        XCTAssertFalse(health.threadCreationIdempotency)
        XCTAssertFalse(health.messageSubmissionIdempotency)
        XCTAssertFalse(health.scheduleRunIdempotency)
    }
}
