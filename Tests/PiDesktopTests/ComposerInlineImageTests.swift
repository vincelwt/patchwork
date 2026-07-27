import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PiDesktop

/// A minimal `NSDraggingInfo` so the Finder drop entry point can be exercised deterministically
/// instead of choreographing a real drag.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var draggingLocation: NSPoint

    init(pasteboard: NSPasteboard, location: NSPoint) {
        self.pasteboard = pasteboard
        self.draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

@MainActor
final class ComposerInlineImageTests: XCTestCase {
    private var directory: URL!
    private var contentBox: ComposerContent = .empty

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiComposer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        contentBox = .empty
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func writePNG(named name: String, width: Int = 8, height: Int = 8) throws -> URL {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func escapeEvent(at timestamp: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
    }

    /// A text view wired the same way `NativeComposerTextView.makeNSView` wires it.
    private func makeTextView() -> ComposerTextView {
        let textView = ComposerTextView()
        textView.isRichText = true
        textView.importsGraphics = true
        textView.font = PiFont.composerNSFont
        textView.typingAttributes = ComposerTextView.baseAttributes
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 80)

        let binding = Binding<ComposerContent>(
            get: { [unowned self] in contentBox },
            set: { [unowned self] value in contentBox = value }
        )
        let representable = NativeComposerTextView(
            content: binding,
            bridge: ComposerBridge(),
            onSubmit: {},
            // The real store applies the same budgets; the composer only needs the accepted set.
            admitImages: { candidates, existing in
                Array(candidates.prefix(max(0, PiTheme.imageCountLimit - existing.count)))
            },
            onHeightChange: { _ in }
        )
        let coordinator = NativeComposerTextView.Coordinator(representable)
        coordinator.textView = textView
        textView.coordinator = coordinator
        textView.delegate = coordinator
        return textView
    }

    // MARK: - Import

    func testFileURLsBecomeAttachments() throws {
        let url = try writePNG(named: "one.png")
        let attachments = ImageImportService.attachments(from: [url])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.fileName, "one.png")
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
        XCTAssertEqual(attachments.first?.fileURL, url.standardizedFileURL)
        XCTAssertNotNil(attachments.first?.image)
    }

    func testNonImageFilesAreIgnored() throws {
        let url = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)
        XCTAssertTrue(ImageImportService.attachments(from: [url]).isEmpty)
    }

    func testPasteboardPNGBecomesAnAttachment() throws {
        let url = try writePNG(named: "clip.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PiDesktopTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: url), forType: .png)

        XCTAssertTrue(ImageImportService.canReadImages(from: pasteboard))
        let attachments = ImageImportService.attachments(from: pasteboard)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.fileName, "Pasted image.png")
        let path = try XCTUnwrap(attachments.first?.fileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        try FileManager.default.removeItem(atPath: path)
        _ = ImageAttachment.prompt(text: "Inspect it", attachments: attachments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Sending recreates a pruned temporary image")
    }

    func testTemporaryImageCachePrunesTheOldestFiles() throws {
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let files = (0..<3).map { cache.appendingPathComponent("\($0).png") }
        for (index, file) in files.enumerated() {
            try Data([UInt8(index)]).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: file.path
            )
        }

        ImageImportService.pruneTemporaryImages(in: cache, keeping: files[2], limit: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[2].path))
    }

    // MARK: - Inline placeholders

    func testInsertedImagesBecomeInlinePlaceholdersInReadingOrder() throws {
        let textView = makeTextView()
        textView.string = ""
        textView.insertText("look at this: ", replacementRange: NSRange(location: 0, length: 0))

        let first = try writePNG(named: "a.png", width: 6, height: 6)
        let second = try writePNG(named: "b.png", width: 10, height: 10)
        let attachments = ImageImportService.attachments(from: [first, second])
        XCTAssertEqual(attachments.count, 2)
        textView.insertImages(attachments, at: nil)

        // The text view holds one U+FFFC per image…
        let raw = textView.string
        XCTAssertEqual(raw.filter { $0 == "\u{FFFC}" }.count, 2)

        // …and the projected content strips them while preserving inline order.
        let content = textView.currentContent()
        XCTAssertEqual(content.text, "look at this: ")
        XCTAssertEqual(content.attachments.map(\.fileName), ["a.png", "b.png"])
        XCTAssertFalse(content.text.contains("\u{FFFC}"))
    }

    func testImagesInsertedAtTheCaretKeepDocumentOrderNotInsertionOrder() throws {
        let textView = makeTextView()
        textView.insertText("start end", replacementRange: NSRange(location: 0, length: 0))

        let tail = try writePNG(named: "tail.png")
        textView.insertImages(ImageImportService.attachments(from: [tail]), at: 9)
        let head = try writePNG(named: "head.png")
        textView.insertImages(ImageImportService.attachments(from: [head]), at: 0)

        // head.png was inserted second but sits first in the document.
        XCTAssertEqual(textView.currentContent().attachments.map(\.fileName), ["head.png", "tail.png"])
        XCTAssertEqual(textView.currentContent().text, "start end")
    }

    func testDeletingThePlaceholderRemovesTheAttachment() throws {
        let textView = makeTextView()
        let url = try writePNG(named: "drop.png")
        textView.insertImages(ImageImportService.attachments(from: [url]), at: nil)
        XCTAssertEqual(textView.currentContent().attachments.count, 1)

        // Exactly what Backspace over the attachment character does.
        let length = textView.string.utf16.count
        textView.textStorage?.replaceCharacters(in: NSRange(location: length - 1, length: 1), with: "")
        XCTAssertTrue(textView.currentContent().attachments.isEmpty)
        XCTAssertEqual(textView.currentContent().text, "")
    }

    func testApplyingModelContentRebuildsInlineAttachments() throws {
        let textView = makeTextView()
        let url = try writePNG(named: "restored.png")
        let attachment = try XCTUnwrap(ImageImportService.attachments(from: [url]).first)

        textView.apply(content: ComposerContent(text: "restored draft", attachments: [attachment]))
        let content = textView.currentContent()
        XCTAssertEqual(content.text, "restored draft")
        XCTAssertEqual(content.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(textView.string.filter { $0 == "\u{FFFC}" }.count, 1)
    }

    func testInlineImagesPublishAComposerHeightAfterTheUpdatePass() async throws {
        let textView = makeTextView()
        var heights: [CGFloat] = []
        textView.onHeightChange = { heights.append($0) }
        let attachment = try XCTUnwrap(
            ImageImportService.attachments(from: [try writePNG(named: "tall.png", width: 40, height: 40)]).first
        )

        textView.apply(content: ComposerContent(text: "look", attachments: [attachment]))
        XCTAssertTrue(heights.isEmpty, "SwiftUI must receive the height after its update pass")

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let published = try XCTUnwrap(heights.last)
        XCTAssertGreaterThanOrEqual(published, PiTheme.inlineAttachmentHeight)
        XCTAssertGreaterThan(published, PiTheme.composerMinEditorHeight)
    }

    // MARK: - Key handling

    func testDoubleEscapeCancelsThePendingSingleEscapeAndFullyStops() {
        let textView = ComposerTextView()
        var fullyStops: [Bool] = []
        textView.onEscape = { fullyStops.append($0) }

        textView.keyDown(with: escapeEvent(at: 1))
        XCTAssertTrue(fullyStops.isEmpty, "The first Escape waits to distinguish a single from a double press")

        textView.keyDown(with: escapeEvent(at: 1.1))
        XCTAssertEqual(fullyStops, [true])
    }

    // MARK: - Finder drop

    func testFinderDropInsertsInlineAttachments() throws {
        let textView = makeTextView()
        textView.insertText("before", replacementRange: NSRange(location: 0, length: 0))

        let url = try writePNG(named: "dragged.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PiDesktopDrop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        let info = FakeDraggingInfo(pasteboard: pasteboard, location: NSPoint(x: 10, y: 10))
        XCTAssertEqual(textView.draggingEntered(info), .copy, "An image drag must be accepted")
        XCTAssertTrue(textView.performDragOperation(info))

        let content = textView.currentContent()
        XCTAssertEqual(content.attachments.map(\.fileName), ["dragged.png"])
        XCTAssertEqual(content.text, "before")
    }

    func testDroppingANonImageIsNotHandledAsAnImage() throws {
        let textView = makeTextView()
        let url = directory.appendingPathComponent("plain.txt")
        try Data("nope".utf8).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PiDesktopDrop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        let info = FakeDraggingInfo(pasteboard: pasteboard, location: .zero)
        XCTAssertFalse(ImageImportService.canReadImages(from: pasteboard))
        _ = textView.performDragOperation(info)
        XCTAssertTrue(textView.currentContent().attachments.isEmpty)
    }

    func testFullConversationDropLoadsFileAndRawImageProvidersInOrder() async throws {
        let source = try writePNG(named: "provider.png")
        let fileProvider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let rawProvider = NSItemProvider(
            item: try Data(contentsOf: source) as NSData,
            typeIdentifier: UTType.png.identifier
        )
        let attachments = await withCheckedContinuation { continuation in
            XCTAssertTrue(ImageImportService.loadDroppedAttachments(from: [fileProvider, rawProvider]) {
                continuation.resume(returning: $0)
            })
        }

        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments[0].fileURL, source.standardizedFileURL)
        XCTAssertEqual(attachments[1].mimeType, "image/png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments[1].fileURL.path))
    }

    func testExistingAndNewConversationAreasRegisterImageFileDropTargets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["ConversationView.swift", "NewChatView.swift"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("Sources/PiDesktop/\(file)"),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains(".contentShape(Rectangle())"), file)
            XCTAssertTrue(source.contains(".onDrop(of: ImageImportService.dropTypes"), file)
            XCTAssertTrue(source.contains("store.addAttachments(images)"), file)
        }
    }

    func testModeLabelKeepsItsIntrinsicWidth() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PiDesktop/ComposerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains(".lineLimit(1)\n                .fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(source.contains(".frame(width: 34, alignment: .trailing)"))
    }

    // MARK: - Budgets

    func testCountBudgetIsAppliedToInlineInsertion() throws {
        let textView = makeTextView()
        var urls: [URL] = []
        for index in 0..<(PiTheme.imageCountLimit + 3) {
            urls.append(try writePNG(named: "img\(index).png"))
        }
        // ImageImportService already caps a single import at the count limit.
        let attachments = ImageImportService.attachments(from: urls)
        XCTAssertEqual(attachments.count, PiTheme.imageCountLimit)

        textView.insertImages(attachments, at: nil)
        XCTAssertEqual(textView.currentContent().attachments.count, PiTheme.imageCountLimit)

        // One more must be refused by the admission closure rather than appended.
        let extra = try writePNG(named: "extra.png")
        textView.insertImages(ImageImportService.attachments(from: [extra]), at: nil)
        XCTAssertEqual(textView.currentContent().attachments.count, PiTheme.imageCountLimit)
    }

    func testPromptFilePathsFollowInlineOrder() throws {
        let textView = makeTextView()
        let first = try writePNG(named: "1.png", width: 4, height: 4)
        let second = try writePNG(named: "2.png", width: 5, height: 5)
        textView.insertImages(ImageImportService.attachments(from: [first, second]), at: nil)

        let prompt = ImageAttachment.prompt(text: "Compare these", attachments: textView.currentContent().attachments)
        XCTAssertEqual(
            prompt,
            "Compare these\n\nAttached image file paths:\n- \(first.path)\n- \(second.path)"
        )
        XCTAssertFalse(prompt.contains(textView.currentContent().attachments[0].data.base64EncodedString()))
    }
}
