import Foundation
import XCTest
@testable import PiDesktop

final class ImageViewerTests: XCTestCase {
    private func payload(_ id: String) -> ImagePayload {
        ImagePayload(id: id, data: Data([0x1]), mimeType: "image/png", fileName: "\(id).png")
    }

    func testArrowingStepsThroughTheGroupAndClampsAtBothEnds() {
        let group = [payload("a"), payload("b"), payload("c")]
        var selection = ViewedImage(image: group[1], group: group)
        XCTAssertEqual(selection.image.id, "b")
        XCTAssertTrue(selection.hasPrevious)
        XCTAssertTrue(selection.hasNext)

        selection.goToNext()
        XCTAssertEqual(selection.image.id, "c")
        XCTAssertFalse(selection.hasNext)
        selection.goToNext() // no wrap
        XCTAssertEqual(selection.image.id, "c")

        selection.goToPrevious()
        selection.goToPrevious()
        XCTAssertEqual(selection.image.id, "a")
        XCTAssertFalse(selection.hasPrevious)
        selection.goToPrevious() // no wrap
        XCTAssertEqual(selection.image.id, "a")
    }

    func testImageMissingFromItsGroupFallsBackToItself() {
        let selection = ViewedImage(image: payload("x"), group: [payload("a"), payload("b")])
        XCTAssertEqual(selection.images.map(\.id), ["x"])
        XCTAssertFalse(selection.hasPrevious)
        XCTAssertFalse(selection.hasNext)
    }
}
