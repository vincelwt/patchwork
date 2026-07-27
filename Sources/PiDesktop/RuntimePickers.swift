import SwiftUI

/// The model and thinking controls are the same two views everywhere they appear, so the
/// composer and the status bar always offer the same exact choices, the same fallback, and the
/// same accessibility. Only the type scale differs.
extension AppStore {
    var currentProviderID: String? { runtimeState.provider ?? selectedSession?.provider }
    var currentModelID: String? { runtimeState.modelID ?? selectedSession?.model }

    var currentModelLabel: String {
        if let name = runtimeState.modelName { return name }
        // Falling back to a raw id (`gpt-5.6-sol`) is honest but shouty in a status bar, so it
        // is presented the way the provider writes it.
        if let id = runtimeState.modelID ?? selectedSession?.model { return ModelNaming.pretty(id) }
        return composerOptionsLoading ? "Loading…" : "Model"
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

    /// The RPC model list narrowed to what Pi itself has enabled in `settings.json`. Falls
    /// back to the unfiltered list whenever there is no scoping information to read — degrade
    /// to "show everything", never to "show nothing".
    var scopedModels: [AvailableModel] {
        PiModelScope.scoped(
            availableModels,
            by: PiModelScopeCache.shared.current(),
            currentProvider: currentProviderID,
            currentModelID: currentModelID
        )
    }

    var modelPickerPresentation: RuntimePickerPresentation {
        .model(attached: isCurrentRouteRuntime, models: scopedModels, loading: composerOptionsLoading)
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
                Button(action: store.prepareComposerOptions) {
                    PickerLabel(text: label.capitalized, font: font)
                }
                .buttonStyle(.plain)
                .opacity(0.55)
                .help("Prepare thinking options")
            }
        }
        .accessibilityLabel("Thinking level")
        .accessibilityValue(label)
    }
}

/// Turns a provider's model id into the name people actually use for it.
enum ModelNaming {
    private static let acronyms: Set<String> = ["gpt", "api", "ai", "llm", "xai", "o1", "o3"]

    static func pretty(_ identifier: String) -> String {
        let tail = identifier.split(separator: "/").last.map(String.init) ?? identifier
        guard !tail.isEmpty else { return identifier }
        return tail
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { part -> String in
                let value = String(part)
                // Version-ish fragments stay as written, known acronyms shout, the rest are
                // ordinary words. Guessing by length would turn "sol" into "SOL".
                if value.first?.isNumber == true { return value }
                if acronyms.contains(value.lowercased()) { return value.uppercased() }
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
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
                    ForEach(store.scopedModels) { model in
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
                Button(action: store.prepareComposerOptions) {
                    PickerLabel(text: label, font: font, maxWidth: maxWidth)
                }
                .buttonStyle(.plain)
                .opacity(0.55)
                .help("Prepare model options")
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
