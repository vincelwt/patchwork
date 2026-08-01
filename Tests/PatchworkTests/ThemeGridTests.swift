import XCTest
@testable import Patchwork

/// The layout grid is policy, not decoration: these values are what keep the sidebar, the
/// transcript, the status bar, and the sidebar footer on one set of edges.
final class ThemeGridTests: XCTestCase {
    func testSidebarRowsShareOneTextOriginAndOneIconColumn() {
        // Action rows, conversation rows, and folder headers all start at the same base inset
        // (there is no reserved disclosure gutter) and then the same icon column, so every
        // title lands on one shared origin regardless of row kind.
        let actionRowTextOrigin = PatchworkTheme.sidebarIconInset + PatchworkTheme.sidebarIconColumn + PatchworkTheme.space6
        let conversationRowTextOrigin = PatchworkTheme.sidebarIconInset + PatchworkTheme.sidebarIconColumn + PatchworkTheme.space6
        let folderHeaderTextOrigin = PatchworkTheme.space8 + PatchworkTheme.sidebarIconColumn + PatchworkTheme.space6

        XCTAssertEqual(actionRowTextOrigin, PatchworkTheme.sidebarTextInset)
        XCTAssertEqual(conversationRowTextOrigin, PatchworkTheme.sidebarTextInset)
        XCTAssertEqual(folderHeaderTextOrigin, PatchworkTheme.sidebarTextInset)
        XCTAssertLessThan(PatchworkTheme.sidebarTextInset, 56, "Indentation must stay shallow")
    }

    func testSidebarFooterAndStatusBarShareOneHeight() {
        XCTAssertEqual(PatchworkTheme.statusBarHeight, 26)
    }

    func testTranscriptRowsShareOneTextOriginAndComposerMeasure() {
        XCTAssertEqual(PatchworkTheme.gridTextInset, PatchworkTheme.gridIconColumn + PatchworkTheme.gridGutter)
        XCTAssertEqual(
            PatchworkTheme.transcriptMaxWidth,
            PatchworkTheme.composerMaxWidth,
            "Transcript content and composer must share the same visible measure"
        )
    }

    func testInspectorColumnStaysInsideTheNativeRange() {
        XCTAssertTrue((264...280).contains(PatchworkTheme.inspectorWidth))
        XCTAssertEqual(ConversationLayout.inspectorColumnWidth, PatchworkTheme.inspectorWidth + PatchworkTheme.inspectorGutter)
        // The inspector is dropped rather than squeezing the transcript below its minimum.
        XCTAssertTrue(ConversationLayout.showsInspector(
            requested: true,
            totalWidth: PatchworkTheme.conversationMinimumWidth + ConversationLayout.inspectorColumnWidth
        ))
        XCTAssertFalse(ConversationLayout.showsInspector(
            requested: true,
            totalWidth: PatchworkTheme.conversationMinimumWidth + ConversationLayout.inspectorColumnWidth - 1
        ))
        XCTAssertFalse(ConversationLayout.showsInspector(requested: false, totalWidth: 2_000))
    }

    func testMenuBarStaysWithinItsWidthBudget() {
        XCTAssertLessThanOrEqual(PatchworkTheme.menuBarWidth, 320)
    }
}

/// Context-over-budget colouring: at or under 100% stays neutral everywhere it is still shown
/// (the inspector, now that the footer bar no longer carries context at all); past 100% the
/// inspector renders it in `Color.patchworkRed`.
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
        XCTAssertEqual(PatchworkTheme.effortRamp.count, PiMode.allCases.count)
    }

    func testEveryModeMapsToADistinctRampColour() {
        let tints = PiMode.allCases.map(\.patchworkTint)
        XCTAssertEqual(Set(tints).count, tints.count, "Every mode must read as a visually distinct step")
    }

    func testUltraAccentDiffersFromItsOwnRampStop() {
        XCTAssertNotEqual(PatchworkTheme.effortUltraAccent, PiMode.ultra.patchworkTint, "Ultra's glow must add a second colour, not repeat its own stop")
    }
}
