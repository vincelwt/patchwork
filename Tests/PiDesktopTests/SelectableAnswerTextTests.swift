import AppKit
import XCTest
@testable import PiDesktop

/// Covers the two pieces of the cross-block answer selection view that are meaningfully testable
/// without a rendering host: the run partitioner (pure), and the attributed-string builder that
/// stands in for what a drag-select + ⌘C over the whole answer would actually copy. Real AppKit
/// drag/selection interaction is not exercised here, the same way the rest of the suite never
/// simulates mouse events — see `ComposerInlineImageTests` for the established pattern of testing
/// AppKit text state programmatically instead.
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

    func testBoldSpanGetsABoldFontTrait() throws {
        let blocks = MarkdownBlockParser.blocks(from: "plain **bold** plain")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "bold"))
        let nsRange = NSRange(range, in: string)
        let font = try XCTUnwrap(built.attributedString.attribute(.font, at: nsRange.location, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        XCTAssertTrue(traits.contains(.boldFontMask), "A **bold** run must resolve to a concrete bold NSFont trait")
    }

    func testMarkdownLinkCarriesItsURLAttribute() throws {
        let blocks = MarkdownBlockParser.blocks(from: "See [docs](https://pi.dev/docs) now")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "docs"))
        let nsRange = NSRange(range, in: string)
        let link = built.attributedString.attribute(.link, at: nsRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://pi.dev/docs")
    }

    func testBareURLIsAutolinkedInTheBuiltAttributedString() throws {
        let blocks = MarkdownBlockParser.blocks(from: "Visit https://pi.dev/docs today")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "https://pi.dev/docs"))
        let nsRange = NSRange(range, in: string)
        let link = built.attributedString.attribute(.link, at: nsRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://pi.dev/docs", "The same autolink pass MarkdownInline uses everywhere else must apply here too")
    }

    func testStrikethroughSpanCarriesTheStrikethroughAttribute() throws {
        let blocks = MarkdownBlockParser.blocks(from: "before ~~gone~~ after")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "gone"))
        let nsRange = NSRange(range, in: string)
        let style = built.attributedString.attribute(.strikethroughStyle, at: nsRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
    }

    func testCodeBlockIsRecordedWithItsExactSourceAndAMonospacedFont() throws {
        let blocks = MarkdownBlockParser.blocks(from: "Before\n\n```swift\nlet x = 1\n```\n\nAfter")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
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
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
        XCTAssertTrue(built.codeBlocks.isEmpty, "An inline code span is not a fenced code block")
        let string = built.attributedString.string
        let range = try XCTUnwrap(string.range(of: "swift build"))
        let nsRange = NSRange(range, in: string)
        let font = try XCTUnwrap(built.attributedString.attribute(.font, at: nsRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testHeadingRendersLargerThanBody() throws {
        let blocks = MarkdownBlockParser.blocks(from: "# Title\n\nBody text")
        let built = AnswerAttributedTextBuilder.build(blocks: blocks, size: PiFont.bodySize)
        let string = built.attributedString.string
        let titleRange = NSRange((try XCTUnwrap(string.range(of: "Title"))), in: string)
        let bodyRange = NSRange((try XCTUnwrap(string.range(of: "Body text"))), in: string)
        let titleFont = try XCTUnwrap(built.attributedString.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(built.attributedString.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(titleFont.pointSize, bodyFont.pointSize)
    }

    func testEmptyBlockListProducesEmptyAttributedString() {
        let built = AnswerAttributedTextBuilder.build(blocks: [], size: PiFont.bodySize)
        XCTAssertEqual(built.attributedString.length, 0)
        XCTAssertTrue(built.codeBlocks.isEmpty)
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
