import XCTest
@testable import PatchworkKit

final class PatchworkPathsTests: XCTestCase {
    func testControlPlaneFilesLiveBesideAppStateAndNeverInsideSessionData() {
        XCTAssertTrue(PatchworkPaths.controlSocket.path.hasSuffix("Patchwork/daemon.sock"))
        XCTAssertTrue(PatchworkPaths.schedules.path.hasSuffix("Patchwork/schedules.json"))
        XCTAssertFalse(PatchworkPaths.supportDirectory.path.contains(".pi/agent/sessions"))
        XCTAssertTrue(PatchworkPaths.activityDirectory.path.hasSuffix(".pi/agent/patchwork-activity"))
    }
}
