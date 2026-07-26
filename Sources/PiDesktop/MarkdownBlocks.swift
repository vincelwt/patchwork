import AppKit
import SwiftUI

// MARK: - Model

/// A block-level Markdown element. `AttributedString(markdown:)` alone collapses every
/// paragraph into a single run, which is why multi-paragraph replies used to render as
/// "KeychainUpdated meta to load it automaticallyDeleted the Bitwarden item". Splitting into
/// blocks first and parsing only inline spans per block fixes that.
enum MarkdownBlock: Equatable, Identifiable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [MarkdownListItem], ordered: Bool, start: Int)
    case quote(String)
    case code(language: String?, code: String)
    case rule

    var id: String {
        switch self {
        case let .paragraph(text): "p:\(text.hashValue)"
        case let .heading(level, text): "h\(level):\(text.hashValue)"
        case let .list(items, ordered, start): "l\(ordered ? "o" : "u")\(start):\(items.hashValue)"
        case let .quote(text): "q:\(text.hashValue)"
        case let .code(language, code): "c\(language ?? "-"):\(code.hashValue)"
        case .rule: "hr:\(UUID().uuidString)"
        }
    }
}

struct MarkdownListItem: Equatable, Hashable, Sendable {
    let marker: String
    let text: String
    /// Nesting depth derived from leading indentation (0 for a top-level item).
    let depth: Int
}

// MARK: - Block parser

enum MarkdownBlockParser {
    private static let fenceCharacters: Set<Character> = ["`", "~"]

    /// Splits source Markdown into blocks. Blank lines separate blocks; newlines inside a
    /// paragraph are preserved so hard breaks survive to the renderer.
    static func blocks(from source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line: paragraph boundary.
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code.
            if let fence = fenceInfo(trimmed), leadingSpaces(line) < 4 {
                flushParagraph()
                var body: [String] = []
                index += 1
                var closed = false
                while index < lines.count {
                    let candidate = lines[index]
                    if isClosingFence(candidate, fence: fence) {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(candidate)
                    index += 1
                }
                _ = closed
                blocks.append(.code(language: fence.language, code: body.joined(separator: "\n")))
                continue
            }

            // Thematic break.
            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // ATX heading.
            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            // Blockquote: consecutive `>` lines become one quote block.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var stripped = String(candidate.dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    quoted.append(stripped)
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Lists: consecutive items, with indented continuation lines folded into the item.
            if listMarker(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                var ordered = false
                var start = 1
                var first = true
                while index < lines.count {
                    let candidate = lines[index]
                    if let marker = listMarker(candidate) {
                        if first {
                            ordered = marker.ordered
                            start = marker.number ?? 1
                            first = false
                        } else if marker.ordered != ordered {
                            break
                        }
                        items.append(MarkdownListItem(
                            marker: marker.display,
                            text: marker.content,
                            depth: min(3, marker.indent / 2)
                        ))
                        index += 1
                        continue
                    }
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    // A lazy continuation line belongs to the previous item.
                    if !candidateTrimmed.isEmpty, leadingSpaces(candidate) >= 2, !items.isEmpty,
                       fenceInfo(candidateTrimmed) == nil {
                        let last = items.removeLast()
                        items.append(MarkdownListItem(
                            marker: last.marker,
                            text: last.text + "\n" + candidateTrimmed,
                            depth: last.depth
                        ))
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append(.list(items: items, ordered: ordered, start: start))
                continue
            }

            // Indented code, only when it opens a block (never mid-paragraph).
            if paragraph.isEmpty, leadingSpaces(line) >= 4 || line.hasPrefix("\t") {
                flushParagraph()
                var body: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line inside indented code is kept only when code follows.
                        let next = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        guard let next, leadingSpaces(next) >= 4 || next.hasPrefix("\t") else { break }
                        body.append("")
                        index += 1
                        continue
                    }
                    guard leadingSpaces(candidate) >= 4 || candidate.hasPrefix("\t") else { break }
                    body.append(dedent(candidate))
                    index += 1
                }
                blocks.append(.code(language: nil, code: body.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: Line classification helpers

    private struct Fence: Equatable {
        let character: Character
        let length: Int
        let language: String?
    }

    private static func fenceInfo(_ trimmed: String) -> Fence? {
        guard let first = trimmed.first, fenceCharacters.contains(first) else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not contain backticks.
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(character: first, length: run.count, language: language?.isEmpty == false ? language : nil)
    }

    private static func isClosingFence(_ line: String, fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == fence.character else { return false }
        let run = trimmed.prefix { $0 == fence.character }
        guard run.count >= fence.length else { return false }
        return trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        let stripped = trimmed.filter { !$0.isWhitespace }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    private static func headingInfo(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Drop an optional closing sequence of hashes.
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes.count, text.trimmingCharacters(in: .whitespaces))
    }

    private struct ListMarker {
        let ordered: Bool
        let number: Int?
        let display: String
        let content: String
        let indent: Int
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        guard indent < 8 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let rest = trimmed.dropFirst()
            guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
            if isThematicBreak(trimmed) { return nil }
            var content = String(rest).trimmingCharacters(in: .whitespaces)
            var display = "•"
            // GitHub task list items keep their checkbox as the marker.
            if content.hasPrefix("[ ] ") || content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                display = content.hasPrefix("[ ] ") ? "☐" : "☑"
                content = String(content.dropFirst(4))
            }
            return ListMarker(ordered: false, number: nil, display: display, content: content, indent: indent)
        }

        guard first.isNumber else { return nil }
        let digits = trimmed.prefix { $0.isNumber }
        guard digits.count <= 9 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        let number = Int(digits) ?? 1
        return ListMarker(
            ordered: true,
            number: number,
            display: "\(number).",
            content: String(rest).trimmingCharacters(in: .whitespaces),
            indent: indent
        )
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private static func dedent(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        var value = line
        var removed = 0
        while removed < 4, value.hasPrefix(" ") {
            value.removeFirst()
            removed += 1
        }
        return value
    }
}

// MARK: - Inline parsing

enum MarkdownInline {
    /// Parses inline spans only, preserving the block's own whitespace and newlines. Code spans
    /// are restyled to SF Mono with a recessed background; links stay clickable.
    static func attributed(_ text: String, size: CGFloat = PiFont.bodySize) -> AttributedString {
        var result: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            result = parsed
        } else {
            result = AttributedString(text)
        }
        result.font = .system(size: size)
        styleCodeSpans(in: &result, size: size)
        return result
    }

    /// Plain fallback used while a message is still streaming (no per-token reparse).
    static func plain(_ text: String, size: CGFloat = PiFont.bodySize) -> AttributedString {
        var value = AttributedString(text)
        value.font = .system(size: size)
        return value
    }

    private static func styleCodeSpans(in string: inout AttributedString, size: CGFloat) {
        for run in string.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            string[run.range].font = .system(size: max(11, size - 1.5), design: .monospaced)
            string[run.range].backgroundColor = .piInset
        }
    }
}

// MARK: - Renderer

struct MarkdownBlockView: View {
    let text: String
    /// Growing streaming text renders as plain preserved-whitespace text; block Markdown is
    /// parsed once the message is final so every token does not re-parse the whole body.
    var streaming = false
    var size: CGFloat = PiFont.bodySize
    /// User bubbles shrink-wrap their content; the transcript column fills its width.
    var fillWidth = true

    var body: some View {
        if streaming {
            Text(MarkdownInline.plain(text, size: size))
                .lineSpacing(PiFont.bodyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: PiTheme.space10) {
                ForEach(Array(MarkdownBlockParser.blocks(from: text).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockRow(block: block, size: size, fillWidth: fillWidth)
                }
            }
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
        }
    }
}

private struct MarkdownBlockRow: View {
    let block: MarkdownBlock
    let size: CGFloat
    var fillWidth = true

    var body: some View {
        switch block {
        case let .paragraph(text):
            inline(text)
        case let .heading(level, text):
            Text(MarkdownInline.attributed(text, size: size))
                .font(headingFont(level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PiTheme.space4)
        case let .list(items, ordered, _):
            VStack(alignment: .leading, spacing: PiTheme.space4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: PiTheme.space6) {
                        Text(item.marker)
                            .font(ordered ? .system(size: size).monospacedDigit() : .system(size: size))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                        inline(item.text)
                    }
                    .padding(.leading, CGFloat(item.depth) * PiTheme.space16)
                }
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: PiTheme.space10) {
                Rectangle()
                    .fill(Color.piHairline)
                    .frame(width: 2)
                inline(text)
                    .foregroundStyle(.secondary)
            }
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case .rule:
            PiHairline().padding(.vertical, PiTheme.space4)
        }
    }

    private func inline(_ text: String) -> some View {
        Text(MarkdownInline.attributed(text, size: size))
            .lineSpacing(PiFont.bodyLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: PiFont.heading1
        case 2: PiFont.heading2
        case 3: PiFont.heading3
        default: PiFont.heading4
        }
    }
}

/// Fenced/indented code on a recessed surface, horizontally scrollable, with a copy button that
/// appears on hover so it never competes with the code itself.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(PiFont.code)
                    .lineSpacing(PiFont.codeLineSpacing)
                    .textSelection(.enabled)
                    .padding(.horizontal, PiTheme.space12)
                    .padding(.vertical, PiTheme.space10)
                    .frame(minWidth: 0, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: PiTheme.space6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(PiFont.micro)
                        .foregroundStyle(.tertiary)
                }
                if hovering || copied {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copied ? Color.piGreen : Color.secondary)
                            .frame(width: 20, height: 18)
                            .piInset(radius: PiTheme.radiusSmall, strong: true)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied" : "Copy code")
                    .accessibilityLabel("Copy code block")
                }
            }
            .padding(PiTheme.space6)
        }
        .piInset()
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}
