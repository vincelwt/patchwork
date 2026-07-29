import AppKit
import SwiftUI
import XCTest
@testable import PiDesktop

private func descendant<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
    if let match = root as? View { return match }
    return root.subviews.lazy.compactMap { descendant(type, in: $0) }.first
}

/// Covers the answer attributed-string builder (including native table layout) and text sizing.
/// Real AppKit drag/selection interaction is not exercised here, the same way the rest of the
/// suite never simulates mouse events — see `ComposerInlineImageTests` for the established pattern
/// of testing AppKit text state programmatically instead.
final class SelectableAnswerTextTests: XCTestCase {
    // MARK: - Tables (one shared selection, not a separate island)

    func testTableCellsAreLaidOutAsOneNativeTextTableInTheSameString() throws {
        let blocks = MarkdownBlockParser.blocks(from: """
        before

        | Feedback | Fix |
        | --- | ---: |
        | not clickable | recap passes onWordPress |

        after
        """)
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string

        for fragment in ["before", "Feedback", "Fix", "not clickable", "recap passes onWordPress", "after"] {
            XCTAssertTrue(string.contains(fragment), "\(fragment) must live in the same selectable string")
        }

        // Every cell belongs to one and the same NSTextTable, which is what lets a drag cross rows.
        var tables: [NSTextTable] = []
        for fragment in ["Feedback", "Fix", "not clickable", "recap passes onWordPress"] {
            let range = NSRange(try XCTUnwrap(string.range(of: fragment)), in: string)
            let style = try XCTUnwrap(
                built.attributedString.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            )
            let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock, "\(fragment) must be a table cell")
            tables.append(block.table)
        }
        XCTAssertEqual(tables.count, 4)
        XCTAssertTrue(tables.allSatisfy { $0 === tables[0] })
        XCTAssertEqual(tables[0].numberOfColumns, 2)

        // Prose around the table is plain text, not a cell.
        let beforeRange = NSRange(try XCTUnwrap(string.range(of: "before")), in: string)
        let beforeStyle = built.attributedString.attribute(.paragraphStyle, at: beforeRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(beforeStyle?.textBlocks.isEmpty ?? true)
    }

    func testTableRespectsPerColumnAlignment() throws {
        let blocks = MarkdownBlockParser.blocks(from: "| L | C | R |\n| :--- | :---: | ---: |\n| a | b | c |")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks)
        let string = built.attributedString.string
        for (fragment, expected) in [("a", NSTextAlignment.left), ("b", .center), ("c", .right)] {
            let range = NSRange(try XCTUnwrap(string.range(of: fragment)), in: string)
            let style = try XCTUnwrap(
                built.attributedString.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            )
            XCTAssertEqual(style.alignment, expected, fragment)
        }
    }

    @MainActor
    func testAnAnswerWithATableStillMeasuresTallerThanASingleRow() {
        let blocks = MarkdownBlockParser.blocks(from: "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |")
        let view = AnswerTextView()
        view.apply(AnswerAttributedTextBuilder.build(blocks: blocks))
        XCTAssertGreaterThan(view.height(forWidth: 600), PiFont.size * 3, "Header plus two rows must all be laid out")
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

    func testTableBlockIdentityIsStableAcrossReads() {
        let table = MarkdownBlock.table(header: ["a"], alignment: [.leading], rows: [["1"]])
        XCTAssertEqual(table.id, table.id)
    }
}
