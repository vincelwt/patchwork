import XCTest
@testable import PiDeskKit

final class PiDeskPathsTests: XCTestCase {
    func testControlPlaneFilesLiveBesideAppStateAndNeverInsideSessionData() {
        XCTAssertTrue(PiDeskPaths.controlSocket.path.hasSuffix("Pi Desktop/daemon.sock"))
        XCTAssertTrue(PiDeskPaths.schedules.path.hasSuffix("Pi Desktop/schedules.json"))
        XCTAssertFalse(PiDeskPaths.supportDirectory.path.contains(".pi/agent/sessions"))
        XCTAssertTrue(PiDeskPaths.activityDirectory.path.hasSuffix(".pi/agent/desktop-activity"))
    }
}
