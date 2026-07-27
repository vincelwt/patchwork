import AppKit
import SwiftUI

// MARK: - Investigation note (task: cross-block answer selection)
//
// A plain `.textSelection(.enabled)` on a container around several `Text` views does not merge
// their selection on macOS 14: SwiftUI only unions a drag selection across *sibling runs joined
// with `+` inside one `Text` value*, never across separate `Text`/view instances in a VStack, and
// it cannot reach into a `CodeBlockView`'s own `ScrollView` at all. That was confirmed by hand
// against this exact layout before writing the type below, which is the AppKit fallback the task
// anticipates. `NSTextView` gives one selection/`copy(_:)` for free across everything it lays out,
// so the fix is to lay the answer's paragraphs/headings/lists/quotes/code out as one attributed
// string in one text view instead of one SwiftUI view per block.
//
// Tables are the one block kind deliberately left out of this shared text view (see
// `MarkdownAnswerPartitioner`) — a real aligned table needs `Grid`, not TextKit line layout, so a
// table still renders as its own `MarkdownTableView` and is its own selection island. Dragging
// through a paragraph, a list, and a code block — the case actually described in the report —
// works as one continuous selection.

/// One contiguous run of an answer's blocks that renders as a single selectable region, or one
/// table that keeps its own `Grid`-based renderer. Splitting only at table boundaries means the
/// common case (prose, lists, quotes, code) is one `NSTextView` and therefore one selection.
enum MarkdownAnswerRun: Identifiable, Equatable {
    case text([MarkdownBlock], position: Int)
    case table(MarkdownBlock, position: Int)

    /// Position is part of the identity on purpose: two runs of identical content (the same
    /// table twice, a repeated paragraph) would otherwise collide in a `ForEach` and render on
    /// top of each other.
    var id: String {
        switch self {
        case let .text(blocks, position): "run:\(position):" + blocks.map(\.id).joined(separator: "|")
        case let .table(block, position): "table:\(position):" + block.id
        }
    }

    var blocks: [MarkdownBlock] {
        switch self {
        case let .text(blocks, _): blocks
        case let .table(block, _): [block]
        }
    }

    static func == (lhs: MarkdownAnswerRun, rhs: MarkdownAnswerRun) -> Bool { lhs.id == rhs.id }
}

enum MarkdownAnswerPartitioner {
    static func runs(from blocks: [MarkdownBlock]) -> [MarkdownAnswerRun] {
        var result: [MarkdownAnswerRun] = []
        var current: [MarkdownBlock] = []
        func flush() {
            guard !current.isEmpty else { return }
            result.append(.text(current, position: result.count))
            current.removeAll(keepingCapacity: true)
        }
        for block in blocks {
            if case .table = block {
                flush()
                result.append(.table(block, position: result.count))
            } else {
                current.append(block)
            }
        }
        flush()
        return result
    }
}

/// A settled assistant answer, laid out so a drag can select continuously from the first
/// paragraph through a list and a code block. Streaming text and every other Markdown use in the
/// app (user bubbles, thinking, narration, tool detail) keep the existing per-block renderer.
struct MarkdownAnswerText: View {
    let text: String
    /// AppKit text views install their own tracking areas, so SwiftUI's `.onHover` never fires
    /// while the pointer is over the answer body. The view reports it instead.
    var onHoverChange: ((Bool) -> Void)?

    var body: some View {
        let runs = MarkdownAnswerPartitioner.runs(from: MarkdownBlockParser.blocks(from: text))
        VStack(alignment: .leading, spacing: PiTheme.transcriptBlockSpacing) {
            ForEach(runs) { run in
                switch run {
                case let .text(blocks, _):
                    SelectableTextRun(blocks: blocks, onHoverChange: onHoverChange)
                case let .table(block, _):
                    if case let .table(header, alignment, rows) = block {
                        MarkdownTableView(header: header, alignment: alignment, rows: rows)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AppKit host

/// Hosts one run and overlays a hover copy button on each code block it reports. Height is not
/// state here: the representable answers `sizeThatFits` directly, so SwiftUI has the real height
/// on the first layout pass instead of growing into it after an async callback.
private struct SelectableTextRun: View {
    let blocks: [MarkdownBlock]
    var onHoverChange: ((Bool) -> Void)?
    @State private var codeBlocks: [AnswerCodeBlockFrame] = []

    var body: some View {
        SelectableTextBlock(
            blocks: blocks,
            onCodeBlocksChange: { codeBlocks = $0 },
            onHoverChange: onHoverChange
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            ForEach(codeBlocks) { frame in
                CodeBlockCopyOverlay(frame: frame)
                    .offset(x: frame.rect.minX, y: frame.rect.minY)
            }
        }
    }
}

/// The bounding rect (in the text view's own coordinate space) of one fenced/indented code block,
/// used purely to float a hover copy button in its corner — the code text itself is part of the
/// surrounding `NSTextView`'s normal selectable flow, not a separate view.
struct AnswerCodeBlockFrame: Identifiable, Equatable {
    let id: String
    let rect: CGRect
    let code: String
}

/// A hover-revealed copy button positioned over one code block's reported rect. This is the same
/// affordance `CodeBlockView` gives fenced code elsewhere; it has to be a separate overlay here
/// because the code itself now lives inside one shared `NSTextView` rather than its own view.
private struct CodeBlockCopyOverlay: View {
    let frame: AnswerCodeBlockFrame
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Color.clear
            .frame(width: max(0, frame.rect.width), height: max(0, frame.rect.height))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                if hovering || copied {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: PiIcon.small, weight: .medium))
                            .foregroundStyle(copied ? Color.piGreen : Color.secondary)
                            .frame(width: 20, height: 18)
                            .piInset(radius: PiTheme.radiusSmall, strong: true)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied" : "Copy code")
                    .accessibilityLabel("Copy code block")
                    .padding(PiTheme.space6)
                }
            }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(frame.code, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// Bridges one contiguous run of blocks into an `NSTextView`. Sizing is the platform's own
/// `sizeThatFits(_:nsView:context:)` (macOS 13+, and this app targets 14): SwiftUI proposes the
/// column width and TextKit answers with the height that text really wraps to, in the same pass.
private struct SelectableTextBlock: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let onCodeBlocksChange: ([AnswerCodeBlockFrame]) -> Void
    var onHoverChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> AnswerTextView {
        let view = AnswerTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.onCodeBlocksChange = onCodeBlocksChange
        view.onHoverChange = onHoverChange
        view.setAccessibilityLabel("Answer")
        applyContent(to: view, context: context)
        return view
    }

    func updateNSView(_ view: AnswerTextView, context: Context) {
        view.onCodeBlocksChange = onCodeBlocksChange
        view.onHoverChange = onHoverChange
        applyContent(to: view, context: context)
    }

    /// Width is deliberately not part of the key: the attributed string does not depend on the
    /// measure, only its layout does, and TextKit rewraps that itself.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerTextView, context: Context) -> CGSize? {
        // Zero is SwiftUI's minimum-size probe, not a usable wrapping width.
        guard proposal.width != 0 else { return nil }
        return nsView.fittingSize(for: proposal.width)
    }

    private func applyContent(to view: AnswerTextView, context: Context) {
        let key = blocks.map(\.id).joined(separator: "|") + "@\(PiFont.size)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        view.apply(AnswerAttributedTextBuilder.build(blocks: blocks))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastKey = ""
    }
}

/// A non-editable `NSTextView` that can be asked for its wrapped height at any width without a
/// layout pass first, and that reports its code blocks' frames so SwiftUI can float copy buttons
/// over them.
final class AnswerTextView: NSTextView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    var onCodeBlocksChange: (([AnswerCodeBlockFrame]) -> Void)?
    private var reportedFrames: [AnswerCodeBlockFrame] = []
    private var codeRanges: [AnswerAttributedTextBuilder.CodeBlockEntry] = []
    private var lastMeasuredWidth = PiTheme.transcriptMaxWidth

    /// Routes drawing through `AnswerLayoutManager` so code/quote/rule blocks get their inline
    /// background without a second nested SwiftUI card (see that type's comment), and owns its
    /// own measure.
    convenience init() {
        self.init(frame: .zero)
        let customLayoutManager = AnswerLayoutManager()
        textContainer?.replaceLayoutManager(customLayoutManager)
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        // The container's width is set explicitly, never tracked from the frame. SwiftUI asks
        // `sizeThatFits` for a height *before* it ever gives this view a width, and a tracking
        // container would answer against a zero frame — one line tall, which is exactly the
        // blank/20pt saved answer this sizing path exists to prevent.
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }

    func apply(_ built: AnswerAttributedTextBuilder.Built) {
        textStorage?.setAttributedString(built.attributedString)
        codeRanges = built.codeBlocks
        reportCodeBlocks()
    }

    /// The height this text wraps to at one column width. Called from `sizeThatFits`, so SwiftUI
    /// learns the real height during the same layout pass rather than after an async callback.
    /// Re-measuring at an unchanged width is a cached `usedRect` read, not a fresh layout.
    func fittingSize(for proposedWidth: CGFloat?) -> CGSize {
        let proposed = proposedWidth.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let current = bounds.width > 1 && bounds.width.isFinite ? bounds.width : nil
        let width = proposed ?? current ?? lastMeasuredWidth
        return CGSize(width: width, height: height(forWidth: width))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 1 }
        let resolvedWidth = width > 0 && width.isFinite ? width : lastMeasuredWidth
        setContainerWidth(resolvedWidth)
        manager.ensureLayout(for: container)
        return max(manager.usedRect(for: container).height.rounded(.up), 1)
    }

    private func setContainerWidth(_ width: CGFloat) {
        lastMeasuredWidth = width
        guard let container = textContainer, abs(container.size.width - width) > 0.5 else { return }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func layout() {
        super.layout()
        reportCodeBlocks()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Nothing tracks the frame for us, so the measure follows it here; a width change also
        // rewraps the text, which moves every code block's reported rect.
        if newSize.width > 0 { setContainerWidth(newSize.width) }
        reportCodeBlocks()
    }

    /// Copy-button geometry is the one thing SwiftUI still cannot know without a layout pass, so
    /// it is published — only on change, and asynchronously, since SwiftUI drops state mutations
    /// made during its own update.
    private func reportCodeBlocks() {
        guard let container = textContainer, let manager = layoutManager else { return }
        guard !codeRanges.isEmpty else {
            publish([])
            return
        }
        manager.ensureLayout(for: container)
        let storageLength = textStorage?.length ?? 0
        let frames: [AnswerCodeBlockFrame] = codeRanges.compactMap { entry in
            guard entry.range.location + entry.range.length <= storageLength else { return nil }
            let glyphRange = manager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return nil }
            let rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
            // The background (and therefore the copy button) always spans the full measure, the
            // same way `CodeBlockView`'s recessed panel fills its row regardless of line length.
            let fullWidth = CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height)
            return AnswerCodeBlockFrame(id: entry.id, rect: fullWidth, code: entry.code)
        }
        publish(frames)
    }

    private func publish(_ frames: [AnswerCodeBlockFrame]) {
        guard frames != reportedFrames else { return }
        reportedFrames = frames
        DispatchQueue.main.async { [weak self] in self?.onCodeBlocksChange?(frames) }
    }
}

// MARK: - Background drawing

/// The block kinds that paint their own background/rule behind the glyphs instead of nesting a
/// SwiftUI card inside the text view (which would just reintroduce the "everything looks like a
/// quote" problem this view exists to avoid).
private enum AnswerBlockKind: String {
    case code, quote, rule
}

private extension NSAttributedString.Key {
    static let piAnswerBlockKind = NSAttributedString.Key("PiAnswerBlockKind")
}

/// Paints a recessed panel behind code, a hairline rule, and a quote's left bar directly into the
/// text view's background pass — the TextKit equivalent of `piInset`/`PiHairline`, so expanded
/// content still reads as code/quote/rule without a second, separately-selectable child view.
private final class AnswerLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let container = textContainers.first else { return }
        let bounded = NSRange(location: 0, length: textStorage.length)
        guard let charRange = glyphsToShow.intersection(NSRange(location: 0, length: numberOfGlyphs)).map({
            characterRange(forGlyphRange: $0, actualGlyphRange: nil)
        })?.intersection(bounded) else { return }

        textStorage.enumerateAttribute(.piAnswerBlockKind, in: charRange, options: []) { value, range, _ in
            guard let raw = value as? String, let kind = AnswerBlockKind(rawValue: raw), range.length > 0 else { return }
            let subGlyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard subGlyphRange.length > 0 else { return }
            let rect = self.boundingRect(forGlyphRange: subGlyphRange, in: container).offsetBy(dx: origin.x, dy: origin.y)
            switch kind {
            case .code:
                let panel = NSRect(x: origin.x, y: rect.minY - 2, width: container.size.width, height: rect.height + 4)
                AnswerColors.codeBackground.setFill()
                NSBezierPath(roundedRect: panel, xRadius: PiTheme.radiusMedium, yRadius: PiTheme.radiusMedium).fill()
            case .quote:
                let bar = NSRect(x: origin.x, y: rect.minY, width: 2, height: rect.height)
                AnswerColors.hairline.setFill()
                bar.fill()
            case .rule:
                let line = NSRect(x: origin.x, y: rect.midY, width: container.size.width, height: 1)
                AnswerColors.hairline.setFill()
                line.fill()
            }
        }
    }
}

/// Mirrors `Theme.swift`'s `Color.piInset`/`Color.piHairline` exactly (same literal values), kept
/// here as `NSColor` because `Color` does not expose the dynamic `NSColor` it wraps and Theme.swift
/// is not a file this change owns. `separatorColor` is the system color `piHairline` wraps, so it
/// carries no drift risk; only the inset panel's literal grays are duplicated.
private enum AnswerColors {
    static let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.145, alpha: 1)
            : NSColor(white: 0.965, alpha: 1)
    }
    static let hairline = NSColor.separatorColor
}

// MARK: - Attributed string construction

/// Builds one `NSAttributedString` for a run of non-table blocks, reusing `MarkdownInline`'s
/// Markdown parsing (so links, autolinks, code spans, and strikethrough match every other inline
/// use in the app) while re-expressing it with concrete `NSFont`s instead of SwiftUI `Font`s,
/// since `Font` has no public way back to an `NSFont` for a real `NSTextView` to draw with.
enum AnswerAttributedTextBuilder {
    struct CodeBlockEntry { let id: String; let code: String; let range: NSRange }
    struct Built { let attributedString: NSAttributedString; let codeBlocks: [CodeBlockEntry] }

    static func build(blocks: [MarkdownBlock]) -> Built {
        let size = PiFont.size
        let result = NSMutableAttributedString()
        var codeBlocks: [CodeBlockEntry] = []

        for block in blocks {
            // The separator stays two real newlines so ⌘C copies paragraphs the way they were
            // written, but it is drawn as a 1pt line plus explicit spacing — otherwise the blank
            // line renders a full body line tall and settled answers breathe differently from
            // every other block of text in the app.
            if result.length > 0 { result.append(blockSeparator()) }
            switch block {
            case let .paragraph(text):
                result.append(inline(text, size: size, color: .labelColor))
            case let .heading(level, text):
                result.append(heading(text, level: level, size: size))
            case let .list(items, ordered, _):
                result.append(list(items, ordered: ordered, size: size))
            case let .quote(text):
                result.append(quote(text, size: size))
            case let .code(_, code):
                // Deterministic, like `MarkdownBlock.id`: a fresh UUID per build handed SwiftUI a
                // new identity for the same code block on every render. Position keeps two
                // identical code blocks in one answer distinct.
                let id = "code:\(codeBlocks.count):\(block.id)"
                let start = result.length
                result.append(codeAttributedString(code, size: size))
                codeBlocks.append(CodeBlockEntry(id: id, code: code, range: NSRange(location: start, length: result.length - start)))
            case .table:
                continue // Tables are partitioned out before reaching this builder.
            case .rule:
                result.append(NSAttributedString(
                    string: " ",
                    attributes: [.font: NSFont.systemFont(ofSize: 1), .piAnswerBlockKind: AnswerBlockKind.rule.rawValue]
                ))
            }
        }
        return Built(attributedString: result, codeBlocks: codeBlocks)
    }

    /// A visually exact `PiTheme.space10` gap that still copies as a blank line.
    private static func blockSeparator() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.paragraphSpacing = PiTheme.transcriptBlockSpacing - 1
        return NSAttributedString(string: "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .paragraphStyle: style
        ])
    }

    /// Plain-text extraction used for tests and as the conceptual model for what a full-answer
    /// ⌘C should read like: block content in order, separated by blank lines.
    static func plainText(blocks: [MarkdownBlock]) -> String {
        build(blocks: blocks).attributedString.string
    }

    // MARK: Block builders

    private static func heading(_ text: String, level: Int, size: CGFloat) -> NSAttributedString {
        let headingSize: CGFloat = switch level {
        case 1: PiFont.heading1Size
        case 2: PiFont.heading2Size
        case 3: PiFont.heading3Size
        default: size
        }
        let base = NSFont.systemFont(ofSize: headingSize, weight: .semibold)
        return inline(text, size: headingSize, color: .labelColor, baseFontOverride: base)
    }

    private static func list(_ items: [MarkdownListItem], ordered: Bool, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            // A uniform indent (not a hanging indent relative to the marker) keeps a lazily
            // continued line's indent correct with zero extra bookkeeping, at the small cost of
            // the marker not visually "hanging" left of wrapped text.
            let indent: CGFloat = PiTheme.space8 + CGFloat(item.depth) * PiTheme.space16
            let style = NSMutableParagraphStyle()
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.lineSpacing = PiFont.bodyLineSpacing
            let markerFont = ordered ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
            let piece = NSMutableAttributedString(string: item.marker + " ", attributes: [
                .font: markerFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style
            ])
            // Lazy continuation lines are logically one line of content; collapsing the source
            // newline to a space lets the uniform paragraph style above apply cleanly.
            let flattened = item.text.replacingOccurrences(of: "\n", with: " ")
            let text = inline(flattened, size: size, color: .labelColor)
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            piece.append(text)
            result.append(piece)
        }
        return result
    }

    private static func quote(_ text: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = PiTheme.space12
        style.firstLineHeadIndent = PiTheme.space12
        style.lineSpacing = PiFont.bodyLineSpacing
        let piece = inline(text, size: size, color: .secondaryLabelColor)
        piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
        piece.addAttribute(.piAnswerBlockKind, value: AnswerBlockKind.quote.rawValue, range: NSRange(location: 0, length: piece.length))
        return piece
    }

    private static func codeAttributedString(_ code: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = PiFont.codeLineSpacing
        style.headIndent = PiTheme.space12
        style.firstLineHeadIndent = PiTheme.space12
        style.paragraphSpacingBefore = PiTheme.space8
        style.paragraphSpacing = PiTheme.space8
        return NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: PiFont.codeSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
            .piAnswerBlockKind: AnswerBlockKind.code.rawValue
        ])
    }

    // MARK: Inline

    /// Re-expresses `MarkdownInline.attributed`'s structural parse (bold/italic/code/link/
    /// strikethrough, plus the autolinked bare URLs it already adds) using concrete `NSFont`
    /// traits instead of its SwiftUI `Font`, which cannot be read back out for AppKit to draw.
    private static func inline(
        _ text: String,
        size: CGFloat,
        color: NSColor,
        baseFontOverride: NSFont? = nil
    ) -> NSMutableAttributedString {
        let parsed = MarkdownInline.attributed(text)
        let result = NSMutableAttributedString()
        let baseFont = baseFontOverride ?? NSFont.systemFont(ofSize: size)
        let codeFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        for run in parsed.runs {
            let substring = String(parsed.characters[run.range])
            guard !substring.isEmpty else { continue }
            let intent = run.inlinePresentationIntent
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if intent?.contains(.code) == true {
                attributes[.font] = codeFont
                attributes[.backgroundColor] = AnswerColors.codeBackground
            } else {
                attributes[.font] = resolvedFont(base: baseFont, intent: intent)
            }
            if intent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.cursor] = NSCursor.pointingHand
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }
        if result.length == 0 { result.append(NSAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: color])) }
        if result.length > 0 {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = PiFont.bodyLineSpacing
            result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private static func resolvedFont(base: NSFont, intent: InlinePresentationIntent?) -> NSFont {
        guard let intent else { return base }
        var traits: NSFontTraitMask = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }
}
