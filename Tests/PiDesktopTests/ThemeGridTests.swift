import XCTest
@testable import PiDesktop

/// The layout grid is policy, not decoration: these values are what keep the sidebar, the
/// transcript, the status bar, and the sidebar footer on one set of edges.
final class ThemeGridTests: XCTestCase {
    func testSidebarRowsShareOneTextOriginAndOneIconColumn() {
        // Action rows, conversation rows, and folder headers all start at the same base inset
        // (there is no reserved disclosure gutter) and then the same icon column, so every
        // title lands on one shared origin regardless of row kind.
        let actionRowTextOrigin = PiTheme.sidebarIconInset + PiTheme.sidebarIconColumn + PiTheme.space6
        let conversationRowTextOrigin = PiTheme.sidebarIconInset + PiTheme.sidebarIconColumn + PiTheme.space6
        let folderHeaderTextOrigin = PiTheme.space8 + PiTheme.sidebarIconColumn + PiTheme.space6

        XCTAssertEqual(actionRowTextOrigin, PiTheme.sidebarTextInset)
        XCTAssertEqual(conversationRowTextOrigin, PiTheme.sidebarTextInset)
        XCTAssertEqual(folderHeaderTextOrigin, PiTheme.sidebarTextInset)
        XCTAssertLessThan(PiTheme.sidebarTextInset, 56, "Indentation must stay shallow")
    }

    func testSidebarFooterAndStatusBarShareOneHeight() {
        XCTAssertEqual(PiTheme.statusBarHeight, 26)
    }

    func testTranscriptRowsShareOneTextOriginAndComposerMeasure() {
        XCTAssertEqual(PiTheme.gridTextInset, PiTheme.gridIconColumn + PiTheme.gridGutter)
        XCTAssertEqual(
            PiTheme.transcriptMaxWidth,
            PiTheme.composerMaxWidth,
            "Transcript content and composer must share the same visible measure"
        )
    }

    func testInspectorColumnStaysInsideTheNativeRange() {
        XCTAssertTrue((264...280).contains(PiTheme.inspectorWidth))
        XCTAssertEqual(ConversationLayout.inspectorColumnWidth, PiTheme.inspectorWidth + PiTheme.inspectorGutter)
        // The inspector is dropped rather than squeezing the transcript below its minimum.
        XCTAssertTrue(ConversationLayout.showsInspector(
            requested: true,
            totalWidth: PiTheme.conversationMinimumWidth + ConversationLayout.inspectorColumnWidth
        ))
        XCTAssertFalse(ConversationLayout.showsInspector(
            requested: true,
            totalWidth: PiTheme.conversationMinimumWidth + ConversationLayout.inspectorColumnWidth - 1
        ))
        XCTAssertFalse(ConversationLayout.showsInspector(requested: false, totalWidth: 2_000))
    }

    func testMenuBarStaysWithinItsWidthBudget() {
        XCTAssertLessThanOrEqual(PiTheme.menuBarWidth, 320)
    }
}

/// Context-over-budget colouring: at or under 100% stays neutral everywhere it is still shown
/// (the inspector, now that the footer bar no longer carries context at all); past 100% the
/// inspector renders it in `Color.piRed`.
final class ContextBudgetTests: XCTestCase {
    func testAtOrUnderOneHundredIsNotOverBudget() {
        XCTAssertFalse(ContextBudget.isOverBudget(0))
        XCTAssertFalse(ContextBudget.isOverBudget(99.4))
        XCTAssertFalse(ContextBudget.isOverBudget(100))
    }

    func testOverOneHundredIsOverBudget() {
        XCTAssertTrue(ContextBudget.isOverBudget(100.1))
        XCTAssertTrue(ContextBudget.isOverBudget(140))
    }

    func testNilContextIsNeverOverBudget() {
        XCTAssertFalse(ContextBudget.isOverBudget(nil))
    }
}

/// The effort ramp backing the composer's mode slider: one stop per mode, calm to intense, and
/// no two modes sharing a colour — a copy-paste bug here would silently make two adjacent modes
/// indistinguishable.
final class EffortRampTests: XCTestCase {
    func testRampHasOneStopPerMode() {
        XCTAssertEqual(PiTheme.effortRamp.count, PiMode.allCases.count)
    }

    func testEveryModeMapsToADistinctRampColour() {
        let tints = PiMode.allCases.map(\.piTint)
        XCTAssertEqual(Set(tints).count, tints.count, "Every mode must read as a visually distinct step")
    }

    func testUltraAccentDiffersFromItsOwnRampStop() {
        XCTAssertNotEqual(PiTheme.effortUltraAccent, PiMode.ultra.piTint, "Ultra's glow must add a second colour, not repeat its own stop")
    }
}
