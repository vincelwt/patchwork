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
    case table(header: [String], alignment: [MarkdownTableAlignment], rows: [[String]])
    case rule

    var id: String {
        switch self {
        case let .paragraph(text): "p:\(text.hashValue)"
        case let .heading(level, text): "h\(level):\(text.hashValue)"
        case let .list(items, ordered, start): "l\(ordered ? "o" : "u")\(start):\(items.hashValue)"
        case let .quote(text): "q:\(text.hashValue)"
        case let .code(language, code): "c\(language ?? "-"):\(code.hashValue)"
        case let .table(header, _, rows): "t:\(header.hashValue):\(rows.count):\(rows.hashValue)"
        // Deterministic: a fresh UUID here handed SwiftUI a brand-new identity on every single
        // render, which recycled views mid-layout and left stale text painted over new content.
        // Uniqueness within a list comes from the position callers pair with this id.
        case .rule: "hr"
        }
    }
}

/// Column alignment from a table's delimiter row (`:---`, `:---:`, `---:`, or plain `---`).
enum MarkdownTableAlignment: Equatable, Sendable {
    case none, leading, center, trailing
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
            // A lone trailing backslash is CommonMark's hard-break marker: the newline it sits
            // on already renders as a visible break in this renderer (every embedded newline
            // does, by design - see the type comment), so the marker itself must be consumed
            // instead of showing up as a stray literal "\" before the break.
            let text = paragraph.map(stripTrailingHardBreakMarker).joined(separator: "\n")
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

            // Setext heading: an in-progress paragraph line immediately underlined by a run of
            // `=` (H1) or `-` (H2). This must be checked before the thematic-break case below,
            // since a bare `---` right after text closes a heading, not a rule - and before the
            // table case, since a bare `---` never looks like a table delimiter row anyway.
            if !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = paragraph.map(stripTrailingHardBreakMarker).joined(separator: "\n")
                paragraph.removeAll(keepingCapacity: true)
                blocks.append(.heading(level: level, text: text))
                index += 1
                continue
            }

            // GFM pipe table: a header row immediately followed by a validating delimiter row
            // (`|---|:---:|---:|`). Both must contain a pipe, so this can never misfire on a
            // setext underline or an ordinary paragraph line.
            if let header = splitTableRow(trimmed), index + 1 < lines.count,
               let alignments = tableDelimiterAlignment(lines[index + 1], columns: header.count) {
                flushParagraph()
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidateTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidateTrimmed.isEmpty, let cells = splitTableRow(candidateTrimmed) else { break }
                    rows.append(normalizeRow(cells, to: header.count))
                    index += 1
                }
                blocks.append(.table(header: normalizeRow(header, to: header.count), alignment: alignments, rows: rows))
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
                var baseIndent = 0
                while index < lines.count {
                    let candidate = lines[index]
                    if let marker = listMarker(candidate) {
                        if first {
                            ordered = marker.ordered
                            start = marker.number ?? 1
                            baseIndent = marker.indent
                            first = false
                        } else if marker.ordered != ordered, marker.indent <= baseIndent {
                            // A different marker type back at (or above) the list's own indent is
                            // a sibling list of the other kind, not a nested continuation of this
                            // one. A deeper-indented marker of the other kind (e.g. a bullet
                            // nested under an ordered item) still folds in below instead of
                            // splitting the list in two.
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

    /// A setext underline is a run of only `=` (H1) or only `-` (H2); the caller only consults
    /// this while a paragraph is in progress, so a document-initial `---`/`===` never matches.
    private static func setextLevel(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Drops one lone trailing backslash (CommonMark's explicit hard-break marker). A trailing
    /// pair (`\\`) is an escaped backslash meant to stay visible, not a break marker, so only an
    /// odd run is stripped, and only its final character.
    private static func stripTrailingHardBreakMarker(_ line: String) -> String {
        guard line.hasSuffix("\\") else { return line }
        let trailingBackslashes = line.reversed().prefix { $0 == "\\" }.count
        guard trailingBackslashes % 2 == 1 else { return line }
        return String(line.dropLast())
    }

    /// Splits one table row on unescaped, non-code-span pipes. A single optional leading and
    /// trailing pipe (the usual `| a | b |` framing) is stripped first so a genuinely empty edge
    /// cell (`| a | |`) is never confused with the optional outer framing. Returns `nil` for a
    /// line that cannot be a table row at all (no pipe outside a code span).
    private static func splitTableRow(_ trimmed: String) -> [String]? {
        guard trimmed.contains("|") else { return nil }
        var body = Substring(trimmed)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        guard !body.isEmpty else { return nil }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var chars = Substring(body)[...]
        while let ch = chars.first {
            if ch == "\\", chars.count >= 2 {
                current.append(ch)
                current.append(chars[chars.index(after: chars.startIndex)])
                chars = chars.dropFirst(2)
                continue
            }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                chars = chars.dropFirst()
                continue
            }
            current.append(ch)
            chars = chars.dropFirst()
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Validates a delimiter row (`---`, `:---`, `---:`, `:---:` per cell) and reports each
    /// column's alignment. `nil` means "not a table": either the cell count does not match the
    /// header, or some cell is not a pure dash run.
    private static func tableDelimiterAlignment(_ line: String, columns: Int) -> [MarkdownTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let cells = splitTableRow(trimmed), cells.count == columns else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : left ? .leading : .none)
        }
        return alignments
    }

    /// Ragged body rows are padded or truncated to the header's column count, per GFM.
    private static func normalizeRow(_ cells: [String], to columns: Int) -> [String] {
        if cells.count == columns { return cells }
        if cells.count > columns { return Array(cells.prefix(columns)) }
        return cells + Array(repeating: "", count: columns - cells.count)
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
        linkifyBareURLs(in: &result)
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

    /// Apple's Markdown parser links `[text](url)` and `<url>` but not a bare "https://…" typed
    /// straight into prose, which is how Pi and users both write URLs most of the time. This
    /// finds `http(s)://` runs Apple's parser left as plain text (never inside an existing link
    /// or a code span) and turns them into real links using the same `.link` attribute, so they
    /// render with the identical styling `Text` already gives markdown-authored links.
    private static func linkifyBareURLs(in string: inout AttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let plain = String(string.characters)
        guard !plain.isEmpty else { return }
        let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let stringRange = Range(match.range, in: plain) else { continue }
            guard let lower = AttributedString.Index(stringRange.lowerBound, within: string),
                  let upper = AttributedString.Index(stringRange.upperBound, within: string) else { continue }
            let range = lower..<upper
            // Never override a real markdown link or relabel a code span as a link.
            guard string[range].link == nil,
                  string[range].runs.allSatisfy({ $0.inlinePresentationIntent?.contains(.code) != true }) else { continue }
            string[range].link = url
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
            VStack(alignment: .leading, spacing: PiTheme.transcriptBlockSpacing) {
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
        case let .table(header, alignment, rows):
            MarkdownTableView(header: header, alignment: alignment, rows: rows, size: size)
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

/// A GFM pipe table rendered as a real native table: a quiet (secondary, medium-weight, not
/// heavy/bold) header, one hairline under it, per-column alignment, and no per-cell borders —
/// row rhythm comes from spacing, not ruled lines, so it reads like part of this UI rather than
/// an imported HTML table. Wrapped in a horizontal `ScrollView` so a wide table scrolls instead
/// of compressing its columns or blowing out the fixed transcript width.
struct MarkdownTableView: View {
    let header: [String]
    let alignment: [MarkdownTableAlignment]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: PiTheme.space16, verticalSpacing: PiTheme.space6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        cellText(cell, column: index, emphasis: true)
                    }
                }
                Divider()
                    .gridCellColumns(max(1, header.count))
                    .overlay(Color.piHairline)
                ForEach(Array(normalizedRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellText(cell, column: index, emphasis: false)
                        }
                    }
                }
            }
            .padding(.trailing, PiTheme.space4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(header.count) columns, \(rows.count) rows")
    }

    /// Defensive against ragged rows even if a caller builds `.table` directly (the parser
    /// already normalizes), since `Grid` expects one cell per column in every `GridRow`.
    private var normalizedRows: [[String]] {
        rows.map { row -> [String] in
            if row.count == header.count { return row }
            if row.count > header.count { return Array(row.prefix(header.count)) }
            return row + Array(repeating: "", count: header.count - row.count)
        }
    }

    private func cellText(_ text: String, column: Int, emphasis: Bool) -> some View {
        Text(MarkdownInline.attributed(text, size: size))
            .font(emphasis ? PiFont.bodyEmphasis : .system(size: size))
            .foregroundStyle(emphasis ? .secondary : .primary)
            .lineSpacing(PiFont.bodyLineSpacing)
            .multilineTextAlignment(textAlignment(column))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .gridColumnAlignment(horizontalAlignment(column))
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignment[safe: column] ?? .none {
        case .center: .center
        case .trailing: .trailing
        case .leading, .none: .leading
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment[safe: column] ?? .none {
        case .center: .center
        case .trailing: .trailing
        case .leading, .none: .leading
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
