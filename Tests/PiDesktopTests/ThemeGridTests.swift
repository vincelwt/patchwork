import XCTest
@testable import PiDesktop

/// The layout grid is policy, not decoration: these values are what keep the sidebar, the
/// transcript, the status bar, and the sidebar footer on one set of edges.
final class ThemeGridTests: XCTestCase {
    func testSidebarRowsShareOneTextOriginAndOneIconColumn() {
        // Action rows and conversation rows both start at the icon inset and then reserve the
        // same icon column, so their titles land on the folder-name origin.
        let actionRowTextOrigin = PiTheme.sidebarIconInset + PiTheme.sidebarIconColumn + PiTheme.space6
        let conversationRowTextOrigin = PiTheme.sidebarIconInset + PiTheme.sidebarIconColumn + PiTheme.space6
        // A folder header spends the disclosure gutter first, then the same icon column.
        let folderHeaderTextOrigin = PiTheme.space8
            + PiTheme.sidebarDisclosureColumn + PiTheme.space6
            + PiTheme.sidebarIconColumn + PiTheme.space6

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
