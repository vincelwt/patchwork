import Foundation

/// The inclusion rule shared by the Mac sidebar and clients that mirror it. Session discovery
/// remains broader: this projection only decides which discovered conversations belong in the
/// user's current sidebar.
public struct SidebarVisibility: Sendable {
    public let showsForeignConversations: Bool
    public let disabledAgents: Set<AgentKind>
    private let startedSessionPaths: Set<String>

    public init(
        showsForeignConversations: Bool,
        appStartedSessionPaths: Set<String>,
        desktopStartedThreadPaths: Set<String> = [],
        disabledAgents: Set<AgentKind> = []
    ) {
        self.showsForeignConversations = showsForeignConversations
        self.disabledAgents = disabledAgents
        startedSessionPaths = Set(
            appStartedSessionPaths.union(desktopStartedThreadPaths).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        )
    }

    public func includes(path: String, agent: AgentKind) -> Bool {
        guard !disabledAgents.contains(agent) else { return false }
        return showsForeignConversations
            || startedSessionPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }
}
