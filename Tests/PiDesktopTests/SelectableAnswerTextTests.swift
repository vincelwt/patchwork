import AppKit
import SwiftUI
import XCTest
@testable import PiDesktop

private func descendant<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
    if let match = root as? View { return match }
    return root.subviews.lazy.compactMap { descendant(type, in: $0) }.first
}

/// Covers the cross-block answer partitioner, attributed-string builder, and hosted text sizing.
/// Real AppKit drag/selection interaction is not exercised here, the same way the rest of the
/// suite never simulates mouse events — see `ComposerInlineImageTests` for the established pattern
/// of testing AppKit text state programmatically instead.
final class SelectableAnswerTextTests: XCTestCase {
    // MARK: - Partitioning

    func testContiguousNonTableBlocksStayInOneRun() {
        let blocks: [MarkdownBlock] = [.paragraph("one"), .list(items: [], ordered: false, start: 1), .paragraph("two")]
        let runs = MarkdownAnswerPartitioner.runs(from: blocks)
        XCTAssertEqual(runs.count, 1)
        guard case let .text(grouped, _) = runs[0] else { return XCTFail("Expected one text run") }
        XCTAssertEqual(grouped.count, 3)
    }

    func testATableSplitsSurroundingProseIntoSeparateRuns() {
        let table = MarkdownBlock.table(header: ["A"], alignment: [.none], rows: [["1"]])
        let blocks: [MarkdownBlock] = [.paragraph("before"), table, .paragraph("after")]
        let runs = MarkdownAnswerPartitioner.runs(from: blocks)
        XCTAssertEqual(runs.count, 3)
        guard case .text = runs[0] else { return XCTFail("Expected text before the table") }
        guard case .table = runs[1] else { return XCTFail("Expected the table itself") }
        guard case .text = runs[2] else { return XCTFail("Expected text after the table") }
    }

    func testConsecutiveTablesEachGetTheirOwnRunWithNoEmptyTextRunBetween() {
        let table = MarkdownBlock.table(header: ["A"], alignment: [.none], rows: [])
        let runs = MarkdownAnswerPartitioner.runs(from: [table, table])
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.allSatisfy { if case .table = $0 { return true } else { return false } })
    }

    func testEmptyBlockListProducesNoRuns() {
        XCTAssertTrue(MarkdownAnswerPartitioner.runs(from: []).isEmpty)
    }

    // MARK: - Attributed string construction (the ⌘C / continuous-selection model)

    func testPlainTextIncludesEveryBlockInOrderForACleanCopy() {
        let blocks = MarkdownBlockParser.blocks(from: "First paragraph.\n\n- item one\n- item two\n\n```\ncode here\n```")
        let text = AnswerAttributedTextBuilder.plainText(blocks: blocks)
        XCTAssertTrue(text.contains("First paragraph."))
        XCTAssertTrue(text.contains("item one"))
        XCTAssertTrue(text.contains("item two"))
        XCTAssertTrue(text.contains("code here"))
        // Order is preserved: the paragraph precedes the list, which precedes the code.
        let paragraphRange = try? XCTUnwrap(text.range(of: "First paragraph."))
        let listRange = try? XCTUnwrap(text.range(of: "item one"))
        let codeRange = try? XCTUnwrap(text.range(of: "code here"))
        if let paragraphRange, let listRange, let codeRange {
            XCTAssertTrue(paragraphRange.lowerBound < listRange.lowerBound)
            XCTAssertTrue(listRange.lowerBound < codeRange.lowerBound)
        } else {
            XCTFail("Expected to find all three fragments")
        }
    }

    func testEverySettledAnswerProseBlockUsesSharedLineSpacing() throws {
        let blocks: [MarkdownBlock] = [
            .paragraph("paragraph"),
            .heading(level: 1, text: "heading"),
            .list(items: [.init(marker: "•", text: "list item", depth: 0)], ordered: false, start: 1),
            .quote("quote")
        ]
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)

        for fragment in ["paragraph", "heading", "list item", "quote"] {
            let range = try XCTUnwrap(built.attributedString.string.range(of: fragment))
            let style = try XCTUnwrap(
                built.attributedString.attribute(
                    .paragraphStyle,
                    at: NSRange(range, in: built.attributedString.string).location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )
            XCTAssertEqual(style.lineSpacing, PiFont.bodyLineSpacing, accuracy: 0.001, fragment)
        }
    }

    func testBoldSpanGetsABoldFontTrait() throws {
        let blocks = MarkdownBlockParser.blocks(from: "plain **bold** plain")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "bold"))
        let nsRange = NSRange(range, in: string)
        let font = try XCTUnwrap(built.attributedString.attribute(.font, at: nsRange.location, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        XCTAssertTrue(traits.contains(.boldFontMask), "A **bold** run must resolve to a concrete bold NSFont trait")
    }

    func testMarkdownLinkCarriesItsURLAttribute() throws {
        let blocks = MarkdownBlockParser.blocks(from: "See [docs](https://pi.dev/docs) now")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "docs"))
        let nsRange = NSRange(range, in: string)
        let link = built.attributedString.attribute(.link, at: nsRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://pi.dev/docs")
    }

    func testBareURLIsAutolinkedInTheBuiltAttributedString() throws {
        let blocks = MarkdownBlockParser.blocks(from: "Visit https://pi.dev/docs today")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "https://pi.dev/docs"))
        let nsRange = NSRange(range, in: string)
        let link = built.attributedString.attribute(.link, at: nsRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://pi.dev/docs", "The same autolink pass MarkdownInline uses everywhere else must apply here too")
    }

    func testStrikethroughSpanCarriesTheStrikethroughAttribute() throws {
        let blocks = MarkdownBlockParser.blocks(from: "before ~~gone~~ after")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "gone"))
        let nsRange = NSRange(range, in: string)
        let style = built.attributedString.attribute(.strikethroughStyle, at: nsRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
    }

    func testCodeBlockIsRecordedWithItsExactSourceAndAMonospacedFont() throws {
        let blocks = MarkdownBlockParser.blocks(from: "Before\n\n```swift\nlet x = 1\n```\n\nAfter")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        XCTAssertEqual(built.codeBlocks.count, 1)
        let entry = try XCTUnwrap(built.codeBlocks.first)
        XCTAssertEqual(entry.code, "let x = 1")

        let substring = (built.attributedString.string as NSString).substring(with: entry.range)
        XCTAssertEqual(substring, "let x = 1", "The recorded range must point at exactly the code text")

        let font = try XCTUnwrap(built.attributedString.attribute(.font, at: entry.range.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace), "Code must render in a monospaced font")
    }

    func testInlineCodeSpanIsAlsoMonospacedDistinctFromABlockCode() throws {
        let blocks = MarkdownBlockParser.blocks(from: "Run `swift build` now")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        XCTAssertTrue(built.codeBlocks.isEmpty, "An inline code span is not a fenced code block")
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "swift build"))
        let nsRange = NSRange(range, in: string)
        let font = try XCTUnwrap(built.attributedString.attribute(.font, at: nsRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testHeadingUsesWeightRatherThanASpecialSize() throws {
        let blocks = MarkdownBlockParser.blocks(from: "# Title\n\nBody text")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string
        let titleRange = NSRange((try XCTUnwrap(string.range(of: "Title"))), in: string)
        let bodyRange = NSRange((try XCTUnwrap(string.range(of: "Body text"))), in: string)
        let titleFont = try XCTUnwrap(built.attributedString.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(built.attributedString.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(titleFont.pointSize, bodyFont.pointSize)
        XCTAssertTrue(titleFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(bodyFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testEmptyBlockListProducesEmptyAttributedString() {
        let built = AnswerAttributedTextBuilder.build(blocks: [])
        XCTAssertEqual(built.attributedString.length, 0)
        XCTAssertTrue(built.codeBlocks.isEmpty)
    }

    // MARK: - Sizing (a saved answer must never render blank or one line tall)

    @MainActor
    func testHostedTextReportsItsWrappedHeightSynchronously() throws {
        let blocks = MarkdownBlockParser.blocks(from: (1...8)
            .map { "Paragraph \($0) with enough words in it that the line has to wrap at a narrow measure." }
            .joined(separator: "\n\n"))
        let view = AnswerTextView()
        view.apply(AnswerAttributedTextBuilder.build(blocks: blocks))

        // No run loop turn, no layout pass: the height has to be right on the first ask, which is
        // what `sizeThatFits` gives SwiftUI before the row is ever drawn.
        let wide = view.height(forWidth: 900)
        let narrow = view.height(forWidth: 300)
        XCTAssertGreaterThan(wide, PiFont.size * 8, "Every block has to be accounted for, not just the first")
        XCTAssertGreaterThan(narrow, wide, "A narrower measure wraps to more lines")

        // Repeated asks at one width are stable (SwiftUI probes sizes more than once per pass).
        XCTAssertEqual(view.height(forWidth: 300), narrow, accuracy: 0.5)
        XCTAssertEqual(view.height(forWidth: 900), wide, accuracy: 0.5)
    }

    @MainActor
    func testMissingWidthProposalUsesARealFirstPassMeasure() {
        let view = AnswerTextView()
        let blocks = MarkdownBlockParser.blocks(from: String(repeating: "A saved answer must be visible immediately. ", count: 20))
        view.apply(AnswerAttributedTextBuilder.build(blocks: blocks))

        let size = view.fittingSize(for: nil)
        XCTAssertEqual(size.width, PiTheme.transcriptMaxWidth)
        XCTAssertGreaterThan(size.height, PiFont.size * 2, "A nil first proposal must not collapse the lazy row to one point")
    }

    @MainActor
    func testEmptyAnswerStillReportsAPositiveHeightRatherThanZero() {
        let view = AnswerTextView()
        view.apply(AnswerAttributedTextBuilder.build(blocks: []))
        XCTAssertGreaterThanOrEqual(view.height(forWidth: 400), 1)
    }

    @MainActor
    func testCodeBlockOverlayIdentityIsStableAcrossRebuilds() throws {
        // Overlay ids used to be a fresh UUID per build, so every re-render replaced the copy
        // button views for unchanged code.
        let source = "```\nlet x = 1\n```\n\ntext\n\n```\nlet x = 1\n```"
        let blocks = MarkdownBlockParser.blocks(from: source)
        let first = AnswerAttributedTextBuilder.build(blocks: blocks).codeBlocks.map(\.id)
        let second = AnswerAttributedTextBuilder.build(blocks: blocks).codeBlocks.map(\.id)
        XCTAssertEqual(first, second, "The same answer must rebuild to the same code-block identities")
        XCTAssertEqual(Set(first).count, 2, "Two identical code blocks still get distinct identities")
    }

    @MainActor
    func testSettledAnswerHostAllocatesHeightForTheWholeAnswer() throws {
        let source = """
        Implemented and merged as `d5b1d67`.

        - Sidebar Automations page with create/edit/run/delete and pause switches.
        - `⌥⌘S` opens it without losing the current conversation or draft.
        - Build, release packaging, and 898 tests passed.
        """
        let host = NSHostingView(rootView: MarkdownAnswerText(text: source))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        // One synchronous layout pass, deliberately without a run loop turn: a saved answer must
        // be its full height the moment it is laid out, not after an async measurement lands.
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(descendant(AnswerTextView.self, in: host))
        XCTAssertGreaterThan(textView.frame.height, PiFont.size * 3, "The list must not be clipped below the first paragraph")
    }
}

final class MarkdownRunIdentityTests: XCTestCase {
    /// A thematic break used to mint a fresh UUID every time its `id` was read, so SwiftUI saw a
    /// brand-new view on every render and left stale text painted over new content.
    func testBlockIdentityIsStableAcrossReads() {
        let rule = MarkdownBlock.rule
        XCTAssertEqual(rule.id, rule.id)
        let paragraph = MarkdownBlock.paragraph("hello")
        XCTAssertEqual(paragraph.id, MarkdownBlock.paragraph("hello").id)
    }

    func testRepeatedContentStillGetsDistinctRunIdentities() {
        let table = MarkdownBlock.table(header: ["a"], alignment: [.leading], rows: [["1"]])
        let blocks: [MarkdownBlock] = [
            .paragraph("same"), table, .paragraph("same"), table, .rule, .rule
        ]
        let runs = MarkdownAnswerPartitioner.runs(from: blocks)
        let ids = runs.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "identical content must not collide into one view")

        // And the identity has to be stable when the same blocks are partitioned again.
        XCTAssertEqual(MarkdownAnswerPartitioner.runs(from: blocks).map(\.id), ids)
    }
}
