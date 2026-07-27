import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var store: AppStore

    private var statuses: ExtensionStatusModel { store.statusModel }

    var body: some View {
        HStack(spacing: PiTheme.space10) {
            RuntimeStateLabel()

            Spacer(minLength: PiTheme.space8)

            // Pi TUI footer parity, driven entirely by verified extension status keys. Cost and
            // the context meter live in the inspector now; the bar's vocabulary stays closed to
            // state, account, fast-priority, thinking, and model — a generic or unrecognised
            // chip (ponytail included) never reaches it, only the inspector's full list does.
            if statuses.values[ExtensionStatusParser.codexAccountKey] != nil {
                CodexAccountControl(account: statuses.codexAccount, isLive: statuses.isLive, isStale: statuses.codexAccountIsStale)
                StatusSeparator()
            }
            if let fast = statuses.fastPriority {
                FastPriorityControl(status: fast, isLive: statuses.isLive)
            }

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
    private var activity: (text: String, help: String, symbol: String?)? {
        if store.isOffline {
            let paused = store.runtimeState.isWaitingForNetwork
            return (paused ? "Offline · paused" : "Offline", paused ? "This turn will resume when the network returns" : "No network connection", "wifi.slash")
        }
        if store.isSelectedRuntime, store.runtimeState.isWaitingForNetwork {
            return ("Resuming", "Network restored; resuming the interrupted turn", nil)
        }
        if store.isSelectedRuntime, store.runtimeState.isCompacting {
            return ("Compacting", "Compacting the context window", nil)
        }
        if store.isSelectedRuntime, store.runtimeState.isRetrying {
            return ("Retry \(store.runtimeState.retryAttempt ?? 1)", "Retrying the last provider request", nil)
        }
        if store.isSelectedRuntime, store.runtimeState.isStreaming {
            return ("Working", "Pi is working on this turn", nil)
        }
        if let session = store.selectedSession, store.isRunning(session) {
            return ("Working", "This conversation is working", nil)
        }
        return nil
    }

    var body: some View {
        if let activity {
            HStack(spacing: PiTheme.space4) {
                if let symbol = activity.symbol {
                    Image(systemName: symbol).font(PiFont.micro)
                } else {
                    ProgressView().controlSize(.mini)
                }
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
    /// Nil only when the extension key has never once resolved to real data — the neutral
    /// placeholder case. Loading/degraded wire values fall back to the last known account
    /// upstream in `ExtensionStatusModel`, so `nil` here specifically means "never known".
    let account: CodexAccountStatus?
    let isLive: Bool
    let isStale: Bool
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail = true } label: {
            HStack(spacing: PiTheme.space4) {
                Image(systemName: symbolName)
                    .font(.system(size: PiIcon.micro, weight: .medium))
                Text(account?.account ?? "Codex account")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let remaining = account?.compactRemaining {
                    Text(remaining).monospacedDigit()
                }
                if let reset = account?.compactReset {
                    Text(reset).monospacedDigit()
                }
            }
            .font(PiFont.micro)
            .foregroundStyle(tint)
            .opacity(isLive && !isStale ? 1 : 0.55)
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
        .accessibilityValue(account?.detailLines.joined(separator: ", ") ?? "Not yet available")
    }

    private var symbolName: String {
        guard let account else { return "person.crop.circle" }
        return account.isLow ? "exclamationmark.triangle.fill" : "person.crop.circle"
    }

    private var tint: Color {
        guard let account else { return .secondary }
        if account.isLow { return .piRed }
        if account.isWarning { return .piOrange }
        return .secondary
    }

    private var helpText: String {
        guard let account else { return "Codex account status is not available yet" }
        let lines = (isLive && !isStale) ? account.detailLines : account.detailLines + ["Last known values"]
        return lines.joined(separator: "\n")
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
                Image(systemName: "bolt.fill").font(.system(size: PiIcon.micro, weight: .bold))
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
//
// Deliberately absent: unknown/generic extension chips (ponytail included) no longer render in
// the footer. `ExtensionStatusModel.genericChips` still exists for the inspector's full list.
