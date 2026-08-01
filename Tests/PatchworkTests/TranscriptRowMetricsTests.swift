import SwiftUI
import XCTest
@testable import Patchwork

/// Pins the one-size text policy. Semantic roles may change weight or design, but never point
/// size; transcript detail uses the shared body role rather than maintaining a parallel scale.
final class TranscriptRowMetricsTests: XCTestCase {
    func testEverySemanticTextRoleUsesOneLiteralPointSize() {
        let sizes = [
            PatchworkFont.bodySize,
            PatchworkFont.metaSize,
            PatchworkFont.codeSize,
            PatchworkFont.heading1Size,
            PatchworkFont.heading2Size,
            PatchworkFont.heading3Size
        ]
        XCTAssertEqual(Set(sizes), [PatchworkFont.size])
        XCTAssertEqual(PatchworkFont.size, NSFont.systemFontSize)
        XCTAssertEqual(PatchworkFont.composerNSFont.pointSize, PatchworkFont.size)
        XCTAssertEqual(PatchworkFont.codeNSFont.pointSize, PatchworkFont.size)
    }

    func testProductSourcesCannotReintroduceScaledTextOrSystemEmptyStates() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Patchwork", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("ContentUnavailableView("), "\(file.lastPathComponent) bypasses PatchworkFont")
            XCTAssertFalse(source.contains("bodySize -"), "\(file.lastPathComponent) derives a smaller text size")
            XCTAssertFalse(source.contains("metaSize -"), "\(file.lastPathComponent) derives a smaller text size")
            XCTAssertFalse(source.contains("codeSize -"), "\(file.lastPathComponent) derives a smaller text size")
        }
    }

    func testExactlyOneCaptionSizeBacksEveryRowTitle() {
        // Work-log header, activity rows, tool steps, custom/system/unknown rows, and the
        // compaction marker all title themselves in `PatchworkFont.caption` — this pins that single
        // value so a title never silently grows/shrinks relative to its siblings.
        XCTAssertEqual(PatchworkFont.caption, Font.system(size: PatchworkFont.metaSize, weight: .regular))
    }

    func testCodeDiffersByDesignNotSize() {
        XCTAssertEqual(PatchworkFont.code, Font.system(size: PatchworkFont.size, design: .monospaced))
        XCTAssertEqual(PatchworkFont.codeSize, PatchworkFont.bodySize)
    }

    func testSharedGridColumnStillBacksEveryIconBearingRow() {
        // Thinking and narration rows gained the same `PatchworkGridRow` icon column tool/result rows
        // already used, rather than a bespoke layout, so this is the same measure `ThemeGridTests`
        // already pins for the rest of the transcript.
        XCTAssertEqual(PatchworkTheme.gridTextInset, PatchworkTheme.gridIconColumn + PatchworkTheme.gridGutter)
    }

    func testMessageViewSourceHasNoParallelDetailScale() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let sourceURL = thisFile
            .deletingLastPathComponent() // TranscriptRowMetricsTests.swift
            .deletingLastPathComponent() // Tests/PatchworkTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources/Patchwork/MessageView.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("bodySize -"), "Transcript rows never derive a smaller font")
        XCTAssertFalse(contents.contains("rowDetail"), "Transcript rows do not maintain a parallel size role")
    }

    func testLiveDotsPulseAndCollapsedWorkHasNoDivider() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Patchwork", isDirectory: true)
        let theme = try String(contentsOf: sourceRoot.appendingPathComponent("Theme.swift"), encoding: .utf8)
        let messages = try String(contentsOf: sourceRoot.appendingPathComponent("MessageView.swift"), encoding: .utf8)

        XCTAssertTrue(theme.contains("if pulsing, !reduceMotion"), "The pulse honors Reduce Motion")
        XCTAssertTrue(theme.contains("CABasicAnimation"), "The pulse is a render-server layer animation, not a view-graph one")
        XCTAssertTrue(messages.contains("if block.isActive { StatusDot(color: .patchworkGreen, pulsing: true) }"))
        XCTAssertFalse(messages.contains("PatchworkHairline()"), "Transcript disclosures use spacing, not separator lines")
    }
}

final class TranscriptRhythmTests: XCTestCase {
    /// The whole conversation column is built from four spacing steps and four glyph sizes.
    /// Anything outside them is what made the app look like several apps stitched together.
    func testTheTranscriptUsesOneSpacingLadder() {
        let ladder = [
            PatchworkTheme.transcriptRowSpacing,
            PatchworkTheme.transcriptBlockSpacing,
            PatchworkTheme.transcriptEntrySpacing,
            PatchworkTheme.transcriptTurnSpacing
        ]
        XCTAssertEqual(ladder, ladder.sorted(), "the ladder must ascend: row < block < entry < turn")
        XCTAssertEqual(Set(ladder).count, ladder.count, "each step is distinct")
        // Every step stays on the 2pt grid the rest of the theme uses.
        XCTAssertTrue(ladder.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 })
    }

    func testGlyphSizesComeFromOneScale() {
        let scale = [PatchworkIcon.micro, PatchworkIcon.small, PatchworkIcon.medium, PatchworkIcon.large]
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
        // Icons must never out-shout the body text they sit beside.
        XCTAssertLessThanOrEqual(PatchworkIcon.large, PatchworkFont.bodySize)
    }

    func testBothMarkdownRenderersShareOneLineHeight() {
        // The streaming SwiftUI renderer and the settled AppKit answer draw the same prose; a
        // different line height between them makes a message visibly reflow when it settles.
        XCTAssertEqual(PatchworkFont.bodyLineSpacing, (PatchworkFont.bodyLineHeight - 1) * PatchworkFont.bodySize, accuracy: 0.001)
        XCTAssertGreaterThan(PatchworkFont.bodyLineSpacing, 0)
    }
}
