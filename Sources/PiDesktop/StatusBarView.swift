import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var store: AppStore

    private var metrics: TokenMetrics { store.selectedMetrics }
    private var statuses: ExtensionStatusModel { store.statusModel }

    var body: some View {
        HStack(spacing: PiTheme.space10) {
            RuntimeStateLabel()

            StatusSeparator()

            MetricLabel(symbol: "arrow.up", value: NumberFormatting.tokens(metrics.input), help: "Input tokens")
            MetricLabel(symbol: "arrow.down", value: NumberFormatting.tokens(metrics.output), help: "Output tokens")
            MetricLabel(symbol: "bolt.horizontal", value: NumberFormatting.tokens(metrics.cacheRead), help: "Cache read tokens")

            Text(NumberFormatting.cost(metrics.cost))
                .font(PiFont.micro.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Session cost")

            if let percent = metrics.contextPercent {
                HStack(spacing: PiTheme.space4) {
                    ProgressView(value: min(100, max(0, percent)), total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 44)
                    Text("\(Int(percent))%")
                        .font(PiFont.micro.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Context window usage")
            }

            Spacer(minLength: PiTheme.space8)

            // Pi TUI footer parity, driven entirely by verified extension status keys.
            if let account = statuses.codexAccount {
                CodexAccountControl(account: account, isLive: statuses.isLive)
                StatusSeparator()
            }
            ModeControl(mode: statuses.mode, isLive: statuses.isLive)
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

            Button(action: store.cycleThinkingLevel) {
                Text(thinking)
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSelectedRuntime)
            .help(store.isSelectedRuntime ? "Cycle thinking level" : "Thinking level")

            Button(action: store.cycleModel) {
                Text(model)
                    .font(PiFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSelectedRuntime)
            .help(store.isSelectedRuntime ? "Cycle model" : model)
        }
        .padding(.horizontal, PiTheme.space12)
        .frame(height: PiTheme.statusBarHeight)
        .background(Color.piTranscript)
        .overlay(alignment: .top) { PiHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pi session status")
    }

    private var model: String {
        if store.isSelectedRuntime {
            return store.runtimeState.modelName ?? store.runtimeState.modelID ?? "Model"
        }
        return store.selectedSession?.model ?? "Model unavailable"
    }
    private var thinking: String {
        if store.isSelectedRuntime { return store.runtimeState.thinkingLevel ?? "off" }
        return store.selectedSession?.thinkingLevel ?? "off"
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

    var body: some View {
        Group {
            if store.isSelectedRuntime, store.runtimeState.isCompacting {
                label("Compacting", symbol: "arrow.triangle.2.circlepath", tint: Color.piPurple)
            } else if store.isSelectedRuntime, store.runtimeState.isRetrying {
                label("Retry \(store.runtimeState.retryAttempt ?? 1)", symbol: "arrow.clockwise", tint: Color.piOrange)
            } else if store.isSelectedRuntime, store.runtimeState.isStreaming {
                HStack(spacing: PiTheme.space4) {
                    ProgressView().controlSize(.mini)
                    Text("Working")
                }
                .font(PiFont.micro)
                .foregroundStyle(.secondary)
            } else if store.isSelectedRuntime, store.runtimeState.isConnected {
                label("Ready", symbol: "circle.fill", tint: Color.piGreen)
            } else if let session = store.selectedSession, store.isRunning(session) {
                // Running in a terminal outside this app.
                HStack(spacing: PiTheme.space4) {
                    ProgressView().controlSize(.mini)
                    Text("Running elsewhere")
                }
                .font(PiFont.micro)
                .foregroundStyle(.secondary)
            } else {
                label("Idle", symbol: "circle", tint: .secondary)
            }
        }
        .help("Pi starts when you send a message")
    }

    private func label(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: PiTheme.space4) {
            Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(tint)
            Text(text).font(PiFont.micro).foregroundStyle(.secondary)
        }
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
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            CodexAccountDetail(account: account, isLive: isLive)
        }
        .help(helpText)
        .accessibilityLabel("Codex account usage")
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

private struct CodexAccountDetail: View {
    @EnvironmentObject private var store: AppStore
    let account: CodexAccountStatus
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space10) {
            PiSectionHeader(title: "Codex account", trailing: isLive ? nil : "cached")
            Text(account.account)
                .font(PiFont.rowEmphasis)
                .textSelection(.enabled)

            if account.windows.isEmpty {
                Text("Usage windows are not loaded yet.")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: PiTheme.space6) {
                    ForEach(account.windows, id: \.label) { window in
                        HStack(spacing: PiTheme.space8) {
                            Text(window.label)
                                .font(PiFont.caption.monospacedDigit())
                                .frame(width: 34, alignment: .leading)
                            ProgressView(value: Double(window.remainingPercent), total: 100)
                                .progressViewStyle(.linear)
                            Text("\(window.remainingPercent)%")
                                .font(PiFont.caption.monospacedDigit())
                                .foregroundStyle(window.remainingPercent <= 15 ? Color.piRed : .secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }

            if let count = account.bankedResetCount, count > 0 {
                Text("\(count) banked reset\(count == 1 ? "" : "s")"
                     + (account.bankedResetExpiry.map { ", first expires in \($0)" } ?? ""))
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            }

            PiHairline()

            Button("Show full limits…") { store.showLimits() }
                .buttonStyle(.plain)
                .font(PiFont.caption)
                .foregroundStyle(Color.accentColor)
                .help("Runs /limits, which reports through the extension dialog")
        }
        .padding(PiTheme.space16)
        .frame(width: 280)
    }
}

// MARK: - mode

private struct ModeControl: View {
    @EnvironmentObject private var store: AppStore
    let mode: PiMode?
    let isLive: Bool

    var body: some View {
        Menu {
            ForEach(PiMode.allCases) { candidate in
                Button {
                    store.setMode(candidate)
                } label: {
                    if candidate == mode { Text("✓ \(candidate.label) — \(candidate.detail)") }
                    else { Text("\(candidate.label) — \(candidate.detail)") }
                }
            }
        } label: {
            HStack(spacing: PiTheme.space4) {
                Image(systemName: "dial.medium")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text(mode?.label ?? "mode")
                    .font(PiFont.micro)
                    .foregroundColor(.secondary)
            }
            .opacity(mode == nil ? 0.55 : (isLive ? 1 : 0.55))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode.map { "Mode \($0.label) · \($0.detail)" } ?? "Switch Pi mode (/mode)")
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
            .padding(.horizontal, PiTheme.space4)
            .frame(height: 16)
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

private struct MetricLabel: View {
    let symbol: String
    let value: String
    let help: String

    var body: some View {
        HStack(spacing: PiTheme.space2) {
            Image(systemName: symbol).font(.system(size: 7, weight: .semibold))
            Text(value).monospacedDigit()
        }
        .font(PiFont.micro)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
