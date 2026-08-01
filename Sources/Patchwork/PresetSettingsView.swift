import PatchworkKit
import SwiftUI

@MainActor
final class PresetOptionsLoader: ObservableObject {
    @Published private(set) var models: [AvailableModel] = []
    @Published private(set) var thinkingLevels: [String] = []
    @Published private(set) var currentModel: AvailableModel?
    @Published private(set) var currentThinkingLevel: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var runtime: AgentRuntimeProtocol?
    private var generation = UUID()
    private let runtimeFactory: @MainActor (AgentKind) -> AgentRuntimeProtocol

    init(runtimeFactory: @escaping @MainActor (AgentKind) -> AgentRuntimeProtocol = PresetOptionsLoader.makeRuntime) {
        self.runtimeFactory = runtimeFactory
    }

    private static func makeRuntime(for agent: AgentKind) -> AgentRuntimeProtocol {
        let additionalArguments = agent == .pi
            ? ["--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates"]
            : []
        return AgentRuntimeClient.make(for: agent, additionalArguments: additionalArguments)
    }

    func load(agent: AgentKind) {
        cancel()
        let generation = UUID()
        self.generation = generation
        isLoading = true
        error = nil
        models = []
        thinkingLevels = []
        currentModel = nil
        currentThinkingLevel = nil

        // Model discovery is read-only and must not depend on project or user extensions.
        // In particular, one broken extension must not leave the preset editor loading forever.
        let runtime = runtimeFactory(agent)
        self.runtime = runtime
        runtime.onExit = { [weak self, weak runtime] message in
            guard let self, self.generation == generation, self.runtime === runtime else { return }
            if let message, !message.isEmpty { self.error = message }
            else { self.error = "The agent stopped before its options were loaded." }
            self.finish()
        }

        do {
            try runtime.start(cwd: FileManager.default.temporaryDirectory, sessionPath: nil)
        } catch {
            self.error = error.localizedDescription
            finish()
            return
        }

        loadState(agent: agent, generation: generation)
    }

    private func loadState(agent: AgentKind, generation: UUID) {
        runtime?.send(type: "get_state", payload: [:]) { [weak self] result in
            guard let self, self.generation == generation, self.runtime != nil else { return }
            if case let .success(response) = result, Self.responseError(response) == nil {
                if let model = AvailableModel(json: response["data"]?["model"] ?? .null) {
                    self.currentModel = model
                }
                self.currentThinkingLevel = response["data"]?["thinkingLevel"]?.stringValue
            }
            self.captureError(result)
            self.loadModels(agent: agent, generation: generation)
        }
    }

    private func loadModels(agent: AgentKind, generation: UUID) {
        runtime?.send(type: "get_available_models", payload: [:]) { [weak self] result in
            guard let self, self.generation == generation, self.runtime != nil else { return }
            if case let .success(response) = result, Self.responseError(response) == nil {
                var models = AvailableModel.parse(response["data"]?["models"])
                if agent == .pi {
                    models = PiModelScope.scoped(
                        models,
                        by: PiModelScopeCache.shared.current(),
                        currentProvider: self.currentModel?.provider,
                        currentModelID: self.currentModel?.modelID
                    )
                }
                self.models = models
            }
            self.captureError(result)
            self.loadThinkingLevels(generation: generation)
        }
    }

    private func loadThinkingLevels(generation: UUID) {
        runtime?.send(type: "get_available_thinking_levels", payload: [:]) { [weak self] result in
            guard let self, self.generation == generation, self.runtime != nil else { return }
            if case let .success(response) = result, Self.responseError(response) == nil {
                self.thinkingLevels = RuntimePickerState.thinkingLevels(from: response["data"]?["levels"])
            }
            self.captureError(result)
            if self.models.isEmpty, let currentModel = self.currentModel { self.models = [currentModel] }
            if self.thinkingLevels.isEmpty {
                self.thinkingLevels = self.currentThinkingLevel.map { AgentThinkingLevels.supported([$0]) } ?? ["off"]
            }
            self.finish()
        }
    }

    func cancel() {
        generation = UUID()
        runtime?.onExit = nil
        runtime?.stop()
        runtime = nil
        isLoading = false
    }

    private func captureError(_ result: Result<JSONValue, Error>) {
        switch result {
        case let .failure(error) where self.error == nil:
            self.error = error.localizedDescription
        case let .success(response) where self.error == nil:
            self.error = Self.responseError(response)
        default:
            break
        }
    }

    private func finish() {
        runtime?.onExit = nil
        runtime?.stop()
        runtime = nil
        isLoading = false
    }

    private static func responseError(_ response: JSONValue) -> String? {
        if let error = response["error"]?.stringValue, !error.isEmpty { return error }
        if response["success"]?.boolValue == false { return "The agent rejected the request." }
        return nil
    }
}

private struct AgentPresetDraft {
    var id: UUID?
    var name = ""
    var agent: AgentKind
    var provider = ""
    var modelID = ""
    var modelName = ""
    var thinkingLevel = ""

    init(agent: AgentKind) { self.agent = agent }

    init(preset: AgentPreset) {
        id = preset.id
        name = preset.name
        agent = preset.agent
        provider = preset.provider
        modelID = preset.modelID
        modelName = preset.modelName
        thinkingLevel = preset.thinkingLevel
    }

    var preset: AgentPreset {
        AgentPreset(
            id: id ?? UUID(), name: name, agent: agent,
            provider: provider, modelID: modelID, modelName: modelName,
            thinkingLevel: thinkingLevel
        )
    }
}

struct PresetSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var loader = PresetOptionsLoader()
    @State private var draft: AgentPresetDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PatchworkTheme.space16) {
                HStack {
                    VStack(alignment: .leading, spacing: PatchworkTheme.space4) {
                        Text("Presets").font(PatchworkFont.title)
                        Text("Choose an agent, one of its models, and a thinking level for new chats.")
                            .font(PatchworkFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: PatchworkTheme.space8)
                    Button("Add Preset", action: beginAdding)
                        .disabled(store.installedAgents.isEmpty || draft != nil)
                }

                if let draft {
                    editor(draft)
                }

                if store.presets.isEmpty {
                    Text("No presets yet. Add one to make new-chat setup a single choice.")
                        .font(PatchworkFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(PatchworkTheme.space12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .patchworkInset()
                } else {
                    VStack(spacing: PatchworkTheme.space8) {
                        ForEach(Array(store.presets.enumerated()), id: \.element.id) { index, preset in
                            presetRow(preset, at: index)
                        }
                    }
                }
            }
            .padding(PatchworkTheme.space20)
        }
        .onDisappear { loader.cancel() }
    }

    private func presetRow(_ preset: AgentPreset, at index: Int) -> some View {
        HStack(spacing: PatchworkTheme.space10) {
            AgentBadge(agent: preset.agent, size: PatchworkTheme.agentBadgeSize + 2)
            VStack(alignment: .leading, spacing: PatchworkTheme.space2) {
                Text(preset.name).font(PatchworkFont.rowEmphasis)
                Text(preset.detail)
                    .font(PatchworkFont.micro)
                    .foregroundStyle(store.installedAgents.contains(preset.agent) ? .secondary : .tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: PatchworkTheme.space8)
            Menu {
                Button("Edit") { beginEditing(preset) }
                Button("Move Up") { store.movePreset(id: preset.id, offset: -1) }
                    .disabled(index == 0)
                Button("Move Down") { store.movePreset(id: preset.id, offset: 1) }
                    .disabled(index == store.presets.count - 1)
                Button("Delete", role: .destructive) { store.deletePreset(id: preset.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: PatchworkTheme.space20, height: PatchworkTheme.space20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(preset.name)")
        }
        .padding(PatchworkTheme.space12)
        .patchworkInset()
    }

    private func editor(_ value: AgentPresetDraft) -> some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space12) {
            Text(value.id == nil ? "New Preset" : "Edit Preset")
                .font(PatchworkFont.rowEmphasis)

            TextField("Preset name", text: draftBinding(\.name))

            Picker("Agent", selection: draftBinding(\.agent)) {
                ForEach(store.installedAgents) { agent in Text(agent.displayName).tag(agent) }
            }
            .onChange(of: draft?.agent) { _, agent in
                guard let agent else { return }
                draft?.provider = ""
                draft?.modelID = ""
                draft?.modelName = ""
                draft?.thinkingLevel = ""
                loader.load(agent: agent)
            }

            Picker("Model", selection: modelSelection) {
                if loader.isLoading {
                    Text("Loading models…").tag("")
                } else {
                    ForEach(editorModels) { model in
                        Text(model.compactLabel).tag(model.id)
                    }
                }
            }
            .disabled(loader.isLoading || editorModels.isEmpty)

            Picker("Thinking", selection: draftBinding(\.thinkingLevel)) {
                ForEach(loader.thinkingLevels, id: \.self) { level in
                    Text(level.capitalized).tag(level)
                }
            }
            .disabled(loader.isLoading || loader.thinkingLevels.isEmpty)

            if let error = loader.error {
                Text(error).font(PatchworkFont.micro).foregroundStyle(Color.patchworkRed)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    loader.cancel()
                    draft = nil
                }
                Button("Save") { saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(PatchworkTheme.space12)
        .patchworkInset(strong: true)
        .onChange(of: loader.isLoading) { _, loading in
            if !loading { normalizeLoadedChoices() }
        }
    }

    private var editorModels: [AvailableModel] {
        guard let draft else { return loader.models }
        var models = loader.models
        if !draft.modelID.isEmpty,
           !models.contains(where: { $0.provider == draft.provider && $0.modelID == draft.modelID }) {
            models.append(draft.preset.model)
        }
        return models
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                guard let draft, !draft.modelID.isEmpty else { return "" }
                return "\(draft.provider)/\(draft.modelID)"
            },
            set: { id in
                guard let model = editorModels.first(where: { $0.id == id }) else { return }
                draft?.provider = model.provider
                draft?.modelID = model.modelID
                draft?.modelName = model.name
            }
        )
    }

    private var canSave: Bool { draft?.preset.isValid == true && !loader.isLoading }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<AgentPresetDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft![keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func beginAdding() {
        guard let agent = store.installedAgents.first else { return }
        draft = AgentPresetDraft(agent: agent)
        loader.load(agent: agent)
    }

    private func beginEditing(_ preset: AgentPreset) {
        guard store.installedAgents.contains(preset.agent) else { return }
        draft = AgentPresetDraft(preset: preset)
        loader.load(agent: preset.agent)
    }

    private func normalizeLoadedChoices() {
        guard draft != nil, !loader.isLoading else { return }
        if draft?.modelID.isEmpty == true,
           let model = loader.currentModel ?? loader.models.first {
            draft?.provider = model.provider
            draft?.modelID = model.modelID
            draft?.modelName = model.name
        }
        if draft?.thinkingLevel.isEmpty == true {
            if loader.thinkingLevels.contains("xhigh") { draft?.thinkingLevel = "xhigh" }
            else if let current = loader.currentThinkingLevel, loader.thinkingLevels.contains(current) {
                draft?.thinkingLevel = current
            } else {
                draft?.thinkingLevel = loader.thinkingLevels.last ?? "off"
            }
        } else if let thinking = draft?.thinkingLevel, !loader.thinkingLevels.contains(thinking) {
            draft?.thinkingLevel = loader.thinkingLevels.contains("xhigh")
                ? "xhigh"
                : (loader.thinkingLevels.last ?? "off")
        }
    }

    private func saveDraft() {
        guard let preset = draft?.preset, preset.isValid else { return }
        store.savePreset(preset)
        loader.cancel()
        draft = nil
    }
}
