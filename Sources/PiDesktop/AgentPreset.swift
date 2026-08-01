import Foundation
import PiDeskKit

/// A complete new-chat runtime choice. The display name is cached so the preset remains
/// understandable when an agent temporarily stops reporting that model.
struct AgentPreset: Codable, Equatable, Identifiable, Sendable {
    static let maximumCount = 50
    static let maximumNameLength = 60
    private static let maximumProviderLength = 100
    private static let maximumModelIDLength = 300
    private static let maximumModelNameLength = 120

    let id: UUID
    var name: String
    var agent: AgentKind
    var provider: String
    var modelID: String
    var modelName: String
    var thinkingLevel: String

    init(
        id: UUID = UUID(),
        name: String,
        agent: AgentKind,
        provider: String,
        modelID: String,
        modelName: String,
        thinkingLevel: String
    ) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        self.agent = agent
        self.provider = String(provider.prefix(Self.maximumProviderLength))
        self.modelID = String(modelID.prefix(Self.maximumModelIDLength))
        self.modelName = String(modelName.prefix(Self.maximumModelNameLength))
        self.thinkingLevel = String(thinkingLevel.prefix(16))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            agent: try container.decode(AgentKind.self, forKey: .agent),
            provider: try container.decode(String.self, forKey: .provider),
            modelID: try container.decode(String.self, forKey: .modelID),
            modelName: try container.decode(String.self, forKey: .modelName),
            thinkingLevel: try container.decode(String.self, forKey: .thinkingLevel)
        )
    }

    var model: AvailableModel {
        AvailableModel(provider: provider, modelID: modelID, name: modelName)
    }

    var detail: String {
        "\(agent.shortName) · \(modelName.isEmpty ? ModelNaming.pretty(modelID) : modelName) · \(thinkingLevel.capitalized)"
    }

    /// Changes whenever applying this preset would produce a different runtime configuration.
    var fingerprint: String {
        [id.uuidString, agent.rawValue, provider, modelID, thinkingLevel].joined(separator: "|")
    }

    var isValid: Bool {
        !name.isEmpty && !provider.isEmpty && !modelID.isEmpty
            && AgentThinkingLevels.all.contains(thinkingLevel)
    }

    static func normalized(_ values: [AgentPreset]) -> [AgentPreset] {
        var seen: Set<UUID> = []
        return values.prefix(maximumCount).filter { $0.isValid && seen.insert($0.id).inserted }
    }
}
