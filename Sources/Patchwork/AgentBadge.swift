import PatchworkKit
import SwiftUI

extension AgentKind {
    /// The agent's tint, derived from its declared hue so a new agent needs no theme edit.
    var tint: Color { Color(hue: accentHue / 360, saturation: 0.62, brightness: 0.82) }
}

/// The agent marker used wherever a conversation is listed. Deliberately a glyph rather than a
/// word: sidebar rows are dense, and the tint plus shape is enough to tell three agents apart at
/// a glance. The accessibility label carries the full name for anyone who cannot rely on that.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = PatchworkTheme.agentBadgeSize
    /// Dimmed for rows that are not the current selection, so the badge never out-shouts the title.
    var isProminent = true

    var body: some View {
        Image(systemName: agent.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isProminent ? agent.tint : agent.tint.opacity(0.55))
            .frame(width: size + 4, height: size + 4)
            .accessibilityLabel(agent.displayName)
            .help(agent.displayName)
    }
}

/// The agent chooser for a new conversation. Shows only agents whose executable actually
/// resolved, so a pick can never fail at spawn time, and hides itself entirely when there is
/// exactly one agent installed rather than presenting a control with a single choice.
struct AgentPicker: View {
    @EnvironmentObject private var store: AppStore

    @ViewBuilder
    var body: some View {
        if store.installedAgents.count > 1 {
            HStack(spacing: PatchworkTheme.space2) {
                ForEach(store.installedAgents) { agent in
                    let isSelected = store.newChatAgent == agent
                    Button {
                        store.newChatAgent = agent
                    } label: {
                        HStack(spacing: PatchworkTheme.space4) {
                            Image(systemName: agent.symbolName)
                                .font(.system(size: PatchworkTheme.agentBadgeSize, weight: .semibold))
                            Text(agent.shortName)
                                .font(isSelected ? PatchworkFont.captionEmphasis : PatchworkFont.caption)
                        }
                        .foregroundStyle(isSelected ? agent.tint : Color.secondary)
                        .padding(.horizontal, PatchworkTheme.space8)
                        .padding(.vertical, PatchworkTheme.space4)
                        .background(
                            Capsule().fill(isSelected ? agent.tint.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            Capsule().stroke(
                                isSelected ? agent.tint.opacity(0.45) : Color.patchworkInset,
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Start this conversation with \(agent.displayName)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }
}
