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

    /// The inline questionnaire lives inside an already-indented transcript row, so its two
    /// panes only sit side by side when both still fit; below that `ViewThatFits` stacks them.
    static let questionnaireChoicesMinWidth: CGFloat = 280
    static let questionnairePreviewMinWidth: CGFloat = 220
    static let questionnairePreviewMaxWidth: CGFloat = 380
    static let questionnairePreviewMaxHeight: CGFloat = 320

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

    /// The sidebar grid: one icon column, then the single text origin shared by action rows,
    /// folder headers, and conversation rows, so the list keeps one edge and stays shallow.
    /// There is deliberately no reserved disclosure gutter — folders expand on a click anywhere
    /// in their header row rather than a dedicated chevron slot.
    static let sidebarDisclosureColumn: CGFloat = 12
    static let sidebarIconColumn: CGFloat = 14
    /// Extra leading space per nesting level in the virtual folder tree, applied to both a
    /// folder header and the sessions/subfolders indented one step past it.
    static let sidebarIndentStep: CGFloat = 14
    /// Nesting stops adding indentation (and the tree stops recursing) past this depth — a sane
    /// ceiling so corrupted parent data can never make the sidebar recurse without bound.
    static let sidebarMaxFolderDepth = 24
    static var sidebarIconInset: CGFloat { space8 }
    static var sidebarTextInset: CGFloat { sidebarIconInset + sidebarIconColumn + space6 }

    /// Transcript rhythm. Four steps, and everything in a conversation uses one of them: text
    /// blocks inside a message, rows inside a group, entries in the work log, and the larger
    /// break between turns. Views must not invent a fifth.
    static let transcriptBlockSpacing: CGFloat = 10
    static let transcriptRowSpacing: CGFloat = 6
    static let transcriptEntrySpacing: CGFloat = 12
    static let transcriptTurnSpacing: CGFloat = 24
    static let transcriptScrollEdgeThreshold: CGFloat = 80

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
    /// The daemon retains a bounded run history; the automations page asks for, and shows, at
    /// most this many records per automation.
    static let runHistoryLimit = 50
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
    static let quickSwitchResultLimit = 60

    // Hosted remote pairing sheet.
    static let remoteAccessWidth: CGFloat = 560
    static let remoteAccessHeight: CGFloat = 620
    static let remoteQRCodeSize: CGFloat = 208

    // Menu bar panel.
    static let menuBarWidth: CGFloat = 320
    static let menuBarHeaderHeight: CGFloat = 38
    static let menuBarSessionRowHeight: CGFloat = 38
    static let menuBarEmptyStateHeight: CGFloat = 32
    static let menuBarActionRowHeight: CGFloat = 27
    static let menuBarSessionsIdealHeight: CGFloat = 480
    static let menuBarSessionsMinHeight: CGFloat = 76
    static let menuBarLimitsIdealHeight: CGFloat = 320
    static let menuBarLimitsMinHeight: CGFloat = 120
    static let menuBarScreenMargin: CGFloat = 24
    static let menuBarFallbackScreenHeight: CGFloat = 800

    static var menuBarFixedHeight: CGFloat {
        menuBarHeaderHeight + 3 * hairline + 2 * menuBarActionRowHeight + space2 + 2 * space4
    }
}

// MARK: - Typography

/// One literal SF Pro point size across the product. Hierarchy comes from weight, colour, and
/// spacing—not from shrinking metadata or enlarging titles. Keeping the semantic names makes
/// call sites readable while ensuring the sidebar, transcript, inspector, composer, status bar,
/// dialogs, code, and Markdown all sit on the same baseline scale.
enum PiFont {
    /// Matches AppKit's native menu/control font, so OS-drawn pickers and menus align too.
    static let size: CGFloat = NSFont.systemFontSize

    // Compatibility aliases are intentionally equal. No semantic text role gets a private size.
    static let bodySize: CGFloat = size
    static let metaSize: CGFloat = size
    static let codeSize: CGFloat = size
    static let heading1Size: CGFloat = size
    static let heading2Size: CGFloat = size
    static let heading3Size: CGFloat = size

    static let bodyLineHeight: CGFloat = 1.45
    static var bodyLineSpacing: CGFloat { (bodyLineHeight - 1) * size }
    static var codeLineSpacing: CGFloat { size * 0.4 }

    static let body = Font.system(size: size, weight: .regular)
    static let bodyEmphasis = Font.system(size: size, weight: .medium)
    static let title = Font.system(size: size, weight: .semibold)
    static let displayTitle = Font.system(size: size, weight: .semibold)
    static let sectionTitle = Font.system(size: size, weight: .semibold)
    static let row = Font.system(size: size, weight: .regular)
    static let rowEmphasis = Font.system(size: size, weight: .medium)
    static let caption = Font.system(size: size, weight: .regular)
    static let captionEmphasis = Font.system(size: size, weight: .medium)
    static let micro = Font.system(size: size, weight: .regular)
    static let code = Font.system(size: size, design: .monospaced)
    static let codeSmall = Font.system(size: size, design: .monospaced)
    static let heading1 = Font.system(size: size, weight: .semibold)
    static let heading2 = Font.system(size: size, weight: .semibold)
    static let heading3 = Font.system(size: size, weight: .semibold)
    static let heading4 = Font.system(size: size, weight: .semibold)

    // AppKit equivalents for the native composer and answer text views.
    static let composerNSFont = NSFont.systemFont(ofSize: size, weight: .regular)
    static let codeNSFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

/// Symbols are the other half of the type scale, and they were the half nobody governed: views
/// picked 8, 9, 10, 10.5, 11, 12 and 13pt glyphs by hand, which is what made the app look like
/// several apps. Every `Image(systemName:)` in the UI uses one of these four sizes.
enum PiIcon {
    /// Chevrons and inline hints that sit inside a line of caption text.
    static let micro: CGFloat = 9
    /// The default: row icons in the sidebar, inspector, and transcript.
    static let small: CGFloat = 11
    /// Toolbar and composer controls.
    static let medium: CGFloat = 12
    /// Empty states and anything meant to be looked at rather than scanned past.
    static let large: CGFloat = 13

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
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
    static let piBlue = Color(nsColor: .systemBlue)
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

    /// A toolbar without macOS 26's shared glass capsule.
    @ViewBuilder
    func piPlainToolbar<C: ToolbarContent>(@ToolbarContentBuilder content: () -> C) -> some View {
        if #available(macOS 26.0, *) {
            toolbar { content().sharedBackgroundVisibility(.hidden) }
        } else {
            toolbar(content: content)
        }
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
                .font(.system(size: PiIcon.small, weight: symbolWeight))
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
            .font(.system(size: PiIcon.micro, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeOut(duration: 0.12), value: expanded)
    }
}

/// A one-size replacement for `ContentUnavailableView`, whose private title/description scale
/// ignores the surrounding SwiftUI font environment.
struct PiUnavailableView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String?
    private let actions: Actions

    init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: PiTheme.space8) {
            Image(systemName: systemImage)
                .font(.system(size: PiIcon.large, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(PiFont.bodyEmphasis)
            if let description, !description.isEmpty {
                Text(description)
                    .font(PiFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions
                .font(PiFont.body)
        }
        .padding(PiTheme.space16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PiUnavailableView where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

struct StatusDot: View {
    let color: Color
    /// Off by default: only a dot that means "work is happening right now" breathes.
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private var animates: Bool { pulsing && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(phase ? 0.3 : 1)
            .animation(animates ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: phase)
            // Phase follows `animates` rather than being set once: a recycled row that turns
            // from a static dot into a pulsing one (or back, or when Reduce Motion flips) still
            // gets the transition the repeating animation needs to start.
            .onAppear { phase = animates }
            .onChange(of: animates) { _, on in phase = on }
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

// MARK: - Context budget

/// Whether the context meter reads as over budget. Anything at or under 100% is the normal
/// run-up the compaction UI already handles; past 100% the window is provably showing the model
/// less than it needs, which is the one state worth alarming red for — in the inspector only,
/// since the footer bar no longer carries cost or context at all.
enum ContextBudget {
    static func isOverBudget(_ percent: Double?) -> Bool {
        guard let percent else { return false }
        return percent > 100
    }
}

// MARK: - Effort ramp

/// The `/mode` ladder reads as an intensity dial, not a flat list of names: colour warms from a
/// calm teal at `xfast` to a hot pink at `ultra`, so the composer's effort control communicates
/// "how hard is this about to work" before anyone reads the label. Ordered by both hue and
/// value/temperature so the ramp still reads correctly for colour-blind users.
extension PiTheme {
    static let effortRamp: [Color] = [
        Color(nsColor: .systemTeal),   // xfast — calm
        Color(nsColor: .systemBlue),   // fast
        Color(nsColor: .systemOrange), // smart
        Color(nsColor: .systemPink)    // ultra — intense
    ]
    /// The far end of `ultra`'s glow: pushes past the ramp's pink into red so the strongest mode
    /// gets a genuinely distinctive treatment instead of just another flat colour stop.
    static let effortUltraAccent = Color(nsColor: .systemRed)

    static let effortTrackHeight: CGFloat = 5
    static let effortTrackWidth: CGFloat = 84
    static let effortKnobDiameter: CGFloat = 14
    static let effortUltraKnobDiameter: CGFloat = 17
}

extension PiMode {
    /// The ramp stop for this mode. `ComposerView.swift` can apply this directly (e.g. via
    /// `.tint`) even without adopting the full `PiEffortTrack` view.
    var piTint: Color {
        PiTheme.effortRamp[Self.allCases.firstIndex(of: self) ?? 0]
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

    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
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
