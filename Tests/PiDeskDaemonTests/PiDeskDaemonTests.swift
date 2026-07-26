import XCTest
@testable import PiDeskKit

final class DaemonPlaceholderTests: XCTestCase {
    func testApiVersionIsPinned() { XCTAssertEqual(PiDeskKit.apiVersion, 1) }
}
