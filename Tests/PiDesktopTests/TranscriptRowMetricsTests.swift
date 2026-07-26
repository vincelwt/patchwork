import SwiftUI
import XCTest
@testable import PiDesktop

/// Pins the transcript row type scale as a policy, the same way `ThemeGridTests` (not owned by
/// this change) pins the shared grid constants: `MessageView.swift` row types no longer compute
/// their own `PiFont.bodySize - 1` literal per call site (thinking, narration, compaction detail,
/// custom detail, and system detail all used to each spell that out independently, and system
/// detail had drifted to `PiFont.caption` entirely) — they all reference `PiFont.rowDetail`. This
/// cannot inspect what a live `Text` actually renders with (there is no snapshot harness here),
/// so it pins the shared constant and its relationship to the rest of the type scale instead,
/// which is what would catch a future call site reintroducing its own ad-hoc offset.
final class TranscriptRowMetricsTests: XCTestCase {
    func testRowDetailIsOneNamedConstantBetweenCaptionAndBody() {
        // The exact value is a deliberate one-step-under-body offset, not one more magic number:
        // pinning the relationship (not just the literal) is what makes a future drive-by
        // `bodySize - 1` at a new call site show up as a behavioral change instead of quietly
        // matching by coincidence.
        XCTAssertEqual(PiFont.rowDetail, PiFont.bodySize - 1)
        XCTAssertLessThan(PiFont.rowDetail, PiFont.bodySize, "Expanded detail stays a step under the answer body")
        // PiFont.caption is Theme.swift's 11.5pt title size; rowDetail (prose content) must still
        // read larger than a row title.
        XCTAssertGreaterThan(PiFont.rowDetail, 11.5)
    }

    func testExactlyOneCaptionSizeBacksEveryRowTitle() {
        // Work-log header, activity rows, tool steps, custom/system/unknown rows, and the
        // compaction marker all title themselves in `PiFont.caption` — this pins that single
        // value so a title never silently grows/shrinks relative to its siblings.
        XCTAssertEqual(PiFont.caption, Font.system(size: 11.5, weight: .regular))
    }

    func testCodeDetailStaysASingleDistinctMonospacedSizeFromProseDetail() {
        // Tool call/result payloads are deliberately not part of the prose-detail unification
        // (task 3 keeps them monospaced, at the shared text origin, un-carded) — this just pins
        // that the two "detail" tracks (prose vs. code) remain exactly two named sizes, not more.
        XCTAssertEqual(PiFont.code, Font.system(size: 12, design: .monospaced))
        XCTAssertNotEqual(PiFont.code, Font.system(size: PiFont.rowDetail))
    }

    func testSharedGridColumnStillBacksEveryIconBearingRow() {
        // Thinking and narration rows gained the same `PiGridRow` icon column tool/result rows
        // already used, rather than a bespoke layout, so this is the same measure `ThemeGridTests`
        // already pins for the rest of the transcript.
        XCTAssertEqual(PiTheme.gridTextInset, PiTheme.gridIconColumn + PiTheme.gridGutter)
    }

    func testMessageViewSourceHasNoRemainingAdHocBodySizeOffset() throws {
        // Belt-and-suspenders: read the actual source so a future edit that reintroduces a
        // scattered `PiFont.bodySize - 1` (instead of the shared `PiFont.rowDetail`) fails a test
        // immediately rather than only in code review.
        let thisFile = URL(fileURLWithPath: #filePath)
        let sourceURL = thisFile
            .deletingLastPathComponent() // TranscriptRowMetricsTests.swift
            .deletingLastPathComponent() // Tests/PiDesktopTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources/PiDesktop/MessageView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let occurrences = contents.components(separatedBy: "bodySize - 1").count - 1
        // Exactly one: the shared constant's own definition. Any more means a call site went
        // back to computing its own offset instead of referencing `PiFont.rowDetail`.
        XCTAssertEqual(occurrences, 1, "Only PiFont.rowDetail's own definition may compute bodySize - 1")
        XCTAssertTrue(contents.contains("static let rowDetail"), "The shared constant must still be defined exactly once")
    }
}
