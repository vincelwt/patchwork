import Foundation
import PiDeskKit

/// The one place that maps an agent to its native protocol adapter.
///
/// Every agent goes through this, Pi included. There is no default-and-special-cases shape here
/// on purpose: adding a fourth agent is one case, and nothing else in the app changes.
enum AgentAdapterFactory {
    static func make(_ agent: AgentKind) -> AgentProtocolAdapter {
        switch agent {
        case .pi: PiProtocolAdapter()
        case .codex: CodexProtocolAdapter()
        case .claude: ClaudeProtocolAdapter()
        }
    }
}
