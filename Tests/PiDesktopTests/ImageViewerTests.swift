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

    func testZoomOneFitsLargeImagesWithoutUpscalingSmallOnes() {
        let viewport = CGSize(width: 800, height: 600)
        let large = CGSize(width: 2400, height: 1200)

        // A wide screenshot lands inside the viewport, aspect ratio intact.
        let fitted = ImageViewerView.fittedSize(for: large, in: viewport, zoom: 1)
        XCTAssertEqual(fitted.width, 800, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 400, accuracy: 0.001)
        XCTAssertEqual(fitted.width / fitted.height, large.width / large.height, accuracy: 0.001)

        // A small image keeps its intrinsic size — fitting never upscales.
        let small = ImageViewerView.fittedSize(for: CGSize(width: 120, height: 90), in: viewport, zoom: 1)
        XCTAssertEqual(small.width, 120, accuracy: 0.001)
        XCTAssertEqual(small.height, 90, accuracy: 0.001)

        // Zoom scales the fitted size in both directions, which is what makes it scrollable.
        let zoomed = ImageViewerView.fittedSize(for: large, in: viewport, zoom: 2)
        XCTAssertEqual(zoomed.width, 1600, accuracy: 0.001)
        XCTAssertEqual(zoomed.height, 800, accuracy: 0.001)

        // Degenerate input collapses instead of producing a NaN or infinite frame.
        XCTAssertEqual(ImageViewerView.fittedSize(for: .zero, in: viewport, zoom: 1), .zero)
        XCTAssertEqual(ImageViewerView.fittedSize(for: large, in: .zero, zoom: 1), .zero)
        XCTAssertEqual(ImageViewerView.fittedSize(for: large, in: viewport, zoom: 0), .zero)
    }

    func testImageMissingFromItsGroupFallsBackToItself() {
        let selection = ViewedImage(image: payload("x"), group: [payload("a"), payload("b")])
        XCTAssertEqual(selection.images.map(\.id), ["x"])
        XCTAssertFalse(selection.hasPrevious)
        XCTAssertFalse(selection.hasNext)
    }
}
