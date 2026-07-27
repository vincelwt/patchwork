import SwiftUI
import XCTest
@testable import PiDesktop

/// The menu bar's single glyph: exactly one of green (running), blue (unread), or an empty
/// outline (idle) is ever shown. `resolve` is the one place this precedence is decided, so it is
/// tested directly against every combination rather than by rendering the view.
final class MenuBarCircleStateTests: XCTestCase {
    func testRunningWinsOverEverything() {
        XCTAssertEqual(MenuBarCircleState.resolve(runningCount: 1, unreadCount: 0), .running)
        XCTAssertEqual(MenuBarCircleState.resolve(runningCount: 3, unreadCount: 5), .running, "Running must win even when there is also unread activity")
    }

    func testUnreadShowsOnlyWhenNothingIsRunning() {
        XCTAssertEqual(MenuBarCircleState.resolve(runningCount: 0, unreadCount: 1), .unread)
        XCTAssertEqual(MenuBarCircleState.resolve(runningCount: 0, unreadCount: 40), .unread)
    }

    func testIdleWhenNothingIsRunningOrUnread() {
        XCTAssertEqual(MenuBarCircleState.resolve(runningCount: 0, unreadCount: 0), .idle)
    }

    func testSymbolAndRenderingModePerState() {
        XCTAssertEqual(MenuBarCircleState.running.symbolName, "circle.fill")
        XCTAssertEqual(MenuBarCircleState.unread.symbolName, "circle.fill")
        XCTAssertEqual(MenuBarCircleState.idle.symbolName, "circle")

        // Idle stays a template image so AppKit tints it for the current menu bar; the two
        // active states carry real colour and must opt out of template rendering.
        XCTAssertFalse(MenuBarCircleState.idle.usesOriginalColor)
        XCTAssertTrue(MenuBarCircleState.running.usesOriginalColor)
        XCTAssertTrue(MenuBarCircleState.unread.usesOriginalColor)
    }

    func testEachStateHasADistinctAccessibilityLabel() {
        let labels = Set([MenuBarCircleState.running, .unread, .idle].map(\.accessibilityLabel))
        XCTAssertEqual(labels.count, 3)
    }

    func testTintsAreDistinctPerState() {
        XCTAssertNotEqual(MenuBarCircleState.running.tint, MenuBarCircleState.unread.tint)
    }
}

final class MenuBarPanelLayoutTests: XCTestCase {
    func testScrollableRegionsFitCommonDisplayHeights() {
        for available in [300, 600, 875, 1440] as [CGFloat] {
            let heights = MenuBarPanelLayout.heights(availableHeight: available)
            let total = PiTheme.menuBarFixedHeight + heights.sessions + heights.limits

            XCTAssertLessThanOrEqual(total, available - PiTheme.menuBarScreenMargin)
            XCTAssertGreaterThanOrEqual(
                heights.limits,
                min(PiTheme.menuBarLimitsMinHeight, max(0, available - PiTheme.menuBarScreenMargin - PiTheme.menuBarFixedHeight))
            )
            XCTAssertLessThan(
                heights.sessions,
                CGFloat(MenuBarPanelLayout.sessionDisplayLimit) * PiTheme.menuBarSessionRowHeight
            )
        }

        let roomy = MenuBarPanelLayout.heights(availableHeight: 1440)
        XCTAssertEqual(roomy.sessions, PiTheme.menuBarSessionsIdealHeight)
        XCTAssertEqual(roomy.limits, PiTheme.menuBarLimitsIdealHeight)
    }

    /// The macOS 27 beta workaround: the panel is centered under the clicked status item and
    /// never allowed past either edge of the screen it was clicked on.
    func testAnchoredXCentersUnderTheClickAndClampsToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let width = PiTheme.menuBarWidth  // 320

        XCTAssertEqual(MenuBarPanelLayout.anchoredX(clickX: 1000, panelWidth: width, visibleFrame: screen), 840)
        // Status item near the right edge: clamped instead of hanging off-screen.
        XCTAssertEqual(MenuBarPanelLayout.anchoredX(clickX: 2550, panelWidth: width, visibleFrame: screen), 2240)
        XCTAssertEqual(MenuBarPanelLayout.anchoredX(clickX: 4, panelWidth: width, visibleFrame: screen), 0)

        // A secondary display to the left keeps its own origin, not the main screen's.
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(MenuBarPanelLayout.anchoredX(clickX: -1430, panelWidth: width, visibleFrame: left), -1440)
        XCTAssertEqual(MenuBarPanelLayout.anchoredX(clickX: -20, panelWidth: width, visibleFrame: left), -320)

        // Panel wider than the screen still starts at the left edge rather than a negative inset.
        XCTAssertEqual(MenuBarPanelLayout.anchoredX(clickX: 100, panelWidth: 400, visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 300)), 0)
    }

    func testSessionHeightFitsRowsThenCapsForScrolling() {
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(count: 0, maxHeight: 480), 0)
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(count: 3, maxHeight: 480), 126)
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(count: 50, maxHeight: 300), 300)
    }
}
