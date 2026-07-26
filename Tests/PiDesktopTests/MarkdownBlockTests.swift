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
}
