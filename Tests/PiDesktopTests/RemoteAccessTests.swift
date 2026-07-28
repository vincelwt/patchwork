import XCTest
@testable import PiDesktop

final class RemoteAccessTests: XCTestCase {
    func testPairingURLProducesAQRCodeImage() throws {
        let image = try XCTUnwrap(QRCode.image(for: "https://remote.ai.gloom.sh/pair/example#ticket=secret"))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(image.size.width, image.size.height)
    }
}
