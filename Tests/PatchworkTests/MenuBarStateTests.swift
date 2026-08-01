import SwiftUI
import XCTest
@testable import Patchwork

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

final class ThreadCountBadgeTests: XCTestCase {
    func testPositiveCountsRenderAndZeroStaysHidden() {
        XCTAssertNil(ThreadCountBadge.label(for: 0))
        XCTAssertEqual(ThreadCountBadge.label(for: 1), "1")
        XCTAssertEqual(ThreadCountBadge.label(for: 42), "42")
    }
}

final class MenuBarPanelLayoutTests: XCTestCase {
    func testScrollableRegionsFitCommonDisplayHeights() {
        for available in [300, 600, 875, 1440] as [CGFloat] {
            let heights = MenuBarPanelLayout.heights(availableHeight: available)
            let total = PatchworkTheme.menuBarFixedHeight + heights.sessions + heights.limits

            XCTAssertLessThanOrEqual(total, available - PatchworkTheme.menuBarScreenMargin)
            XCTAssertGreaterThanOrEqual(
                heights.limits,
                min(PatchworkTheme.menuBarLimitsMinHeight, max(0, available - PatchworkTheme.menuBarScreenMargin - PatchworkTheme.menuBarFixedHeight))
            )
            XCTAssertLessThan(
                heights.sessions,
                CGFloat(MenuBarPanelLayout.sessionDisplayLimit) * PatchworkTheme.menuBarSessionRowHeight
            )
        }

        let roomy = MenuBarPanelLayout.heights(availableHeight: 1440)
        XCTAssertEqual(roomy.sessions, PatchworkTheme.menuBarSessionsIdealHeight)
        XCTAssertEqual(roomy.limits, PatchworkTheme.menuBarLimitsIdealHeight)
    }

    /// The macOS 27 beta workaround: the panel is centered under the clicked status item and
    /// never allowed past either edge of the screen it was clicked on.
    func testAnchoredXCentersUnderTheClickAndClampsToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let width = PatchworkTheme.menuBarWidth  // 320

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

    func testSessionHeightFitsRowsAndSectionHeadersThenCapsForScrolling() {
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(rows: 0, headers: 0, maxHeight: 480), 0)
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(rows: 3, headers: 0, maxHeight: 480), 126)
        // Three rows under one Running header: the header's own height and gap are counted too.
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(rows: 3, headers: 1, maxHeight: 480), 152)
        XCTAssertEqual(MenuBarPanelLayout.sessionHeight(rows: 50, headers: 3, maxHeight: 300), 300)
    }
}

/// The panel lists the same buckets the sidebar files conversations into, so only its own
/// selection and row bound are worth testing directly.
final class MenuBarSectionTests: XCTestCase {
    private func summary(_ name: String) -> SessionSummary {
        SessionSummary(
            id: name,
            fileURL: URL(fileURLWithPath: "/tmp/\(name).jsonl"),
            cwd: URL(fileURLWithPath: "/Users/vince/code", isDirectory: true),
            createdAt: Date(),
            modifiedAt: Date(),
            name: name,
            preview: "p",
            messageCount: 0,
            metrics: TokenMetrics()
        )
    }

    private func groups(_ sessions: [SessionSummary], automated: Set<String> = [], pullRequest: Set<String> = []) -> [SidebarStatusGroup] {
        SidebarStatusGroup.groups(
            sessions,
            isRunning: { $0.name.hasPrefix("running") },
            isUnread: { $0.name.hasPrefix("unread") },
            hasOpenPullRequest: { pullRequest.contains($0.name) },
            isAutomated: { automated.contains($0.name) },
            runningAt: \.modifiedAt,
            modifiedAt: \.modifiedAt
        )
    }

    func testOnlyRunningUnreadAndDoneAppearInThatOrder() {
        let sessions = [summary("done"), summary("unread 1"), summary("running 1"), summary("pr"), summary("scheduled")]
        let visible = MenuBarPanelLayout.boundedSections(
            groups(sessions, automated: ["scheduled"], pullRequest: ["pr"])
        )
        XCTAssertEqual(visible.sections.map(\.section), [.running, .unread, .done])
        XCTAssertEqual(visible.sections.flatMap { $0.sessions.map(\.name) }, ["running 1", "unread 1", "done"])
        XCTAssertEqual(visible.hidden, 0, "Open PRs and Automated are not shown here and are not an overflow either")
    }

    func testTheGlobalRowBoundIsSharedAcrossSectionsInPriorityOrder() {
        let limit = MenuBarPanelLayout.sessionDisplayLimit
        let sessions = (0..<40).map { summary("running \($0)") }
            + (0..<20).map { summary("unread \($0)") }
            + (0..<5).map { summary("done \($0)") }
        let visible = MenuBarPanelLayout.boundedSections(groups(sessions))

        XCTAssertEqual(visible.sections.reduce(0) { $0 + $1.sessions.count }, limit)
        XCTAssertEqual(visible.sections.map(\.section), [.running, .unread], "Done does not fit, so it does not render an empty header")
        XCTAssertEqual(visible.sections.map(\.sessions.count), [40, limit - 40])
        XCTAssertEqual(visible.hidden, 65 - limit)
    }

    func testEmptyInputProducesNoSectionsAndNoOverflow() {
        let visible = MenuBarPanelLayout.boundedSections([])
        XCTAssertTrue(visible.sections.isEmpty)
        XCTAssertEqual(visible.hidden, 0)
    }
}
