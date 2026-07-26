import Foundation
import XCTest
@testable import PiDesktop

final class MarkdownBlockTests: XCTestCase {
    // The exact regression from the report: consecutive lines used to render as
    // "KeychainUpdated meta to load it automaticallyDeleted the Bitwarden item".
    func testConsecutiveLinesStayOnSeparateLinesInsideOneParagraph() {
        let source = "Keychain\nUpdated meta to load it automatically\nDeleted the Bitwarden item"
        let blocks = MarkdownBlockParser.blocks(from: source)

        XCTAssertEqual(blocks.count, 1)
        guard case let .paragraph(text) = blocks[0] else { return XCTFail("Expected a paragraph") }
        XCTAssertEqual(text, source, "Newlines inside a paragraph are preserved verbatim")

        let attributed = MarkdownInline.attributed(text)
        XCTAssertTrue(String(attributed.characters).contains("\n"),
                      "inlineOnlyPreservingWhitespace must keep the hard breaks")
        XCTAssertEqual(String(attributed.characters), source)
    }

    func testBlankLinesSeparateParagraphs() {
        let blocks = MarkdownBlockParser.blocks(from: "First paragraph.\n\nSecond paragraph.\n\n\nThird.")
        XCTAssertEqual(blocks, [
            .paragraph("First paragraph."),
            .paragraph("Second paragraph."),
            .paragraph("Third.")
        ])
    }

    func testTrailingAndLeadingBlankLinesProduceNoEmptyBlocks() {
        let blocks = MarkdownBlockParser.blocks(from: "\n\n  \nOnly text\n\n  \n")
        XCTAssertEqual(blocks, [.paragraph("Only text")])
    }

    func testHeadingsAtEveryLevel() {
        let blocks = MarkdownBlockParser.blocks(from: "# One\n## Two\n###### Six\n####### NotAHeading")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 6, text: "Six"),
            .paragraph("####### NotAHeading")
        ])
    }

    func testClosedHeadingSequenceIsStripped() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks(from: "## Title ##"),
            [.heading(level: 2, text: "Title")]
        )
    }

    func testFencedCodePreservesInternalBlankLinesAndLanguage() {
        let source = """
        Intro text

        ```swift
        let a = 1

        let b = 2
        ```

        After
        """
        let blocks = MarkdownBlockParser.blocks(from: source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("Intro text"))
        XCTAssertEqual(blocks[1], .code(language: "swift", code: "let a = 1\n\nlet b = 2"))
        XCTAssertEqual(blocks[2], .paragraph("After"))
    }

    func testUnterminatedFenceCapturesTheRemainder() {
        let blocks = MarkdownBlockParser.blocks(from: "```\nstreaming code\nnot closed yet")
        XCTAssertEqual(blocks, [.code(language: nil, code: "streaming code\nnot closed yet")])
    }

    func testTildeFenceAndBacktickFenceBothWork() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks(from: "~~~sh\necho hi\n~~~"),
            [.code(language: "sh", code: "echo hi")]
        )
    }

    func testFencedCodeDoesNotSwallowMarkdownAfterTheClosingFence() {
        let blocks = MarkdownBlockParser.blocks(from: "```\ncode\n```\n# Heading")
        XCTAssertEqual(blocks, [
            .code(language: nil, code: "code"),
            .heading(level: 1, text: "Heading")
        ])
    }

    func testIndentedCodeBlock() {
        let blocks = MarkdownBlockParser.blocks(from: "Intro\n\n    indented one\n    indented two\n\nAfter")
        XCTAssertEqual(blocks, [
            .paragraph("Intro"),
            .code(language: nil, code: "indented one\nindented two"),
            .paragraph("After")
        ])
    }

    func testBulletListItemsAreSeparate() {
        let blocks = MarkdownBlockParser.blocks(from: "- first\n- second\n* third")
        guard case let .list(items, ordered, _) = blocks.first else { return XCTFail("Expected a list") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(items.map(\.marker), ["•", "•", "•"])
    }

    func testOrderedListKeepsNumbersAndStart() {
        let blocks = MarkdownBlockParser.blocks(from: "3. three\n4. four")
        guard case let .list(items, ordered, start) = blocks.first else { return XCTFail("Expected a list") }
        XCTAssertTrue(ordered)
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items.map(\.marker), ["3.", "4."])
    }

    func testTaskListMarkers() {
        let blocks = MarkdownBlockParser.blocks(from: "- [ ] todo\n- [x] done")
        guard case let .list(items, _, _) = blocks.first else { return XCTFail("Expected a list") }
        XCTAssertEqual(items.map(\.marker), ["☐", "☑"])
        XCTAssertEqual(items.map(\.text), ["todo", "done"])
    }

    func testListContinuationLineJoinsItsItem() {
        let blocks = MarkdownBlockParser.blocks(from: "- first line\n  continued here\n- second")
        guard case let .list(items, _, _) = blocks.first else { return XCTFail("Expected a list") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "first line\ncontinued here")
    }

    func testNestedListDepthFromIndentation() {
        let blocks = MarkdownBlockParser.blocks(from: "- top\n    - nested")
        guard case let .list(items, _, _) = blocks.first else { return XCTFail("Expected a list") }
        XCTAssertEqual(items.map(\.depth), [0, 2])
    }

    func testBlockquoteLinesGroupIntoOneBlock() {
        let blocks = MarkdownBlockParser.blocks(from: "> quoted one\n> quoted two\n\nplain")
        XCTAssertEqual(blocks, [
            .quote("quoted one\nquoted two"),
            .paragraph("plain")
        ])
    }

    func testThematicBreakIsNotConfusedWithABullet() {
        XCTAssertEqual(MarkdownBlockParser.blocks(from: "---"), [.rule])
        XCTAssertEqual(MarkdownBlockParser.blocks(from: "***"), [.rule])
        guard case .list = MarkdownBlockParser.blocks(from: "- item").first else {
            return XCTFail("A single dash bullet must stay a list")
        }
    }

    func testWindowsLineEndingsAreNormalized() {
        let blocks = MarkdownBlockParser.blocks(from: "one\r\n\r\ntwo")
        XCTAssertEqual(blocks, [.paragraph("one"), .paragraph("two")])
    }

    func testMixedDocumentProducesEveryBlockKindInOrder() {
        let source = """
        # Title

        Body line one
        Body line two

        - bullet

        > note

        ```json
        {"a":1}
        ```

        ---

        Closing.
        """
        let blocks = MarkdownBlockParser.blocks(from: source)
        XCTAssertEqual(blocks.count, 7)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .paragraph("Body line one\nBody line two"))
        guard case .list = blocks[2] else { return XCTFail("Expected a list at index 2") }
        XCTAssertEqual(blocks[3], .quote("note"))
        XCTAssertEqual(blocks[4], .code(language: "json", code: "{\"a\":1}"))
        XCTAssertEqual(blocks[5], .rule)
        XCTAssertEqual(blocks[6], .paragraph("Closing."))
    }

    func testInlineSpansAreParsedAndCodeSpansRestyled() {
        let attributed = MarkdownInline.attributed("Run `swift build` then **ship** it")
        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "Run swift build then ship it", "Inline markers are consumed")

        let codeRuns = attributed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertFalse(codeRuns.isEmpty, "The code span keeps its presentation intent")
        for run in codeRuns {
            XCTAssertNotNil(attributed[run.range].font, "Code spans get an explicit monospaced font")
        }
    }

    func testInlineLinkSurvivesAsAnAttribute() {
        let attributed = MarkdownInline.attributed("See [docs](https://pi.dev) now")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://pi.dev"])
    }

    func testLargeInputStaysBounded() {
        // A pathological transcript block must still split in linear time.
        let source = Array(repeating: "line", count: 5_000).joined(separator: "\n\n")
        let blocks = MarkdownBlockParser.blocks(from: source)
        XCTAssertEqual(blocks.count, 5_000)
    }

    // MARK: - Tables

    func testBasicTableParsesHeaderAlignmentAndRows() {
        let source = """
        | Name | Age | City |
        |:-----|:---:|-----:|
        | Ada  | 30  | NYC  |
        | Grace | 40 | DC |
        """
        let blocks = MarkdownBlockParser.blocks(from: source)
        XCTAssertEqual(blocks.count, 1)
        guard case let .table(header, alignment, rows) = blocks[0] else { return XCTFail("Expected a table") }
        XCTAssertEqual(header, ["Name", "Age", "City"])
        XCTAssertEqual(alignment, [.leading, .center, .trailing])
        XCTAssertEqual(rows, [["Ada", "30", "NYC"], ["Grace", "40", "DC"]])
    }

    func testTableWithoutOuterPipesStillParses() {
        let source = "Name | Score\n--- | ---\nAda | 9"
        let blocks = MarkdownBlockParser.blocks(from: source)
        guard case let .table(header, alignment, rows) = blocks.first else { return XCTFail("Expected a table") }
        XCTAssertEqual(header, ["Name", "Score"])
        XCTAssertEqual(alignment, [.none, .none])
        XCTAssertEqual(rows, [["Ada", "9"]])
    }

    func testRaggedRowsArePaddedAndTruncatedToHeaderWidth() {
        let source = "| A | B | C |\n|---|---|---|\n| short |\n| too | many | cells | here |"
        let blocks = MarkdownBlockParser.blocks(from: source)
        guard case let .table(_, _, rows) = blocks.first else { return XCTFail("Expected a table") }
        XCTAssertEqual(rows, [["short", "", ""], ["too", "many", "cells"]])
    }

    func testEscapedPipeDoesNotSplitACell() {
        let source = "| A | B |\n|---|---|\n| a \\| b | plain |"
        let blocks = MarkdownBlockParser.blocks(from: source)
        guard case let .table(_, _, rows) = blocks.first else { return XCTFail("Expected a table") }
        XCTAssertEqual(rows, [["a \\| b", "plain"]])
    }

    func testPipeInsideCodeSpanDoesNotSplitACell() {
        let source = "| A | B |\n|---|---|\n| `a\\|b` | plain |"
        let blocks = MarkdownBlockParser.blocks(from: source)
        guard case let .table(_, _, rows) = blocks.first else { return XCTFail("Expected a table") }
        XCTAssertEqual(rows.first?.first, "`a\\|b`")
    }

    func testTableCellsCarryInlineSpans() {
        let source = "| A |\n|---|\n| **bold** and `code` |"
        let blocks = MarkdownBlockParser.blocks(from: source)
        guard case let .table(_, _, rows) = blocks.first else { return XCTFail("Expected a table") }
        let attributed = MarkdownInline.attributed(rows[0][0])
        XCTAssertEqual(String(attributed.characters), "bold and code")
        XCTAssertTrue(attributed.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testInvalidDelimiterRowFallsBackToParagraphs() {
        // Column count mismatch: not a table, so both lines stay ordinary paragraph text.
        let blocks = MarkdownBlockParser.blocks(from: "A | B\n---|---|---")
        XCTAssertEqual(blocks, [.paragraph("A | B\n---|---|---")])
    }

    func testTableWithoutPipesIsNotDetected() {
        // No pipe anywhere: this is the classic setext-heading shape, not a one-column table.
        guard case .heading = MarkdownBlockParser.blocks(from: "Title\n---").first else {
            return XCTFail("A pipe-less pair must not become a table")
        }
    }

    func testTableCanInterruptAParagraphWithoutABlankLine() {
        let blocks = MarkdownBlockParser.blocks(from: "Intro\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .paragraph("Intro"))
        guard case .table = blocks[1] else { return XCTFail("Expected a table") }
    }

    // MARK: - Setext headings

    func testSetextHeadingsProduceH1AndH2() {
        XCTAssertEqual(MarkdownBlockParser.blocks(from: "Title\n====="), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownBlockParser.blocks(from: "Subtitle\n---"), [.heading(level: 2, text: "Subtitle")])
    }

    func testSetextHeadingCanSpanAMultiLineParagraph() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks(from: "Line one\nLine two\n==="),
            [.heading(level: 1, text: "Line one\nLine two")]
        )
    }

    func testLoneUnderlineWithoutAPrecedingParagraphStaysARule() {
        // Regression guard: setext must never hijack a standalone thematic break.
        XCTAssertEqual(MarkdownBlockParser.blocks(from: "---"), [.rule])
        XCTAssertEqual(MarkdownBlockParser.blocks(from: "Body\n\n---"), [.paragraph("Body"), .rule])
    }

    // MARK: - Nested/mixed list continuation

    func testBulletNestedUnderAnOrderedItemFoldsIntoOneList() {
        let blocks = MarkdownBlockParser.blocks(from: "1. First\n   - nested\n2. Second")
        XCTAssertEqual(blocks.count, 1, "A same-type sibling after a nested nested item must not split the list")
        guard case let .list(items, ordered, _) = blocks[0] else { return XCTFail("Expected one list") }
        XCTAssertTrue(ordered, "The list's own type follows its first item")
        XCTAssertEqual(items.map(\.text), ["First", "nested", "Second"])
        XCTAssertEqual(items.map(\.marker), ["1.", "•", "2."])
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
    }

    func testSiblingListOfADifferentTypeAtTopLevelStillStartsANewBlock() {
        let blocks = MarkdownBlockParser.blocks(from: "1. First\n- bullet")
        XCTAssertEqual(blocks.count, 2, "An unindented marker of the other kind ends the first list")
        guard case let .list(first, firstOrdered, _) = blocks[0] else { return XCTFail("Expected a list") }
        XCTAssertTrue(firstOrdered)
        XCTAssertEqual(first.map(\.text), ["First"])
        guard case let .list(second, secondOrdered, _) = blocks[1] else { return XCTFail("Expected a second list") }
        XCTAssertFalse(secondOrdered)
        XCTAssertEqual(second.map(\.text), ["bullet"])
    }

    // MARK: - Strikethrough

    func testStrikethroughIsRecognizedAsAPresentationIntent() {
        let attributed = MarkdownInline.attributed("~~gone~~ stays")
        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "gone stays")
        let struck = attributed.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }
        XCTAssertTrue(struck, "~~text~~ must carry a strikethrough presentation intent")
    }

    // MARK: - Autolinks

    func testBareHTTPURLBecomesAClickableLink() {
        let attributed = MarkdownInline.attributed("See https://pi.dev/docs for more")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://pi.dev/docs"])
        XCTAssertEqual(String(attributed.characters), "See https://pi.dev/docs for more", "The visible text is untouched")
    }

    func testAngleBracketAutolinkIsClickable() {
        let attributed = MarkdownInline.attributed("<https://pi.dev>")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://pi.dev"])
    }

    func testBareURLInsideAnExistingMarkdownLinkIsNotDoubleLinked() {
        let attributed = MarkdownInline.attributed("[docs](https://pi.dev/docs)")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.absoluteString, "https://pi.dev/docs")
    }

    // MARK: - Hard line breaks

    func testTrailingBackslashHardBreakIsConsumedNotShownLiterally() {
        let blocks = MarkdownBlockParser.blocks(from: "line one\\\nline two")
        XCTAssertEqual(blocks, [.paragraph("line one\nline two")], "The break marker itself must not remain visible")
    }

    func testEscapedTrailingBackslashPairIsKeptLiteral() {
        let blocks = MarkdownBlockParser.blocks(from: "line one\\\\\nline two")
        XCTAssertEqual(blocks, [.paragraph("line one\\\\\nline two")], "An even run is a literal escaped backslash, not a break marker")
    }

    // MARK: - Inline code containing backticks

    func testInlineCodeSpanCanContainABacktickUsingADoubleBacktickFence() {
        let attributed = MarkdownInline.attributed("Use `` `quoted` `` here")
        let codeRuns = attributed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertFalse(codeRuns.isEmpty, "A double-backtick fence must still produce a code span")
        let codeText = codeRuns.map { String(attributed.characters[$0.range]) }.joined()
        XCTAssertTrue(codeText.contains("`quoted`"), "The inner backticks are content, not delimiters")
    }
}
