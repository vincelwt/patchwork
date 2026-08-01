import PatchworkKit
import SwiftUI

/// A flat column, not a floating card: one background, one leading hairline (owned by the
/// conversation layout), quiet uppercase section headers, and no nested surfaces.
///
/// Every section is agent-aware: sections only appear when the agent behind the conversation
/// actually produces the thing they show, so a Claude Code thread never renders an empty
/// Extensions block and a Codex thread never claims Pi's numbers.
struct InspectorView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var activities: RuntimeActivityModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PatchworkTheme.space16) {
                AgentSection()

                if store.selectedGit.isRepository || store.selectedWorktree != nil {
                    GitSection(snapshot: store.selectedGit)
                }

                if let capability = store.activeCapability {
                    CapabilitySection(capability: capability)
                }

                let agents = activities.items.filter { $0.kind == .subagent }
                if !agents.isEmpty {
                    ActivitySection(title: "Subagents", items: agents)
                }

                let processes = activities.items.filter { $0.kind == .process }
                if !processes.isEmpty {
                    ActivitySection(title: "Background processes", items: processes)
                }

                if store.activeCapabilities.reportsUsage {
                    MetricsSection()
                }

                // Only Pi has an extension host, so this is a capability check rather than a
                // "did anything arrive" check: an empty block would otherwise flicker in.
                if store.activeCapabilities.supportsActivityExtension,
                   !store.statusModel.isEmpty || !store.extensionWidgets.isEmpty {
                    ExtensionSection()
                }

                if let latest = store.unknownRPCEvents.last {
                    UnknownEventSection(
                        agent: store.activeAgent,
                        event: latest,
                        count: store.unknownRPCEvents.count
                    )
                }
            }
            .padding(.horizontal, PatchworkTheme.space12)
            .padding(.vertical, PatchworkTheme.space16)
        }
        .frame(width: PatchworkTheme.inspectorWidth)
        .background(Color.patchworkTranscript)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Environment inspector")
    }
}

// MARK: - Agent

/// Who is running this conversation and how it is configured. This is the one section that is
/// always present: which agent a transcript belongs to is never obvious from its contents, and
/// the same three controls mean different things per agent.
private struct AgentSection: View {
    @EnvironmentObject private var store: AppStore

    private var agent: AgentKind { store.activeAgent }
    private var capabilities: AgentCapabilities { store.activeCapabilities }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            PatchworkSectionHeader(title: "Agent", trailing: store.runtimeState.isConnected ? nil : "detached")

            InspectorRow(symbol: agent.symbolName, title: agent.displayName) {
                Text(store.runtimeState.sessionID?.prefix(8).description ?? "—")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            if let model = store.runtimeState.modelName ?? store.runtimeState.modelID {
                InspectorRow(symbol: "cpu", title: "Model") {
                    Text(model).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            if capabilities.thinking != .unsupported, let level = store.runtimeState.thinkingLevel {
                InspectorRow(symbol: "brain", title: "Thinking") {
                    Text(level).foregroundStyle(.secondary)
                }
            }

            if let mode = store.currentMode {
                InspectorRow(symbol: "slider.horizontal.3", title: capabilities.modeControlTitle) {
                    Text(mode.title).foregroundStyle(.secondary)
                }
                .help(mode.detail)
            }

            // Named plainly rather than hidden, so "why is Compact greyed out" answers itself.
            if !unavailable.isEmpty {
                InspectorRow(symbol: "minus.circle", title: "Unavailable") {
                    Text(unavailable.joined(separator: ", "))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .help("\(agent.displayName) has no equivalent for these")
            }
        }
    }

    private var unavailable: [String] {
        var missing: [String] = []
        if !capabilities.canCompact { missing.append("compact") }
        if !capabilities.canFork { missing.append("edit history") }
        if !capabilities.canExportHTML { missing.append("export") }
        if !capabilities.canRenameSession { missing.append("rename") }
        if !capabilities.canSteerMidTurn { missing.append("steering") }
        return missing
    }
}

// MARK: - Git

private struct GitSection: View {
    @EnvironmentObject private var store: AppStore
    let snapshot: GitSnapshot
    /// Starts collapsed: a dirty monorepo can list thousands of files, and instantiating a row
    /// per file on every inspector render is what made large repositories stall.
    @State private var expanded = false
    @State private var showAllFiles = false

    private var boundedFiles: [GitFileChange] { Array(snapshot.files.prefix(PatchworkTheme.gitFileHardLimit)) }
    private var visibleFiles: [GitFileChange] {
        showAllFiles ? boundedFiles : Array(boundedFiles.prefix(PatchworkTheme.gitFilePreviewCount))
    }
    private var changedFilesTitle: String {
        "\(snapshot.files.count)\(snapshot.filesTruncated ? "+" : "") changed files"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            HStack(spacing: PatchworkTheme.space6) {
                PatchworkSectionHeader(title: "Environment")
                Button(action: store.refreshSelectedGit) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: PatchworkIcon.micro, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh Git")
            }

            if snapshot.isRepository {
                InspectorRow(symbol: "plusminus", title: "Changes") {
                    if snapshot.isDirty {
                        Text("+\(snapshot.additions)").foregroundStyle(Color.patchworkGreen)
                        Text("−\(snapshot.deletions)").foregroundStyle(Color.patchworkRed)
                    } else {
                        Text("clean").foregroundStyle(.tertiary)
                    }
                }

                InspectorRow(symbol: "arrow.triangle.branch", title: snapshot.branch ?? "Worktree") {
                    if snapshot.isDetached { Text("detached").foregroundStyle(.tertiary) }
                }
                .help(snapshot.statusHint ?? "Git worktree")
            }

            if let worktree = store.selectedWorktree {
                InspectorRow(symbol: "arrow.branch", title: "Worktree") {
                    Text(worktree.name).lineLimit(1).truncationMode(.middle)
                }
                .help("Linked from \(worktree.mainName) \u{b7} \(worktree.path)")
            }

            if snapshot.isDirty {
                DisclosureButton(title: expanded ? "Hide files" : changedFilesTitle, expanded: expanded) {
                    expanded.toggle()
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleFiles) { file in GitFileRow(file: file) }
                    }
                    if boundedFiles.count > visibleFiles.count {
                        MoreButton(title: "Show \(boundedFiles.count - visibleFiles.count) more") { showAllFiles = true }
                    } else if showAllFiles, boundedFiles.count > PatchworkTheme.gitFilePreviewCount {
                        MoreButton(title: "Show less") { showAllFiles = false }
                    }
                    if snapshot.filesTruncated || snapshot.files.count > boundedFiles.count {
                        Text("Additional changed files are not listed")
                            .font(PatchworkFont.micro).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct GitFileRow: View {
    let file: GitFileChange

    var body: some View {
        HStack(spacing: PatchworkTheme.space4) {
            Text(file.path)
                .font(PatchworkFont.micro)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: PatchworkTheme.space4)
            if file.isBinary {
                Text("bin").foregroundStyle(.tertiary)
            } else if file.linesUnavailable {
                // Text file that was too large to count: not the same as binary.
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text("+\(file.additions)").foregroundStyle(Color.patchworkGreen)
                Text("−\(file.deletions)").foregroundStyle(Color.patchworkRed)
            }
        }
        .font(PatchworkFont.micro.monospacedDigit())
        .frame(height: PatchworkTheme.inspectorRowHeight - 4)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help)
    }

    private var help: String {
        if file.isBinary { return "\(file.path) · binary" }
        if file.linesUnavailable { return "\(file.path) · text, LOC unavailable (file too large to count)" }
        return "\(file.path) · +\(file.additions) −\(file.deletions)"
    }
}

// MARK: - Current capability

private struct CapabilitySection: View {
    let capability: ToolCapability

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            PatchworkSectionHeader(title: capability.kind.rawValue, trailing: "active")
            InspectorRow(symbol: capability.kind.symbol, title: capability.title) {
                StatusDot(color: .patchworkGreen, pulsing: true)
            }
            if let target = capability.target {
                Text(target)
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Target: \(target)")
            }
        }
    }
}

// MARK: - Activities

private struct ActivitySection: View {
    let title: String
    let items: [ActivityItem]
    @State private var showFinished = false

    private var active: [ActivityItem] { items.filter { $0.status == .running || $0.status == .waiting || $0.status == .queued } }
    private var finished: [ActivityItem] { items.filter { !active.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            // Only what is currently running gets a full section; a finished item collapses into
            // one quiet summary row instead of padding the inspector with a stale history.
            if !active.isEmpty {
                PatchworkSectionHeader(title: title, trailing: "\(active.count) active")
                ForEach(active) { ActivityRow(item: $0) }
            }
            if !finished.isEmpty {
                DisclosureButton(title: showFinished ? "Hide finished" : summaryTitle, expanded: showFinished) {
                    showFinished.toggle()
                }
                if showFinished { ForEach(finished) { ActivityRow(item: $0) } }
            }
        }
    }

    /// Nothing running: the summary row carries the section title itself, so an idle section is
    /// one line instead of a header sitting over an empty list.
    private var summaryTitle: String {
        active.isEmpty ? "\(title) \u{b7} \(finished.count) done" : "\(finished.count) done"
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PatchworkTheme.space6) {
                    status.frame(width: 12, height: 12)
                    if item.kind == .subagent {
                        VStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                            Text(item.title).font(PatchworkFont.caption).lineLimit(1)
                            AgentMetadataLine(item: item)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(item.title).font(PatchworkFont.caption).lineLimit(1)
                        Spacer(minLength: PatchworkTheme.space4)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(PatchworkFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    PatchworkChevron(expanded: expanded).opacity(hovering || expanded ? 1 : 0.3)
                }
                .frame(minHeight: PatchworkTheme.inspectorRowHeight)
                .padding(.vertical, item.kind == .subagent ? PatchworkTheme.space2 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                Text(item.detail?.isEmpty == false ? item.detail! : item.raw.prettyPrinted(maxLength: 2_500))
                    .font(PatchworkFont.codeSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PatchworkTheme.space6)
                    .patchworkInset(radius: PatchworkTheme.radiusSmall)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .running, .waiting: StatusDot(color: .patchworkGreen, pulsing: true)
        case .succeeded: symbol("checkmark.circle.fill", Color.patchworkGreen)
        case .failed: symbol("xmark.circle.fill", Color.patchworkRed)
        case .stopped: symbol("stop.circle", .secondary)
        case .queued: symbol("clock", .secondary)
        case .unknown: symbol("circle.dotted", .secondary)
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).font(.system(size: PatchworkIcon.small)).foregroundStyle(tint)
    }
}

private struct AgentMetadataLine: View {
    let item: ActivityItem

    @ViewBuilder var body: some View {
        if [.running, .waiting, .queued].contains(item.status), item.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                label(at: context.date)
            }
        } else {
            label(at: item.endedAt ?? Date())
        }
    }

    private func label(at date: Date) -> some View {
        Text(item.agentSummary(now: date) ?? "Agent")
            .font(PatchworkFont.micro.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

// MARK: - Metrics

private struct MetricsSection: View {
    @EnvironmentObject private var store: AppStore
    private var metrics: TokenMetrics { store.selectedMetrics }

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            PatchworkSectionHeader(title: "Session", trailing: NumberFormatting.cost(metrics.cost))
            InspectorRow(symbol: "arrow.up", title: "Input") { value(metrics.input) }
            InspectorRow(symbol: "arrow.down", title: "Output") { value(metrics.output) }
            InspectorRow(symbol: "bolt.horizontal", title: "Cache read") { value(metrics.cacheRead) }
            InspectorRow(symbol: "square.and.arrow.down", title: "Cache write") { value(metrics.cacheWrite) }
            if let hit = metrics.latestCacheHitPercent {
                InspectorRow(symbol: "percent", title: "Cache hit") {
                    Text("\(Int(hit.rounded()))%").monospacedDigit()
                }
            }
            if let percent = metrics.contextPercent {
                // Past 100% the window is provably over what the model can see — the one
                // context state worth alarming red for, everywhere else stays neutral.
                let overBudget = ContextBudget.isOverBudget(percent)
                HStack(spacing: PatchworkTheme.space6) {
                    Text("Context").font(PatchworkFont.micro).foregroundStyle(overBudget ? Color.patchworkRed : .secondary)
                    Group {
                        if overBudget {
                            ProgressView(value: min(100, max(0, percent)), total: 100).tint(Color.patchworkRed)
                        } else {
                            ProgressView(value: min(100, max(0, percent)), total: 100)
                        }
                    }
                    .progressViewStyle(.linear)
                    Text("\(Int(percent.rounded()))%")
                        .font(PatchworkFont.micro.monospacedDigit())
                        .foregroundStyle(overBudget ? Color.patchworkRed : .secondary)
                }
                .frame(height: PatchworkTheme.inspectorRowHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Context window usage")
                .accessibilityValue(overBudget ? "\(Int(percent.rounded())) percent, over budget" : "\(Int(percent.rounded())) percent")
            }
        }
    }

    private func value(_ number: Int) -> some View {
        Text(NumberFormatting.tokens(number)).monospacedDigit()
    }
}

// MARK: - Extensions

private struct ExtensionSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let statuses = store.statusModel
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            PatchworkSectionHeader(title: "Extensions", trailing: statuses.isLive ? nil : "cached")
            ForEach(statuses.values.keys.sorted(), id: \.self) { key in
                InspectorRow(symbol: "puzzlepiece.extension", title: key) {
                    Text(statuses.values[key] ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .opacity(statuses.isLive ? 1 : 0.6)
            }
            ForEach(store.extensionWidgets.values.sorted(by: { $0.key < $1.key })) { widget in
                VStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                    Text(widget.key).font(PatchworkFont.micro.weight(.medium)).foregroundStyle(.tertiary)
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(ANSI.strip(line))
                            .font(PatchworkFont.codeSmall)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
        }
    }
}

private struct UnknownEventSection: View {
    let agent: AgentKind
    let event: String
    let count: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            PatchworkSectionHeader(title: "Unknown \(agent.shortName) events", trailing: "\(count)")
            DisclosureButton(title: expanded ? "Hide payload" : "Show latest payload", expanded: expanded) {
                expanded.toggle()
            }
            if expanded {
                Text(event)
                    .font(PatchworkFont.codeSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PatchworkTheme.space6)
                    .patchworkInset(radius: PatchworkTheme.radiusSmall)
            }
        }
    }
}

// MARK: - Shared inspector primitives

/// One dense inspector row: leading symbol, title, trailing value. No nesting, no card.
private struct InspectorRow<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: PatchworkTheme.space6) {
            Image(systemName: symbol)
                .font(.system(size: PatchworkIcon.micro))
                .foregroundStyle(.tertiary)
                .frame(width: 13, alignment: .center)
            Text(title)
                .font(PatchworkFont.caption)
                .lineLimit(1)
            Spacer(minLength: PatchworkTheme.space4)
            HStack(spacing: PatchworkTheme.space4) { trailing() }
                .font(PatchworkFont.micro)
        }
        .frame(height: PatchworkTheme.inspectorRowHeight)
    }
}

private struct DisclosureButton: View {
    let title: String
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: PatchworkTheme.space4) {
                PatchworkChevron(expanded: expanded)
                Text(title).font(PatchworkFont.micro).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: PatchworkTheme.inspectorRowHeight - 4)
            .contentShape(Rectangle())
            .opacity(hovering ? 1 : 0.85)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MoreButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(PatchworkFont.micro).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}
