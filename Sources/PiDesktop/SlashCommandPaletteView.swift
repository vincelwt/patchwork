import PiDeskKit
import SwiftUI

/// The composer's slash-command list: the same rows, hairlines, and hint chips as the ⌘K
/// palette, drawn above the editor rather than over the window. It never takes focus — the
/// composer's own text view stays first responder and forwards the four palette keys.
struct SlashCommandPaletteView: View {
    let query: String
    let matches: [AgentCommand]
    let agent: AgentKind
    let isLoading: Bool
    @Binding var selection: Int
    let run: (AgentCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if matches.isEmpty {
                Text(emptyMessage)
                    .font(SidebarTypography.status)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PiTheme.space16)
                    .padding(.vertical, PiTheme.space12)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                                SlashCommandRow(command: command, agent: agent, selected: index == selection)
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        run(command)
                                    }
                            }
                        }
                        .padding(.vertical, PiTheme.space4)
                    }
                    .frame(maxHeight: PiTheme.commandPaletteMaxHeight)
                    .onChange(of: selection) { _, value in
                        withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(value, anchor: .center) }
                    }
                }

                PiHairline()

                HStack(spacing: PiTheme.space12) {
                    HintLabel(keys: "↑↓", text: "Navigate")
                    HintLabel(keys: "↩", text: "Run")
                    HintLabel(keys: "esc", text: "Dismiss")
                    Spacer()
                }
                .padding(.horizontal, PiTheme.space16)
                .frame(height: 26)
                // Already spoken by the rows themselves.
                .accessibilityHidden(true)
            }
        }
        .background(Color.piTranscript, in: RoundedRectangle(cornerRadius: PiTheme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PiTheme.panelRadius, style: .continuous)
                .stroke(Color.piHairline, lineWidth: PiTheme.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
    }

    /// Honest about which of the two empty states this is: still asking the agent, or asked and
    /// told there is nothing.
    private var emptyMessage: String {
        if isLoading { return "Loading commands…" }
        if query.isEmpty { return "\(agent.displayName) reported no commands" }
        return "No commands match “/\(query)”"
    }
}

private struct SlashCommandRow: View {
    let command: AgentCommand
    let agent: AgentKind
    let selected: Bool

    var body: some View {
        // The ⌘K result grid: one text origin, the secondary text truncating first, and a quiet
        // trailing tag.
        HStack(spacing: PiTheme.space6) {
            Text(command.prompt)
                .font(SidebarTypography.conversationTitle(selected: selected))
                .lineLimit(1)
                .layoutPriority(1)
            Text(command.detail)
                .font(SidebarTypography.metadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: PiTheme.space4)
            Text(command.sourceLabel(agent: agent))
                .font(SidebarTypography.metadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.leading, PiTheme.sidebarIconInset)
        .padding(.trailing, PiTheme.space8)
        .frame(height: PiTheme.commandPaletteRowHeight)
        .contentShape(Rectangle())
        .background(
            selected ? Color.piSelection : Color.clear,
            in: RoundedRectangle(cornerRadius: PiTheme.radiusSmall, style: .continuous)
        )
        .padding(.horizontal, PiTheme.space6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([command.prompt, command.detail, command.sourceLabel(agent: agent)]
            .filter { !$0.isEmpty }
            .joined(separator: ", "))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }
}
