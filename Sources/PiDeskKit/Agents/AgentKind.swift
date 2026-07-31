import Foundation

/// One coding agent Pi Desktop can drive. Every agent is a peer: Pi has no privileged path
/// through the app, it is simply the agent whose native protocol happens to be `--mode rpc`.
///
/// The raw value is the durable identity written into app state, daemon schedules, run history,
/// and the CLI/web wire format. Never renumber or rename a case.
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case pi
    case codex
    case claude

    public var id: String { rawValue }

    /// Decoding an agent Pi Desktop does not know must not fail a whole thread list; unknown
    /// identities degrade to Pi, which is the only agent guaranteed to parse a Pi session file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(rawValue: raw) ?? .pi
    }

    public var displayName: String {
        switch self {
        case .pi: "Pi"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    /// Short label for dense surfaces (sidebar rows, CLI table columns).
    public var shortName: String {
        switch self {
        case .pi: "Pi"
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    /// SF Symbol used wherever an agent needs a glyph. Deliberately monochrome shapes that read
    /// at 10pt in a sidebar row.
    public var symbolName: String {
        switch self {
        case .pi: "circle.hexagongrid"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        }
    }

    /// Stable hue (degrees) for the agent's accent tint. Views convert this through `Theme`.
    public var accentHue: Double {
        switch self {
        case .pi: 265
        case .codex: 150
        case .claude: 22
        }
    }
}
