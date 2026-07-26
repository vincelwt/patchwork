import XCTest
@testable import PiDeskWeb

final class WebPlaceholderTests: XCTestCase {
    func testUnknownPathHasNoAsset() { XCTAssertNil(PiDeskWeb.asset(for: "/nope")) }
}
