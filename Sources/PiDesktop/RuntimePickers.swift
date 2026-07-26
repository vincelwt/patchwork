import SwiftUI

/// The model and thinking controls are the same two views everywhere they appear, so the
/// composer and the status bar always offer the same exact choices, the same fallback, and the
/// same accessibility. Only the type scale differs.
extension AppStore {
    var currentProviderID: String? { runtimeState.provider ?? selectedSession?.provider }
    var currentModelID: String? { runtimeState.modelID ?? selectedSession?.model }

    var currentModelLabel: String {
        runtimeState.modelName
            ?? runtimeState.modelID
            ?? selectedSession?.model
            ?? (composerOptionsLoading ? "Loading…" : "Model")
    }

    var currentThinkingLabel: String {
        runtimeState.thinkingLevel ?? selectedSession?.thinkingLevel ?? "off"
    }

    /// "Model" is a placeholder title, not a value: VoiceOver must not read the control's own
    /// name back as its value.
    var currentModelAccessibilityValue: String {
        if let name = runtimeState.modelName ?? runtimeState.modelID ?? selectedSession?.model {
            return name
        }
        return composerOptionsLoading ? "loading" : "unavailable"
    }

    var modelPickerPresentation: RuntimePickerPresentation {
        .model(attached: isCurrentRouteRuntime, models: availableModels, loading: composerOptionsLoading)
    }

    var thinkingPickerPresentation: RuntimePickerPresentation {
        .thinking(attached: isCurrentRouteRuntime, levels: availableThinkingLevels, loading: composerOptionsLoading)
    }
}

struct ThinkingPickerControl: View {
    @EnvironmentObject private var store: AppStore
    var font: Font = PiFont.caption

    var body: some View {
        let label = store.currentThinkingLabel
        Group {
            switch store.thinkingPickerPresentation {
            case .menu:
                Menu {
                    ForEach(store.availableThinkingLevels, id: \.self) { level in
                        Button { store.setThinkingLevel(level) } label: {
                            if level == label { Label(level.capitalized, systemImage: "checkmark") }
                            else { Text(level.capitalized) }
                        }
                    }
                } label: {
                    PickerLabel(text: label.capitalized, font: font)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Thinking level — choose one")
            case .cycle:
                Button(action: store.cycleThinkingLevel) {
                    PickerLabel(text: label.capitalized, font: font)
                }
                .buttonStyle(.plain)
                .help("Thinking level — click to cycle")
            case .disabled:
                // Its own accessibility element, otherwise a plain label merges into the
                // neighbouring model label and VoiceOver reads "off Model".
                PickerLabel(text: label.capitalized, font: font)
                    .opacity(0.55)
                    .accessibilityElement(children: .ignore)
                    .help("Thinking level")
            }
        }
        .accessibilityLabel("Thinking level")
        .accessibilityValue(label)
    }
}

struct ModelPickerControl: View {
    @EnvironmentObject private var store: AppStore
    var font: Font = PiFont.caption
    var maxWidth: CGFloat = 130

    var body: some View {
        let label = store.currentModelLabel
        Group {
            switch store.modelPickerPresentation {
            case .menu:
                Menu {
                    ForEach(store.availableModels) { model in
                        Button { store.setModel(model) } label: {
                            if model.provider == store.currentProviderID && model.modelID == store.currentModelID {
                                Label(model.compactLabel, systemImage: "checkmark")
                            } else {
                                Text(model.compactLabel)
                            }
                        }
                        .help(model.detailLabel)
                    }
                } label: {
                    PickerLabel(text: label, font: font, maxWidth: maxWidth)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(help(label))
            case .cycle:
                Button(action: store.cycleModel) {
                    PickerLabel(text: label, font: font, maxWidth: maxWidth)
                }
                .buttonStyle(.plain)
                .help("\(help(label)) — click to cycle")
            case .disabled:
                PickerLabel(text: label, font: font, maxWidth: maxWidth)
                    .opacity(0.55)
                    .accessibilityElement(children: .ignore)
                    .help(help(label))
            }
        }
        .accessibilityLabel("Model")
        .accessibilityValue(store.currentModelAccessibilityValue)
    }

    private func help(_ label: String) -> String {
        store.currentProviderID.map { "\($0) · \(label)" } ?? label
    }
}

/// One label treatment for both pickers so the two controls stay on the same baseline grid.
private struct PickerLabel: View {
    let text: String
    let font: Font
    var maxWidth: CGFloat?

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: maxWidth, alignment: .trailing)
    }
}
