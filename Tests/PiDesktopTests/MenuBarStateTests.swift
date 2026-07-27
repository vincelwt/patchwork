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
}
