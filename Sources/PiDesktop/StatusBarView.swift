import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var store: AppStore

    private var metrics: TokenMetrics { store.selectedMetrics }
    private var statuses: ExtensionStatusModel { store.statusModel }

    var body: some View {
        HStack(spacing: PiTheme.space10) {
            RuntimeStateLabel()

            // Token counts live in the hover detail; the bar itself carries the number that
            // actually matters at a glance.
            CostLabel(metrics: metrics)

            if let percent = metrics.contextPercent {
                HStack(spacing: PiTheme.space4) {
                    ProgressView(value: min(100, max(0, percent)), total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 44)
                    Text("\(Int(percent))%")
                        .font(PiFont.micro.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context window usage")
                .accessibilityValue("\(Int(percent)) percent")
                .help("Context window usage")
            }

            Spacer(minLength: PiTheme.space8)

            // Pi TUI footer parity, driven entirely by verified extension status keys.
            if let account = statuses.codexAccount {
                CodexAccountControl(account: account, isLive: statuses.isLive)
                StatusSeparator()
            }
            if let fast = statuses.fastPriority {
                FastPriorityControl(status: fast, isLive: statuses.isLive)
            }
            GenericStatusChips(chips: statuses.genericChips, isLive: statuses.isLive)

            StatusSeparator()

            if store.runtimeState.queueCount > 0, store.isSelectedRuntime {
                Label("\(store.runtimeState.queueCount)", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
                    .help("Queued messages")
            }

            ThinkingPickerControl(font: PiFont.micro)

            ModelPickerControl(font: PiFont.micro, maxWidth: 150)
        }
        .padding(.horizontal, PiTheme.space12)
        .frame(height: PiTheme.statusBarHeight)
        .background(Color.piTranscript)
        .overlay(alignment: .top) { PiHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pi session status")
    }

}

private struct StatusSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.piHairline)
            .frame(width: PiTheme.hairline, height: 11)
    }
}

private struct RuntimeStateLabel: View {
    @EnvironmentObject private var store: AppStore

    /// Idle is the normal state and needs no words: the bar only speaks while Pi is busy.
    private var activity: (text: String, help: String)? {
        if store.isSelectedRuntime, store.runtimeState.isCompacting {
            return ("Compacting", "Compacting the context window")
        }
        if store.isSelectedRuntime, store.runtimeState.isRetrying {
            return ("Retry \(store.runtimeState.retryAttempt ?? 1)", "Retrying the last provider request")
        }
        if store.isSelectedRuntime, store.runtimeState.isStreaming {
            return ("Working", "Pi is working on this turn")
        }
        if let session = store.selectedSession, store.isRunning(session) {
            return ("Working", "This conversation is working")
        }
        return nil
    }

    var body: some View {
        if let activity {
            HStack(spacing: PiTheme.space4) {
                ProgressView().controlSize(.mini)
                Text(activity.text)
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
            }
            .help(activity.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session state")
            .accessibilityValue(activity.help)

            StatusSeparator()
        }
    }
}

// MARK: - Cost

/// Cost is the headline; the token breakdown is one hover away.
private struct CostLabel: View {
    let metrics: TokenMetrics

    var body: some View {
        Text(NumberFormatting.cost(metrics.cost))
            .font(PiFont.micro.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session cost")
            .accessibilityValue(NumberFormatting.cost(metrics.cost))
            .hoverPopover {
                VStack(alignment: .leading, spacing: PiTheme.space6) {
                    PiSectionHeader(title: "Session", trailing: NumberFormatting.cost(metrics.cost))
                    MetricDetailRow(title: "Input", value: metrics.input)
                    MetricDetailRow(title: "Output", value: metrics.output)
                    MetricDetailRow(title: "Cache read", value: metrics.cacheRead)
                    MetricDetailRow(title: "Cache write", value: metrics.cacheWrite)
                    if let hit = metrics.latestCacheHitPercent {
                        MetricDetailRow(title: "Cache hit", text: "\(Int(hit.rounded()))%")
                    }
                    if let percent = metrics.contextPercent {
                        MetricDetailRow(title: "Context", text: "\(Int(percent.rounded()))%")
                    }
                }
                .padding(PiTheme.space16)
                .frame(width: 220)
            }
    }
}

private struct MetricDetailRow: View {
    let title: String
    var value: Int?
    var text: String?

    var body: some View {
        HStack(spacing: PiTheme.space8) {
            Text(title).font(PiFont.caption).foregroundStyle(.secondary)
            Spacer(minLength: PiTheme.space8)
            Text(text ?? NumberFormatting.tokens(value ?? 0))
                .font(PiFont.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hover popover

/// Hover-to-reveal detail that stays open while the pointer travels into it. A plain
/// `.popover` bound to `onHover` closes the instant the popover takes the mouse.
private struct HoverPopoverModifier<PopoverContent: View>: ViewModifier {
    @ViewBuilder let popoverContent: () -> PopoverContent

    @State private var presented = false
    @State private var anchorHovering = false
    @State private var contentHovering = false
    @State private var work: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                anchorHovering = hovering
                schedule(open: hovering)
            }
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                popoverContent()
                    .onHover { hovering in
                        contentHovering = hovering
                        schedule(open: hovering)
                    }
            }
            .onDisappear { work?.cancel() }
    }

    private func schedule(open: Bool) {
        work?.cancel()
        work = Task { @MainActor in
            try? await Task.sleep(nanoseconds: open ? 320_000_000 : 220_000_000)
            guard !Task.isCancelled else { return }
            presented = open ? true : (anchorHovering || contentHovering)
        }
    }
}

extension View {
    func hoverPopover<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(HoverPopoverModifier(popoverContent: content))
    }
}

// MARK: - codex-account

private struct CodexAccountControl: View {
    let account: CodexAccountStatus
    let isLive: Bool
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail = true } label: {
            HStack(spacing: PiTheme.space4) {
                Image(systemName: account.isLow ? "exclamationmark.triangle.fill" : "person.crop.circle")
                    .font(.system(size: 9, weight: .medium))
                Text(account.account)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let remaining = account.compactRemaining {
                    Text(remaining).monospacedDigit()
                }
                if let reset = account.compactReset {
                    Text(reset).monospacedDigit()
                }
            }
            .font(PiFont.micro)
            .foregroundStyle(tint)
            .opacity(isLive ? 1 : 0.55)
            .frame(maxWidth: 260, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover reveals every signed-in account, the same report `/limits` prints.
        .hoverPopover { LimitsPopoverView(fallback: account) }
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            LimitsPopoverView(fallback: account)
        }
        .help(helpText)
        .accessibilityLabel("Codex account usage")
        .accessibilityValue(account.detailLines.joined(separator: ", "))
    }

    private var tint: Color {
        if account.isLow { return .piRed }
        if account.isWarning { return .piOrange }
        return .secondary
    }

    private var helpText: String {
        (isLive ? account.detailLines : account.detailLines + ["Last known values"]).joined(separator: "\n")
    }
}

// MARK: - fast-priority

private struct FastPriorityControl: View {
    @EnvironmentObject private var store: AppStore
    let status: FastPriorityStatus
    let isLive: Bool
    @State private var hovering = false

    var body: some View {
        Button { store.toggleFastPriority() } label: {
            HStack(spacing: PiTheme.space4) {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                Text("fast")
            }
            .font(PiFont.micro)
            .foregroundStyle(status.isActive ? Color.piGreen : Color.secondary)
            .opacity(isLive ? 1 : 0.55)
            .padding(.horizontal, PiTheme.space6)
            .frame(height: 20)
            .contentShape(Rectangle())
            .background(
                hovering ? Color.piHover : Color.clear,
                in: RoundedRectangle(cornerRadius: PiTheme.radiusSmall, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(status.isActive ? "Fast priority active — click to toggle (/codex-fast)" : "Fast priority inactive — click to toggle (/codex-fast)")
        .accessibilityLabel("Fast priority")
        .accessibilityValue(status.isActive ? "active" : "inactive")
    }
}

// MARK: - unknown keys

/// Unknown status keys keep rendering generically, so a newly installed extension is visible
/// without a code change.
private struct GenericStatusChips: View {
    let chips: [(key: String, value: String)]
    let isLive: Bool

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: PiTheme.space8) {
                ForEach(chips.prefix(3), id: \.key) { chip in
                    Text(chip.value)
                        .font(PiFont.micro)
                        .foregroundStyle(.secondary)
                        .opacity(isLive ? 1 : 0.55)
                        .lineLimit(1)
                        .help("\(chip.key): \(chip.value)")
                }
                if chips.count > 3 {
                    Menu {
                        ForEach(chips.dropFirst(3), id: \.key) { chip in
                            Text("\(chip.key): \(chip.value)")
                        }
                    } label: {
                        Text("+\(chips.count - 3)")
                            .font(PiFont.micro.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }
}
