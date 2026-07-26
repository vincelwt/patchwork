import AppKit
import SwiftUI

// MARK: - Metrics

/// The single source of truth for spacing, sizing, and layout. Views must not invent
/// one-off paddings; every value used in the UI is named here.
enum PiTheme {
    // Spacing scale (4pt base with two half steps for dense controls).
    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space6: CGFloat = 6
    static let space8: CGFloat = 8
    static let space10: CGFloat = 10
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    // Columns
    static let sidebarIdealWidth: CGFloat = 268
    static let sidebarMinWidth: CGFloat = 232
    static let sidebarMaxWidth: CGFloat = 340
    static let windowMinimumWidth: CGFloat = 700
    static let windowMinimumHeight: CGFloat = 520
    static let sidebarAutoCollapseWidth: CGFloat = 860
    static let transcriptMaxWidth: CGFloat = 780
    static let composerMaxWidth: CGFloat = 780
    static let inspectorWidth: CGFloat = 272
    /// Gutter reserved around the inspector panel inside its own column.
    static let inspectorGutter: CGFloat = 0
    /// The transcript/composer column must keep at least this much room, otherwise the
    /// inspector column is not reserved at all.
    static let conversationMinimumWidth: CGFloat = 560

    // Rows
    static let rowHeight: CGFloat = 28
    static let sidebarRowHeight: CGFloat = 27
    static let folderHeaderHeight: CGFloat = 24
    static let statusBarHeight: CGFloat = 26
    static let inspectorRowHeight: CGFloat = 22

    /// The shared transcript grid. Every icon-bearing row centers its symbol in a column of
    /// `gridIconColumn` and starts its text at `gridTextInset`, so tool calls, results,
    /// thinking, custom, and system rows line up with each other exactly.
    static let gridIconColumn: CGFloat = 17
    static let gridGutter: CGFloat = 7
    static var gridTextInset: CGFloat { gridIconColumn + gridGutter }

    /// The sidebar grid. A disclosure gutter that only folders use, then one icon column, then
    /// the single text origin shared by action rows, folder headers, and conversation rows, so
    /// the list keeps one edge and stays shallow.
    static let sidebarDisclosureColumn: CGFloat = 12
    static let sidebarIconColumn: CGFloat = 14
    static var sidebarIconInset: CGFloat { space8 + sidebarDisclosureColumn + space6 }
    static var sidebarTextInset: CGFloat { sidebarIconInset + sidebarIconColumn + space6 }

    /// Transcript rhythm: the gap between entries inside one turn, and the larger gap that
    /// separates one turn from the next.
    static let transcriptEntrySpacing: CGFloat = 10
    static let transcriptTurnSpacing: CGFloat = 22

    // Radii — one small, one medium, one for the composer. No other values.
    static let radiusSmall: CGFloat = 5
    static let radiusMedium: CGFloat = 8
    static let userBubbleRadius: CGFloat = 14
    static let composerRadius: CGFloat = 12
    static let panelRadius: CGFloat = 10

    static let hairline: CGFloat = 1

    // Budgets and bounds (unchanged policy).
    static let imageCountLimit = 8
    static let imageByteLimit = 16 * 1_024 * 1_024
    static let totalImageByteLimit = 64 * 1_024 * 1_024
    static let unknownPayloadLimit = 8_000
    static let sessionPreviewLimit = 512
    /// Aggregate decoded-bitmap cache ceiling (decoded pixel cost, not encoded bytes).
    static let decodedImageCountLimit = 64
    static let decodedImageByteLimit = 64 * 1_024 * 1_024
    /// Git list starts collapsed and stays bounded even when expanded.
    static let gitFilePreviewCount = 12
    static let gitFileHardLimit = 400

    /// The composer editor grows with its content between these bounds.
    static let composerMinEditorHeight: CGFloat = 30
    static let composerMaxEditorHeight: CGFloat = 240

    /// Inline composer attachment preview size.
    static let inlineAttachmentHeight: CGFloat = 48
    static let inlineAttachmentMaxWidth: CGFloat = 96

    /// Conversation image preview ceiling.
    static let transcriptImageMaxWidth: CGFloat = 460
    static let transcriptImageMaxHeight: CGFloat = 300

    /// Quick switcher.
    static let quickSwitchWidth: CGFloat = 560
    static let quickSwitchRowHeight: CGFloat = 34
    static let menuBarWidth: CGFloat = 320
    static let quickSwitchResultLimit = 60
}

// MARK: - Typography

/// A deliberate SF Pro (non-rounded) scale. Semibold is reserved for real titles.
enum PiFont {
    /// Transcript body: 14.5pt with a 1.45 line height (≈6.5pt extra leading).
    static let bodySize: CGFloat = 14.5
    static let bodyLineHeight: CGFloat = 1.45
    static var bodyLineSpacing: CGFloat { (bodyLineHeight - 1) * bodySize }

    static let body = Font.system(size: bodySize, weight: .regular)
    static let bodyEmphasis = Font.system(size: bodySize, weight: .medium)

    /// Section and window titles.
    static let title = Font.system(size: 15, weight: .semibold)
    static let sectionTitle = Font.system(size: 12, weight: .semibold)

    /// Sidebar and inspector rows.
    static let row = Font.system(size: 13, weight: .regular)
    static let rowEmphasis = Font.system(size: 13, weight: .medium)

    /// Captions, metadata, footers.
    static let caption = Font.system(size: 11.5, weight: .regular)
    static let captionEmphasis = Font.system(size: 11.5, weight: .medium)
    static let micro = Font.system(size: 10.5, weight: .regular)

    /// SF Mono for code and tool output.
    static let code = Font.system(size: 12, design: .monospaced)
    static let codeSmall = Font.system(size: 11, design: .monospaced)

    static var codeLineSpacing: CGFloat { 12 * 0.4 }

    // Markdown heading ramp, anchored on the body size.
    static let heading1 = Font.system(size: 19, weight: .semibold)
    static let heading2 = Font.system(size: 17, weight: .semibold)
    static let heading3 = Font.system(size: 15, weight: .semibold)
    static let heading4 = Font.system(size: bodySize, weight: .semibold)

    // AppKit equivalents for the native composer text view.
    static let composerNSFont = NSFont.systemFont(ofSize: bodySize, weight: .regular)
    static let codeNSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

// MARK: - Surfaces

extension Color {
    /// Appearance-aware neutral, so light stays near-white and dark stays true dark instead of
    /// both collapsing into the same translucent gray.
    static func piDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// The transcript reading surface: near-white in light, true dark in dark.
    static let piTranscript = Color(nsColor: .textBackgroundColor)
    /// Window chrome behind panels.
    static let piWindow = Color(nsColor: .windowBackgroundColor)
    /// Hairline separators.
    static let piHairline = Color(nsColor: .separatorColor)

    /// Recessed neutral used for code, tool output, and inset detail. Never tinted.
    static let piInset = piDynamic(
        light: NSColor(white: 0.965, alpha: 1),
        dark: NSColor(white: 0.145, alpha: 1)
    )
    /// A slightly stronger inset for nested surfaces (used at most one level deep).
    static let piInsetStrong = piDynamic(
        light: NSColor(white: 0.935, alpha: 1),
        dark: NSColor(white: 0.185, alpha: 1)
    )
    /// The user message bubble: neutral, not accent-tinted.
    static let piUserBubble = piDynamic(
        light: NSColor(white: 0.945, alpha: 1),
        dark: NSColor(white: 0.19, alpha: 1)
    )

    /// Neutral hover and selection for rows.
    static let piHover = piDynamic(
        light: NSColor(white: 0, alpha: 0.045),
        dark: NSColor(white: 1, alpha: 0.055)
    )
    static let piSelection = piDynamic(
        light: NSColor(white: 0, alpha: 0.075),
        dark: NSColor(white: 1, alpha: 0.10)
    )
    static let piPressed = piDynamic(
        light: NSColor(white: 0, alpha: 0.10),
        dark: NSColor(white: 1, alpha: 0.14)
    )

    // Semantic accents, used sparingly.
    static let piGreen = Color(nsColor: .systemGreen)
    static let piRed = Color(nsColor: .systemRed)
    static let piOrange = Color(nsColor: .systemOrange)
    static let piPurple = Color(nsColor: .systemPurple)
}

// MARK: - Shared building blocks

/// A hairline separator from `separatorColor`, never a translucent gray band.
struct PiHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.piHairline)
            .frame(height: PiTheme.hairline)
    }
}

/// A single recessed surface with no border and no shadow, so nothing ever doubles up.
struct PiInsetModifier: ViewModifier {
    var radius: CGFloat = PiTheme.radiusMedium
    var strong = false

    func body(content: Content) -> some View {
        content.background(
            strong ? Color.piInsetStrong : Color.piInset,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }
}

extension View {
    func piInset(radius: CGFloat = PiTheme.radiusMedium, strong: Bool = false) -> some View {
        modifier(PiInsetModifier(radius: radius, strong: strong))
    }

    /// Restrained neutral hover/selection background used by every row in the app.
    func piRowBackground(selected: Bool, hovering: Bool, radius: CGFloat = PiTheme.radiusSmall) -> some View {
        background(
            selected ? Color.piSelection : (hovering ? Color.piHover : Color.clear),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }
}

/// One shared transcript grid row: symbol centered in the icon column, content starting at the
/// single text origin. Used by tool calls, results, thinking, custom, and system rows.
struct PiGridRow<Content: View>: View {
    let symbol: String
    var tint: Color = .secondary
    var symbolWeight: Font.Weight = .regular
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PiTheme.gridGutter) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: symbolWeight))
                .foregroundStyle(tint)
                .frame(width: PiTheme.gridIconColumn, alignment: .center)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A grid row that shows a spinner instead of a symbol while work is in flight.
struct PiGridProgressRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PiTheme.gridGutter) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: PiTheme.gridIconColumn, alignment: .center)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A borderless disclosure chevron with a consistent size and quiet tint.
struct PiChevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeOut(duration: 0.12), value: expanded)
    }
}

struct StatusDot: View {
    let color: Color
    var isPulsing = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(isPulsing && pulse ? 1.2 : 1)
            .opacity(isPulsing && pulse ? 0.55 : 1)
            .animation(
                isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

/// A quiet section header used by the inspector: uppercase, tertiary, no card.
struct PiSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: PiTheme.space6) {
            Text(title.uppercased())
                .font(PiFont.micro.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            Spacer(minLength: PiTheme.space4)
            if let trailing {
                Text(trailing)
                    .font(PiFont.micro.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Layout policy

/// Pure layout policy for the conversation detail area so the inspector can be a real
/// reserved trailing column instead of an overlay.
enum ConversationLayout {
    /// Width the inspector column occupies, including its gutter.
    static var inspectorColumnWidth: CGFloat { PiTheme.inspectorWidth + PiTheme.inspectorGutter }

    /// The inspector is only shown when the conversation column keeps a usable width.
    static func showsInspector(requested: Bool, totalWidth: CGFloat) -> Bool {
        guard requested else { return false }
        return totalWidth - inspectorColumnWidth >= PiTheme.conversationMinimumWidth
    }
}

// MARK: - Formatting

enum NumberFormatting {
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    static func cost(_ value: Double) -> String {
        value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    /// `4m 1s` style duration for turn headers. Seconds are dropped past an hour, where they
    /// stop carrying information.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        let hours = total / 3_600
        return "\(hours)h \((total % 3_600) / 60)m"
    }

    /// Compact elapsed/duration label for the menu bar and activity rows.
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

extension Date {
    var relativeShort: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
