import PiDeskKit
import Foundation

struct AvailableModel: Identifiable, Hashable, Sendable {
    var id: String { "\(provider)/\(modelID)" }
    let provider: String
    let modelID: String
    let name: String
    let reasoning: Bool

    var compactLabel: String { name.isEmpty ? modelID : name }
    var detailLabel: String { "\(provider) / \(modelID)" }

    init?(json: JSONValue) {
        guard let provider = json["provider"]?.stringValue,
              let modelID = json["id"]?.stringValue,
              !provider.isEmpty, !modelID.isEmpty else { return nil }
        self.provider = provider
        self.modelID = modelID
        self.name = json["name"]?.stringValue ?? modelID
        self.reasoning = json["reasoning"]?.boolValue ?? false
    }

    init(provider: String, modelID: String, name: String, reasoning: Bool = false) {
        self.provider = provider
        self.modelID = modelID
        self.name = name
        self.reasoning = reasoning
    }

    static func parse(_ value: JSONValue?) -> [AvailableModel] {
        var seen: Set<String> = []
        return (value?.arrayValue ?? []).prefix(500).compactMap(AvailableModel.init(json:)).filter {
            seen.insert($0.id).inserted
        }
    }
}

/// Deterministic selection normalization used by menus while asynchronous RPC options refresh.
enum RuntimePickerState {
    /// The shared vocabulary, which lives with the adapters that have to produce values in it.
    static let allThinkingLevels = AgentThinkingLevels.all

    static func thinkingLevels(from value: JSONValue?) -> [String] {
        AgentThinkingLevels.supported(value?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    static func selectedModel(in models: [AvailableModel], provider: String?, modelID: String?) -> AvailableModel? {
        if let provider, let modelID,
           let exact = models.first(where: { $0.provider == provider && $0.modelID == modelID }) {
            return exact
        }
        return models.first
    }

    static func selectedThinkingLevel(in levels: [String], current: String?) -> String {
        if let current, levels.contains(current) { return current }
        return levels.first ?? "off"
    }
}

// MARK: - Model scoping

/// The scoping fields from Pi's own `~/.pi/agent/settings.json`. Pi decides which models a
/// session may actually pick from; the desktop only ever reads this file, never writes it.
/// This is Pi's file and Pi's policy: it must never be applied to another agent's model list,
/// which would filter every entry out and leave an empty picker.
struct PiModelScope: Equatable {
    /// Raw `enabledModels` entries, e.g. `"openai-codex/*"` or `"anthropic/claude-opus-5"`.
    let enabledModels: [String]
    let defaultProvider: String?
    let defaultModel: String?

    var isEmpty: Bool { enabledModels.isEmpty }

    /// `provider/*` (or a bare provider entry with no slash) enables every model for that
    /// provider; `provider/model` enables exactly one.
    func allows(provider: String, modelID: String) -> Bool {
        for raw in enabledModels {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            guard let slash = entry.firstIndex(of: "/") else {
                if entry == provider { return true }
                continue
            }
            let entryProvider = String(entry[entry.startIndex..<slash])
            let entryModel = entry[entry.index(after: slash)...]
            guard entryProvider == provider else { continue }
            if entryModel == "*" || entryModel == modelID { return true }
        }
        return false
    }

    static func parse(_ json: JSONValue) -> PiModelScope? {
        guard let object = json.objectValue else { return nil }
        let models = object["enabledModels"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let provider = object["defaultProvider"]?.stringValue
        let model = object["defaultModel"]?.stringValue
        guard !models.isEmpty || provider != nil || model != nil else { return nil }
        return PiModelScope(enabledModels: models, defaultProvider: provider, defaultModel: model)
    }

    static func load(settingsURL: URL) -> PiModelScope? {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return parse(json)
    }

    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json", isDirectory: false)
    }

    /// Filters an RPC model list down to what Pi has actually enabled, keeping the current
    /// selection visible even if it falls outside that scope (a session already running an
    /// out-of-scope model must not lose its own entry from the menu), and returning the input
    /// unchanged when there is no scoping information to honour — an unreadable or empty
    /// settings file must degrade to "show everything", never to "show nothing".
    static func scoped(
        _ models: [AvailableModel],
        by scope: PiModelScope?,
        currentProvider: String?,
        currentModelID: String?
    ) -> [AvailableModel] {
        guard let scope, !scope.isEmpty else { return models }
        var filtered = models.filter { scope.allows(provider: $0.provider, modelID: $0.modelID) }
        if let currentProvider, let currentModelID,
           !filtered.contains(where: { $0.provider == currentProvider && $0.modelID == currentModelID }),
           let current = models.first(where: { $0.provider == currentProvider && $0.modelID == currentModelID }) {
            filtered.append(current)
        }
        return filtered
    }
}

/// Reads settings.json at most once per file change. The picker's menu is rebuilt on every
/// render, and re-parsing a small JSON file from disk on every one of those renders would be
/// wasted work; an mtime check keeps a hand-edited settings file honoured without a relaunch.
final class PiModelScopeCache: @unchecked Sendable {
    static let shared = PiModelScopeCache()

    private let url: URL
    private let isDefaultURL: Bool
    private var lastModified: Date?
    private var cached: PiModelScope?

    init(url: URL = PiModelScope.defaultSettingsURL) {
        self.url = url
        self.isDefaultURL = url == PiModelScope.defaultSettingsURL
    }

    func current() -> PiModelScope? {
        // The default location is the real, ambient `~/.pi/agent/settings.json`. A developer's
        // own scoping must never leak into the test suite and make an unrelated fixture model
        // vanish from a picker depending on what happens to be installed on the machine running
        // `swift test`. A cache constructed with an explicit `url:` (as tests do) bypasses this.
        if isDefaultURL, Self.isRunningTests { return nil }
        // `FileManager.attributesOfItem` always stats live; `URL.resourceValues(forKeys:)`
        // caches per `URL` instance and would keep returning the mtime from the first read.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let modified, modified == lastModified { return cached }
        lastModified = modified
        cached = PiModelScope.load(settingsURL: url)
        return cached
    }

    /// `XCTestConfigurationFilePath` is only set by Xcode's own test driver, not by `swift
    /// test`; checking for the linked `XCTestCase` class instead catches every invocation
    /// (SwiftPM, `xcodebuild`, and Xcode) that actually runs inside an XCTest host process.
    private static let isRunningTests =
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// How a model/thinking control presents itself. The composer and the status bar share this so
/// exact choices are discoverable in both places, and neither silently degrades to a mystery
/// button when Pi has not answered the query-only option RPCs yet.
enum RuntimePickerPresentation: Equatable {
    /// Explicit list of choices, applied with the `set_*` RPCs.
    case menu
    /// No list available, but the runtime still accepts `cycle_*`.
    case cycle
    /// Nothing is attached (or options are still loading): show the label, disabled.
    case disabled

    /// `allowsCycle` is false for agents with no cycle command: offering a button that can only
    /// fail is worse than showing the label disabled.
    static func model(
        attached: Bool,
        models: [AvailableModel],
        loading: Bool,
        allowsCycle: Bool = true
    ) -> RuntimePickerPresentation {
        guard attached else { return .disabled }
        if !models.isEmpty { return .menu }
        if loading || !allowsCycle { return .disabled }
        return .cycle
    }

    /// A single known level is not a choice, so the cycle command stays the honest fallback
    /// wherever the agent has one.
    static func thinking(
        attached: Bool,
        levels: [String],
        loading: Bool,
        allowsCycle: Bool = true
    ) -> RuntimePickerPresentation {
        guard attached else { return .disabled }
        if levels.count > 1 { return .menu }
        if loading || !allowsCycle { return .disabled }
        return .cycle
    }
}
