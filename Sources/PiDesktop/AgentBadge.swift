import PiDeskKit
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
    var size: CGFloat = PiTheme.agentBadgeSize
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
            HStack(spacing: PiTheme.space2) {
                ForEach(store.installedAgents) { agent in
                    let isSelected = store.newChatAgent == agent
                    Button {
                        store.newChatAgent = agent
                    } label: {
                        HStack(spacing: PiTheme.space4) {
                            Image(systemName: agent.symbolName)
                                .font(.system(size: PiTheme.agentBadgeSize, weight: .semibold))
                            Text(agent.shortName)
                                .font(isSelected ? PiFont.captionEmphasis : PiFont.caption)
                        }
                        .foregroundStyle(isSelected ? agent.tint : Color.secondary)
                        .padding(.horizontal, PiTheme.space8)
                        .padding(.vertical, PiTheme.space4)
                        .background(
                            Capsule().fill(isSelected ? agent.tint.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            Capsule().stroke(
                                isSelected ? agent.tint.opacity(0.45) : Color.piInset,
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

/// The complete runtime choice for a new conversation. A preset owns the agent choice, so the
/// agent is no longer independently switchable once presets exist.
struct PresetPicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings

    @ViewBuilder
    var body: some View {
        if store.availablePresets.isEmpty {
            VStack(spacing: PiTheme.space6) {
                AgentPicker()
                Button("Create a Preset…") {
                    store.settingsPane = .presets
                    openSettings()
                }
                    .font(PiFont.caption)
            }
        } else {
            HStack(spacing: PiTheme.space8) {
                if let preset = store.selectedPreset {
                    AgentBadge(agent: preset.agent, isProminent: true)
                    Menu {
                        ForEach(store.availablePresets) { choice in
                            Button { store.selectPreset(choice.id) } label: {
                                if choice.id == preset.id {
                                    Label(choice.name, systemImage: "checkmark")
                                } else {
                                    Text(choice.name)
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(preset.name).font(PiFont.captionEmphasis)
                            Text(preset.detail).font(PiFont.micro).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .help("Choose a preset. Press Command-Shift-P to cycle.")
                    .accessibilityLabel("New chat preset")
                    .accessibilityValue(preset.name)
                }
                Button {
                    store.settingsPane = .presets
                    openSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: PiIcon.small))
                }
                .buttonStyle(.plain)
                .help("Manage presets")
                .accessibilityLabel("Manage presets")
            }
            .padding(.horizontal, PiTheme.space10)
            .padding(.vertical, PiTheme.space6)
            .piInset()
        }
    }
}
