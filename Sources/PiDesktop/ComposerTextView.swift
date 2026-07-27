import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer's content: plain text with the attachment placeholders removed, plus the inline
/// image attachments in the exact order they appear in the text.
struct ComposerContent: Equatable {
    var text: String
    var attachments: [ImageAttachment]

    static let empty = ComposerContent(text: "", attachments: [])

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

/// Imperative hooks the SwiftUI composer uses to reach into the AppKit text view (insert an
/// attachment at the caret, focus the field) without owning it.
final class ComposerBridge {
    var insertImages: (([ImageAttachment]) -> Void)?
    var focus: (() -> Void)?
}

/// An `NSTextAttachment` that remembers which `ImageAttachment` it renders, so the text view can
/// map inline placeholders back to local image paths in order.
final class ComposerImageAttachment: NSTextAttachment {
    let attachmentID: UUID

    init(attachment: ImageAttachment) {
        self.attachmentID = attachment.id
        super.init(data: nil, ofType: nil)
        let preview = attachment.image
        image = preview
        if let preview, preview.size.height > 0 {
            let scale = PiTheme.inlineAttachmentHeight / preview.size.height
            let width = min(PiTheme.inlineAttachmentMaxWidth, max(24, preview.size.width * scale))
            bounds = CGRect(x: 0, y: -3, width: width, height: PiTheme.inlineAttachmentHeight)
        } else {
            bounds = CGRect(x: 0, y: -3, width: 40, height: PiTheme.inlineAttachmentHeight)
        }
    }

    required init?(coder: NSCoder) { fatalError("ComposerImageAttachment is created programmatically") }
}

/// A native text view that previews pasted, dropped, and attached images inline at the caret.
/// Deleting the placeholder character removes the attachment; sending strips the placeholders and
/// appends the remaining attachments' local file paths to the prompt in reading order.
struct NativeComposerTextView: NSViewRepresentable {
    @Binding var content: ComposerContent
    let bridge: ComposerBridge
    var placeholder = ""
    var autofocus = false
    let onSubmit: () -> Void
    var onEscape: ((Bool) -> Void)? = nil
    /// Applies the image budgets and returns the accepted subset.
    let admitImages: ([ImageAttachment], [ImageAttachment]) -> [ImageAttachment]
    /// Intrinsic content height, so the composer grows with the text (and inline images)
    /// instead of always occupying its maximum.
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        // Rich text is required for inline attachments; pasted styling is normalized by
        // `paste(_:)`, which only ever inserts plain text or our own attachments.
        textView.isRichText = true
        // Without this, AppKit validates Edit ▸ Paste against the text view's readable types and
        // disables ⌘V for an image-only pasteboard, so `paste(_:)` is never called at all.
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = PiFont.composerNSFont
        textView.textColor = .labelColor
        textView.typingAttributes = ComposerTextView.baseAttributes
        textView.defaultParagraphStyle = ComposerTextView.paragraphStyle
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.autofocusOnWindow = autofocus
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onHeightChange = onHeightChange
        textView.setAccessibilityLabel("Message")
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        context.coordinator.textView = textView
        textView.coordinator = context.coordinator
        textView.apply(content: content)

        bridge.insertImages = { [weak textView] images in
            guard let textView else { return }
            textView.insertImages(images, at: nil)
        }
        bridge.focus = { [weak textView] in
            textView?.window?.makeFirstResponder(textView)
        }

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        textView.placeholder = placeholder
        textView.autofocusOnWindow = autofocus
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onHeightChange = onHeightChange
        // Only rebuild when the model diverges from what the view last published, so typing is
        // never interrupted by a round trip through SwiftUI state.
        if context.coordinator.published != content {
            textView.apply(content: content)
            context.coordinator.published = content
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerTextView
        weak var textView: ComposerTextView?
        var published: ComposerContent = .empty

        init(_ parent: NativeComposerTextView) {
            self.parent = parent
            self.published = parent.content
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            let value = view.currentContent()
            published = value
            parent.content = value
        }

        func admit(_ images: [ImageAttachment]) -> [ImageAttachment] {
            guard let existing = textView?.currentContent().attachments else { return [] }
            return parent.admitImages(images, existing)
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: ((Bool) -> Void)? { didSet { if onEscape == nil { firstEscapeTime = nil } } }
    var onHeightChange: ((CGFloat) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var autofocusOnWindow = false
    weak var coordinator: NativeComposerTextView.Coordinator?
    private var reportedHeight: CGFloat = 0
    private var didAutofocus = false
    private var firstEscapeTime: TimeInterval?
    private static let doubleEscapeInterval: TimeInterval = 0.5
    /// Attachments currently represented by an inline placeholder, keyed by identity.
    private var known: [UUID: ImageAttachment] = [:]

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }()

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PiFont.composerNSFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    // MARK: Content projection

    /// Walks the attributed string once, producing the plain text (placeholders removed) and the
    /// attachments in inline order.
    func currentContent() -> ComposerContent {
        guard let storage = textStorage else { return .empty }
        var text = String()
        var ordered: [ImageAttachment] = []
        var seen: Set<UUID> = []

        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? ComposerImageAttachment {
                if let model = known[attachment.attachmentID], seen.insert(attachment.attachmentID).inserted {
                    ordered.append(model)
                }
                return
            }
            if value != nil { return }
            text.append(storage.attributedSubstring(from: range).string)
        }

        // Any stray placeholder from an unknown attachment source is dropped, never sent.
        return ComposerContent(text: text.replacingOccurrences(of: "\u{FFFC}", with: ""), attachments: ordered)
    }

    /// Rebuilds the view from a model value (draft restore, `set_editor_text`, send clearing).
    func apply(content: ComposerContent) {
        let selection = selectedRange()
        let result = NSMutableAttributedString(string: content.text, attributes: Self.baseAttributes)
        known = Dictionary(uniqueKeysWithValues: content.attachments.map { ($0.id, $0) })
        // Externally supplied attachments are appended after the text, which is what a draft
        // restore or extension-driven editor update means.
        for attachment in content.attachments {
            let inline = NSMutableAttributedString(attachment: ComposerImageAttachment(attachment: attachment))
            inline.addAttributes(Self.baseAttributes, range: NSRange(location: 0, length: inline.length))
            result.append(inline)
        }
        textStorage?.setAttributedString(result)
        typingAttributes = Self.baseAttributes
        let location = min(selection.location, result.length)
        setSelectedRange(NSRange(location: location, length: 0))
        needsDisplay = true
        reportHeight()
    }

    // MARK: Placeholder and focus

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, window?.firstResponder !== self, !placeholder.isEmpty else { return }
        let fragmentPadding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(
            x: textContainerInset.width + fragmentPadding,
            y: textContainerInset.height
        )
        placeholder.draw(at: origin, withAttributes: [
            .font: PiFont.composerNSFont,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: Self.paragraphStyle
        ])
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard autofocusOnWindow, !didAutofocus, window != nil else { return }
        didAutofocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    // MARK: Intrinsic height

    /// Publishes the laid-out content height so SwiftUI can size the composer to its text.
    func reportHeight() {
        guard let container = textContainer, let manager = layoutManager else { return }
        manager.ensureLayout(for: container)
        let height = (manager.usedRect(for: container).height + textContainerInset.height * 2).rounded(.up)
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        onHeightChange?(height)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        reportHeight()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width changes rewrap the text, which changes the intrinsic height.
        reportHeight()
    }

    // MARK: Insertion

    func insertImages(_ images: [ImageAttachment], at location: Int?) {
        guard let coordinator else { return }
        let accepted = coordinator.admit(images)
        guard !accepted.isEmpty else { return }

        let insertion = NSMutableAttributedString()
        for attachment in accepted {
            known[attachment.id] = attachment
            let inline = NSMutableAttributedString(attachment: ComposerImageAttachment(attachment: attachment))
            inline.addAttributes(Self.baseAttributes, range: NSRange(location: 0, length: inline.length))
            insertion.append(inline)
        }

        let target = location.map { NSRange(location: min($0, textStorage?.length ?? 0), length: 0) } ?? selectedRange()
        if shouldChangeText(in: target, replacementString: insertion.string) {
            textStorage?.replaceCharacters(in: target, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: target.location + insertion.length, length: 0))
        }
        typingAttributes = Self.baseAttributes
    }

    // MARK: Key handling

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        if event.keyCode == 53, modifiers.isEmpty, !hasMarkedText(), let onEscape {
            if event.isARepeat { return }
            if let firstEscapeTime,
               event.timestamp >= firstEscapeTime,
               event.timestamp - firstEscapeTime < Self.doubleEscapeInterval {
                self.firstEscapeTime = nil
                onEscape(true)
            } else {
                let timestamp = event.timestamp
                firstEscapeTime = timestamp
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleEscapeInterval) { [weak self] in
                    guard let self, self.firstEscapeTime == timestamp else { return }
                    self.firstEscapeTime = nil
                    self.onEscape?(false)
                }
            }
            return
        }
        if firstEscapeTime != nil {
            firstEscapeTime = nil
            onEscape?(false)
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText(), !modifiers.contains(.shift) { onSubmit?(); return }
        super.keyDown(with: event)
    }

    /// Images become inline attachments; everything else is inserted as plain text so the
    /// composer never accumulates foreign fonts or colours.
    override func paste(_ sender: Any?) {
        let images = ImageImportService.attachments(from: NSPasteboard.general)
        if !images.isEmpty {
            insertImages(images, at: nil)
            return
        }
        if let plain = NSPasteboard.general.string(forType: .string) {
            insertText(plain, replacementRange: selectedRange())
            typingAttributes = Self.baseAttributes
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Images and file URLs must be readable for ⌘V to stay enabled; the actual insertion is
    /// always performed by `paste(_:)` above, never by AppKit's own image import.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for candidate in [NSPasteboard.PasteboardType.png, .tiff, .fileURL] where !types.contains(candidate) {
            types.append(candidate)
        }
        return types
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) {
            return NSPasteboard.general.string(forType: .string) != nil
                || ImageImportService.canReadImages(from: NSPasteboard.general)
        }
        return super.validateUserInterfaceItem(item)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageImportService.canReadImages(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageImportService.canReadImages(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = ImageImportService.attachments(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        insertImages(images, at: index)
        window?.makeFirstResponder(self)
        return true
    }
}

// MARK: - Import

enum ImageImportService {
    private static let temporaryImageCountLimit = 64
    static let dropTypes: [UTType] = [.fileURL, .image]

    static func canReadImages(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func attachments(from pasteboard: NSPasteboard) -> [ImageAttachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] ?? []
        let files = attachments(from: urls)
        if !files.isEmpty { return files }
        if let data = pasteboard.data(forType: .png), data.count <= PiTheme.imageByteLimit,
           let attachment = temporaryAttachment(data: data, mimeType: "image/png", fileName: "Pasted image.png") {
            return [attachment]
        }
        if let tiff = pasteboard.data(forType: .tiff), tiff.count <= PiTheme.imageByteLimit,
           let image = NSImage(data: tiff), let png = pngData(from: image), png.count <= PiTheme.imageByteLimit,
           let attachment = temporaryAttachment(data: png, mimeType: "image/png", fileName: "Pasted image.png") {
            return [attachment]
        }
        return []
    }

    static func attachments(from urls: [URL]) -> [ImageAttachment] {
        urls.prefix(PiTheme.imageCountLimit).compactMap { url in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= PiTheme.imageByteLimit,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return ImageAttachment(
                data: data,
                mimeType: type.preferredMIMEType ?? "image/\(url.pathExtension.lowercased())",
                fileName: url.lastPathComponent,
                fileURL: url
            )
        }
    }

    @discardableResult
    static func loadDroppedAttachments(
        from providers: [NSItemProvider],
        completion: @escaping ([ImageAttachment]) -> Void
    ) -> Bool {
        let providers = Array(providers.filter { provider in
            dropTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }.prefix(PiTheme.imageCountLimit))
        guard !providers.isEmpty else { return false }

        var loaded: [(Int, ImageAttachment)] = []
        var remaining = providers.count
        for (index, provider) in providers.enumerated() {
            loadDroppedAttachment(from: provider) { attachment in
                DispatchQueue.main.async {
                    if let attachment { loaded.append((index, attachment)) }
                    remaining -= 1
                    if remaining == 0 { completion(loaded.sorted { $0.0 < $1.0 }.map(\.1)) }
                }
            }
        }
        return true
    }

    private static func loadDroppedAttachment(
        from provider: NSItemProvider,
        completion: @escaping (ImageAttachment?) -> Void
    ) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = droppedURL(from: item), let attachment = attachments(from: [url]).first {
                    completion(attachment)
                } else {
                    loadDroppedImage(from: provider, completion: completion)
                }
            }
        } else {
            loadDroppedImage(from: provider, completion: completion)
        }
    }

    private static func loadDroppedImage(
        from provider: NSItemProvider,
        completion: @escaping (ImageAttachment?) -> Void
    ) {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { completion(nil); return }
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
            guard let data, data.count <= PiTheme.imageByteLimit,
                  let image = NSImage(data: data), let png = pngData(from: image),
                  png.count <= PiTheme.imageByteLimit else { completion(nil); return }
            completion(temporaryAttachment(data: png, mimeType: "image/png", fileName: "Dropped image.png"))
        }
    }

    private static func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let value = item as? String { return URL(string: value) }
        return nil
    }

    static func attachment(from image: ImagePayload) -> ImageAttachment? {
        let fallbackName = "Image.\(UTType(mimeType: image.mimeType)?.preferredFilenameExtension ?? "png")"
        return temporaryAttachment(
            data: image.data,
            mimeType: image.mimeType,
            fileName: image.fileName ?? fallbackName
        )
    }

    private static func temporaryAttachment(data: Data, mimeType: String, fileName: String) -> ImageAttachment? {
        let manager = FileManager.default
        let directory = ImageAttachment.temporaryDirectory
        let id = UUID()
        var url = directory.appendingPathComponent(id.uuidString)
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
        if !pathExtension.isEmpty { url.appendPathExtension(pathExtension) }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            pruneTemporaryImages(in: directory, keeping: url)
            return ImageAttachment(id: id, data: data, mimeType: mimeType, fileName: fileName, fileURL: url)
        } catch {
            return nil
        }
    }

    static func pruneTemporaryImages(
        in directory: URL,
        keeping current: URL,
        limit: Int = temporaryImageCountLimit
    ) {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []).sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for stale in files.filter({ $0 != current }).prefix(max(0, files.count - limit)) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
