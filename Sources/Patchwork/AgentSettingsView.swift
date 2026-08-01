import PatchworkKit
import SwiftUI

/// Which agents Patchwork drives, and what it may install for them.
///
/// Switching an agent off stops its transcripts being scanned and stops it being offered for a
/// new conversation. Nothing it owns is touched: no session file, no configuration, and no
/// already-installed skill.
struct AgentSettingsView: View {
    @EnvironmentObject private var store: AppStore
    /// Per-agent result of the most recent install, shown inline rather than as a toast that
    /// would be gone before the settings window is read.
    @State private var results: [AgentKind: AgentSkillInstaller.Outcome] = [:]
    @State private var installing: Set<AgentKind> = []
    /// Recomputed after every install so a row stops offering work it has already done.
    @State private var installedSkills: Set<AgentKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space16) {
            Text("Agents").font(PatchworkFont.title)

            if store.detectedAgents.isEmpty {
                Text("No agents found. Install pi, codex, or claude in ~/.local/bin.")
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: PatchworkTheme.space12) {
                    ForEach(store.detectedAgents) { agent in
                        row(for: agent)
                        if agent != store.detectedAgents.last { Divider() }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
                Toggle(isOn: Binding(
                    get: { store.showsForeignConversations },
                    set: { store.setShowsForeignConversations($0) }
                )) {
                    Text("Show conversations started elsewhere").font(PatchworkFont.body)
                }
                .toggleStyle(.switch)
                Text("An agent's directory also holds work from terminals, other desktop apps, and automations. Driving one of those from here means two processes writing the same transcript.")
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !missing.isEmpty {
                Text("Not installed: \(missing.map(\.displayName).joined(separator: ", "))")
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .task { installedSkills = Self.currentlyInstalledSkills() }
    }

    private var missing: [AgentKind] {
        AgentKind.allCases.filter { !store.detectedAgents.contains($0) }
    }

    @ViewBuilder
    private func row(for agent: AgentKind) -> some View {
        let isEnabled = !store.disabledAgents.contains(agent)
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            HStack(spacing: PatchworkTheme.space8) {
                AgentBadge(agent: agent, isProminent: isEnabled)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.displayName)
                        .font(PatchworkFont.rowEmphasis)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    Text(detail(for: agent))
                        .font(PatchworkFont.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: PatchworkTheme.space8)
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { store.setAgent(agent, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(isEnabled
                    ? "Stop reading \(agent.displayName) conversations and offering it for new chats"
                    : "Read \(agent.displayName) conversations again")
            }

            skillRow(for: agent, isEnabled: isEnabled)
        }
    }

    /// Pi is deliberately absent from this row: it already gets Patchwork's extension, which
    /// does strictly more than the skill would.
    @ViewBuilder
    private func skillRow(for agent: AgentKind, isEnabled: Bool) -> some View {
        if AgentSkillInstaller.supports(agent) {
            HStack(spacing: PatchworkTheme.space8) {
                Text(skillCaption(for: agent))
                    .font(PatchworkFont.micro)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: PatchworkTheme.space8)
                Button(installedSkills.contains(agent) ? "Reinstall Skill" : "Install Skill") {
                    install(agent)
                }
                .font(PatchworkFont.caption)
                .disabled(!isEnabled || installing.contains(agent))
            }
            .padding(.leading, PatchworkTheme.agentBadgeSize + PatchworkTheme.space12)
        }
    }

    private func skillCaption(for agent: AgentKind) -> String {
        if let result = results[agent] { return result.summary }
        if installedSkills.contains(agent) { return "Knows how to use patchwork" }
        return "Teach it to manage conversations and automations with patchwork"
    }

    private func detail(for agent: AgentKind) -> String {
        let capabilities = agent.capabilities
        var parts = ["Models: \(capabilities.modelSelection == .queried ? "live" : "aliases")"]
        if capabilities.canSteerMidTurn { parts.append("steering") }
        if capabilities.canCompact { parts.append("compaction") }
        if capabilities.supportsActivityExtension { parts.append("extension host") }
        return parts.joined(separator: " · ")
    }

    private func install(_ agent: AgentKind) {
        installing.insert(agent)
        results[agent] = nil
        Task {
            // File I/O off the main actor; the result is published back onto it.
            let outcome = await Task.detached(priority: .userInitiated) {
                AgentSkillInstaller.install(for: agent)
            }.value
            results[agent] = outcome
            installedSkills = Self.currentlyInstalledSkills()
            installing.remove(agent)
        }
    }

    private static func currentlyInstalledSkills() -> Set<AgentKind> {
        Set(AgentKind.allCases.filter { AgentSkillInstaller.isInstalled(for: $0) })
    }
}
