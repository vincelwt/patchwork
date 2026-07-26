import XCTest
@testable import PiDesktop

/// `PiEffortTrack`'s bug was entirely in its position math, so it is pinned down here as plain
/// arithmetic rather than a rendered snapshot.
final class EffortSliderGeometryTests: XCTestCase {
    private let steps = PiMode.allCases.count
    private let width = PiTheme.effortTrackWidth
    private let inset = PiTheme.effortUltraKnobDiameter / 2

    // MARK: - knobCenterX

    func testKnobCentreNeverHangsPastTheTrackEdges() {
        for index in 0..<steps {
            let center = PiEffortTrackGeometry.knobCenterX(index: Double(index), steps: steps, width: width, inset: inset)
            XCTAssertGreaterThanOrEqual(center, inset, "the knob's own radius must stay inside the frame at the low end")
            XCTAssertLessThanOrEqual(center, width - inset, "...and at the high end — this is the bug: it used to reach `width` exactly")
        }
    }

    func testKnobCentreAtEachStopIsEvenlySpacedAcrossTheInsetTrack() {
        let centers = (0..<steps).map { PiEffortTrackGeometry.knobCenterX(index: Double($0), steps: steps, width: width, inset: inset) }
        XCTAssertEqual(centers[0], inset, accuracy: 0.001, "the first stop sits exactly one radius from the left edge")
        XCTAssertEqual(centers[steps - 1], width - inset, accuracy: 0.001, "the last stop sits exactly one radius from the right edge, never at `width`")

        let step = (width - inset * 2) / CGFloat(steps - 1)
        for index in 0..<steps {
            XCTAssertEqual(centers[index], inset + step * CGFloat(index), accuracy: 0.001)
        }
    }

    func testKnobCentreClampsForOutOfRangeIndices() {
        XCTAssertEqual(
            PiEffortTrackGeometry.knobCenterX(index: -5, steps: steps, width: width, inset: inset),
            inset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PiEffortTrackGeometry.knobCenterX(index: 99, steps: steps, width: width, inset: inset),
            width - inset,
            accuracy: 0.001
        )
    }

    func testDegenerateWidthNeverDividesByZero() {
        XCTAssertEqual(PiEffortTrackGeometry.knobCenterX(index: 2, steps: steps, width: 0, inset: inset), inset)
    }

    func testASingleStepFallsBackToTheMidpointInsteadOfDividingByZero() {
        XCTAssertEqual(PiEffortTrackGeometry.knobCenterX(index: 2, steps: 1, width: width, inset: inset), width / 2)
    }

    // MARK: - index(forX:)

    func testIndexForXIsTheInverseOfKnobCentreX() {
        for tenth in 0...(steps - 1) * 10 {
            let index = Double(tenth) / 10
            let x = PiEffortTrackGeometry.knobCenterX(index: index, steps: steps, width: width, inset: inset)
            let resolved = PiEffortTrackGeometry.index(forX: x, steps: steps, width: width, inset: inset)
            XCTAssertEqual(resolved, index, accuracy: 0.001, "a click must resolve to exactly the stop the knob would be drawn at")
        }
    }

    func testIndexForXClampsBeyondBothTrackEnds() {
        XCTAssertEqual(PiEffortTrackGeometry.index(forX: -50, steps: steps, width: width, inset: inset), 0)
        XCTAssertEqual(PiEffortTrackGeometry.index(forX: 5_000, steps: steps, width: width, inset: inset), Double(steps - 1))
    }

    func testIndexForXHandlesAZeroWidthTrack() {
        XCTAssertEqual(PiEffortTrackGeometry.index(forX: 10, steps: steps, width: 0, inset: inset), 0)
    }

    // MARK: - displayedIndex (the drag-responsiveness fix)

    func testDisplayedIndexPrefersAnActiveDragOverEverythingElse() {
        XCTAssertEqual(PiEffortTrackGeometry.displayedIndex(dragIndex: 1.5, pendingIndex: 3, reportedIndex: 0), 1.5)
    }

    func testDisplayedIndexHoldsThePendingReleaseUntilReconciled() {
        // No active drag, but the release has not yet been confirmed by the reported mode: the
        // stale, still-reported index must not win here, or the knob snaps back on every release.
        XCTAssertEqual(PiEffortTrackGeometry.displayedIndex(dragIndex: nil, pendingIndex: 3, reportedIndex: 0), 3)
    }

    func testDisplayedIndexFallsBackToTheReportedModeOnceReconciled() {
        XCTAssertEqual(PiEffortTrackGeometry.displayedIndex(dragIndex: nil, pendingIndex: nil, reportedIndex: 2), 2)
    }
}
