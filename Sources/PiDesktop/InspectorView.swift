import SwiftUI

/// A flat column, not a floating card: one background, one leading hairline (owned by the
/// conversation layout), quiet uppercase section headers, and no nested surfaces.
struct InspectorView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PiTheme.space16) {
                if store.selectedGit.isRepository {
                    GitSection(snapshot: store.selectedGit)
                }

                if let capability = store.activeCapability {
                    CapabilitySection(capability: capability)
                }

                let agents = store.activities.filter { $0.kind == .subagent }
                if !agents.isEmpty {
                    ActivitySection(title: "Subagents", items: agents)
                }

                let processes = store.activities.filter { $0.kind == .process }
                if !processes.isEmpty {
                    ActivitySection(title: "Background processes", items: processes)
                }

                MetricsSection()

                if !store.statusModel.isEmpty || !store.extensionWidgets.isEmpty {
                    ExtensionSection()
                }

                if let latest = store.unknownRPCEvents.last {
                    UnknownEventSection(event: latest, count: store.unknownRPCEvents.count)
                }
            }
            .padding(.horizontal, PiTheme.space12)
            .padding(.vertical, PiTheme.space16)
        }
        .frame(width: PiTheme.inspectorWidth)
        .background(Color.piTranscript)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Environment inspector")
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

    private var boundedFiles: [GitFileChange] { Array(snapshot.files.prefix(PiTheme.gitFileHardLimit)) }
    private var visibleFiles: [GitFileChange] {
        showAllFiles ? boundedFiles : Array(boundedFiles.prefix(PiTheme.gitFilePreviewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            HStack(spacing: PiTheme.space6) {
                PiSectionHeader(title: "Environment")
                Button(action: store.refreshSelectedGit) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh Git")
            }

            InspectorRow(symbol: "plusminus", title: "Changes") {
                if snapshot.isDirty {
                    Text("+\(snapshot.additions)").foregroundStyle(Color.piGreen)
                    Text("−\(snapshot.deletions)").foregroundStyle(Color.piRed)
                } else {
                    Text("clean").foregroundStyle(.tertiary)
                }
            }

            InspectorRow(symbol: "arrow.triangle.branch", title: snapshot.branch ?? "Worktree") {
                if snapshot.isDetached { Text("detached").foregroundStyle(.tertiary) }
            }
            .help(snapshot.statusHint ?? "Git worktree")

            if snapshot.isDirty {
                DisclosureButton(title: expanded ? "Hide files" : "\(snapshot.files.count) changed files", expanded: expanded) {
                    expanded.toggle()
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleFiles) { file in GitFileRow(file: file) }
                    }
                    if boundedFiles.count > visibleFiles.count {
                        MoreButton(title: "Show \(boundedFiles.count - visibleFiles.count) more") { showAllFiles = true }
                    } else if showAllFiles, boundedFiles.count > PiTheme.gitFilePreviewCount {
                        MoreButton(title: "Show less") { showAllFiles = false }
                    }
                    if snapshot.files.count > boundedFiles.count {
                        Text("\(snapshot.files.count - boundedFiles.count) more files not listed")
                            .font(PiFont.micro).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct GitFileRow: View {
    let file: GitFileChange

    var body: some View {
        HStack(spacing: PiTheme.space4) {
            Text(file.path)
                .font(PiFont.micro)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: PiTheme.space4)
            if file.isBinary {
                Text("bin").foregroundStyle(.tertiary)
            } else if file.linesUnavailable {
                // Text file that was too large to count: not the same as binary.
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text("+\(file.additions)").foregroundStyle(Color.piGreen)
                Text("−\(file.deletions)").foregroundStyle(Color.piRed)
            }
        }
        .font(PiFont.micro.monospacedDigit())
        .frame(height: PiTheme.inspectorRowHeight - 4)
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
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            PiSectionHeader(title: capability.kind.rawValue, trailing: "active")
            InspectorRow(symbol: capability.kind.symbol, title: capability.title) {
                ProgressView().controlSize(.mini)
            }
            if let target = capability.target {
                Text(target)
                    .font(PiFont.micro)
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
    @State private var showAll = false

    private var active: [ActivityItem] { items.filter { $0.status == .running || $0.status == .waiting || $0.status == .queued } }
    private var inactive: [ActivityItem] { items.filter { !active.contains($0) } }
    private var visible: [ActivityItem] {
        if showAll { return active + inactive }
        return active + Array(inactive.prefix(max(0, 6 - active.count)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            PiSectionHeader(title: title, trailing: active.isEmpty ? nil : "\(active.count) active")
            ForEach(visible) { ActivityRow(item: $0) }
            if items.count > visible.count {
                MoreButton(title: "Show \(items.count - visible.count) more") { showAll = true }
            } else if showAll, items.count > 6 {
                MoreButton(title: "Show less") { showAll = false }
            }
        }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: PiTheme.space6) {
                    status.frame(width: 12, height: 12)
                    Text(item.title).font(PiFont.caption).lineLimit(1)
                    Spacer(minLength: PiTheme.space4)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(PiFont.micro).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    PiChevron(expanded: expanded).opacity(hovering || expanded ? 1 : 0.3)
                }
                .frame(height: PiTheme.inspectorRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                Text(item.detail?.isEmpty == false ? item.detail! : item.raw.prettyPrinted(maxLength: 2_500))
                    .font(PiFont.codeSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PiTheme.space6)
                    .piInset(radius: PiTheme.radiusSmall)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .running, .waiting: ProgressView().controlSize(.mini)
        case .succeeded: symbol("checkmark.circle.fill", Color.piGreen)
        case .failed: symbol("xmark.circle.fill", Color.piRed)
        case .stopped: symbol("stop.circle", .secondary)
        case .queued: symbol("clock", .secondary)
        case .unknown: symbol("circle.dotted", .secondary)
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 10)).foregroundStyle(tint)
    }
}

// MARK: - Metrics

private struct MetricsSection: View {
    @EnvironmentObject private var store: AppStore
    private var metrics: TokenMetrics { store.selectedMetrics }

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            PiSectionHeader(title: "Session", trailing: NumberFormatting.cost(metrics.cost))
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
                HStack(spacing: PiTheme.space6) {
                    Text("Context").font(PiFont.micro).foregroundStyle(.secondary)
                    ProgressView(value: min(100, max(0, percent)), total: 100).progressViewStyle(.linear)
                    Text("\(Int(percent.rounded()))%").font(PiFont.micro.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(height: PiTheme.inspectorRowHeight)
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
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            PiSectionHeader(title: "Extensions", trailing: statuses.isLive ? nil : "cached")
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
                VStack(alignment: .leading, spacing: PiTheme.space2) {
                    Text(widget.key).font(PiFont.micro.weight(.medium)).foregroundStyle(.tertiary)
                    ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                        Text(ANSI.strip(line))
                            .font(PiFont.codeSmall)
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
    let event: String
    let count: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            PiSectionHeader(title: "Unknown Pi events", trailing: "\(count)")
            DisclosureButton(title: expanded ? "Hide payload" : "Show latest payload", expanded: expanded) {
                expanded.toggle()
            }
            if expanded {
                Text(event)
                    .font(PiFont.codeSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PiTheme.space6)
                    .piInset(radius: PiTheme.radiusSmall)
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
        HStack(spacing: PiTheme.space6) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 13, alignment: .center)
            Text(title)
                .font(PiFont.caption)
                .lineLimit(1)
            Spacer(minLength: PiTheme.space4)
            HStack(spacing: PiTheme.space4) { trailing() }
                .font(PiFont.micro)
        }
        .frame(height: PiTheme.inspectorRowHeight)
    }
}

private struct DisclosureButton: View {
    let title: String
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: PiTheme.space4) {
                PiChevron(expanded: expanded)
                Text(title).font(PiFont.micro).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: PiTheme.inspectorRowHeight - 4)
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
            Text(title).font(PiFont.micro).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}
