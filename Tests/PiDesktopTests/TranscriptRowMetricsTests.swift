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
    func testExpandedDetailIsTheSameSizeAsAnAnswer() {
        // Detail used to be a step smaller than prose, which is half of why the transcript read
        // as several different apps stacked vertically. It is now the same size and separated by
        // colour instead.
        XCTAssertEqual(PiFont.rowDetail, PiFont.bodySize)
        XCTAssertGreaterThan(PiFont.rowDetail, PiFont.metaSize)
    }

    func testExactlyOneCaptionSizeBacksEveryRowTitle() {
        // Work-log header, activity rows, tool steps, custom/system/unknown rows, and the
        // compaction marker all title themselves in `PiFont.caption` — this pins that single
        // value so a title never silently grows/shrinks relative to its siblings.
        XCTAssertEqual(PiFont.caption, Font.system(size: PiFont.metaSize, weight: .regular))
    }

    func testCodeDetailStaysASingleDistinctMonospacedSizeFromProseDetail() {
        // Tool call/result payloads are deliberately not part of the prose-detail unification
        // (task 3 keeps them monospaced, at the shared text origin, un-carded) — this just pins
        // that the two "detail" tracks (prose vs. code) remain exactly two named sizes, not more.
        XCTAssertEqual(PiFont.code, Font.system(size: PiFont.codeSize, design: .monospaced))
        // Monospaced runs one step under prose so the two optically match rather than clash.
        XCTAssertEqual(PiFont.codeSize, PiFont.bodySize - 1)
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
        // Nothing in the transcript computes its own offset from the body size any more.
        XCTAssertEqual(occurrences, 0, "Row sizes come from PiFont, never from an ad-hoc offset")
        XCTAssertTrue(contents.contains("static let rowDetail"), "The shared constant must still be defined exactly once")
    }
}

final class TranscriptRhythmTests: XCTestCase {
    /// The whole conversation column is built from four spacing steps and four glyph sizes.
    /// Anything outside them is what made the app look like several apps stitched together.
    func testTheTranscriptUsesOneSpacingLadder() {
        let ladder = [
            PiTheme.transcriptRowSpacing,
            PiTheme.transcriptBlockSpacing,
            PiTheme.transcriptEntrySpacing,
            PiTheme.transcriptTurnSpacing
        ]
        XCTAssertEqual(ladder, ladder.sorted(), "the ladder must ascend: row < block < entry < turn")
        XCTAssertEqual(Set(ladder).count, ladder.count, "each step is distinct")
        // Every step stays on the 2pt grid the rest of the theme uses.
        XCTAssertTrue(ladder.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 })
    }

    func testGlyphSizesComeFromOneScale() {
        let scale = [PiIcon.micro, PiIcon.small, PiIcon.medium, PiIcon.large]
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
        // Icons must never out-shout the body text they sit beside.
        XCTAssertLessThanOrEqual(PiIcon.large, PiFont.bodySize)
    }

    func testBothMarkdownRenderersShareOneLineHeight() {
        // The streaming SwiftUI renderer and the settled AppKit answer draw the same prose; a
        // different line height between them makes a message visibly reflow when it settles.
        XCTAssertEqual(PiFont.bodyLineSpacing, (PiFont.bodyLineHeight - 1) * PiFont.bodySize, accuracy: 0.001)
        XCTAssertGreaterThan(PiFont.bodyLineSpacing, 0)
    }
}
