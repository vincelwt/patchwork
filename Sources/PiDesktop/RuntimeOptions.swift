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
    static let allThinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func thinkingLevels(from value: JSONValue?) -> [String] {
        let received = value?.arrayValue?.compactMap(\.stringValue) ?? []
        let supported = allThinkingLevels.filter { received.contains($0) }
        return supported.isEmpty ? ["off"] : supported
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

    static func model(attached: Bool, models: [AvailableModel], loading: Bool) -> RuntimePickerPresentation {
        guard attached else { return .disabled }
        if !models.isEmpty { return .menu }
        return loading ? .disabled : .cycle
    }

    /// A single known level is not a choice, so the cycle command stays the honest fallback.
    static func thinking(attached: Bool, levels: [String], loading: Bool) -> RuntimePickerPresentation {
        guard attached else { return .disabled }
        if levels.count > 1 { return .menu }
        return loading ? .disabled : .cycle
    }
}
