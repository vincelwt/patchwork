import Foundation

/// How an agent exposes its model list.
public enum ModelSelectionStyle: String, Codable, Hashable, Sendable {
    /// The runtime answers a "list your models" query, and a selection applies live.
    case queried
    /// No list exists over the protocol; the app offers a curated alias list and reports
    /// whatever the runtime says it is actually running.
    case aliases
}

/// How a reasoning/thinking level is applied once chosen.
public enum ThinkingApplyStyle: String, Codable, Hashable, Sendable {
    /// Applies to the live session immediately.
    case live
    /// Only takes effect on the next turn (the runtime carries it as a per-turn override).
    case nextTurn
    /// The process has to be relaunched with a new flag; the app does that transparently by
    /// resuming the same session id.
    case relaunch
    case unsupported
}

/// The agent's analogue of Pi's `/mode` slider: a small ordered set of named operating modes.
public struct AgentMode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    /// Ordering hint, lowest is the most restrictive/cheapest.
    public let rank: Int

    public init(id: String, title: String, detail: String, rank: Int) {
        self.id = id
        self.title = title
        self.detail = detail
        self.rank = rank
    }
}

/// What a given agent can actually do. Every optional affordance in the UI, the daemon, and the
/// CLI gates on this rather than on `AgentKind`, so adding an agent never means grepping for
/// `case .codex` across the app.
public struct AgentCapabilities: Codable, Hashable, Sendable {
    public var modelSelection: ModelSelectionStyle
    public var thinking: ThinkingApplyStyle
    /// Ordered modes for the composer control. Empty hides the control entirely.
    public var modes: [AgentMode]
    /// Human label for the mode control ("Mode", "Approvals", "Permissions").
    public var modeControlTitle: String
    public var canCompact: Bool
    public var canFork: Bool
    public var canExportHTML: Bool
    public var canRenameSession: Bool
    /// True when a message sent mid-turn interrupts and redirects the current turn. False means
    /// the app must queue it as a follow-up instead.
    public var canSteerMidTurn: Bool
    /// True when the runtime reports token usage/cost the inspector can show.
    public var reportsUsage: Bool
    /// True when the runtime can enumerate its slash commands / skills.
    public var listsCommands: Bool
    /// True when the runtime surfaces tool-permission prompts the app must answer.
    public var requestsToolPermission: Bool
    /// True when the runtime emits a structured plan/todo list.
    public var reportsPlan: Bool
    /// True when Pi Desktop's own activity extension can be installed for this agent.
    public var supportsActivityExtension: Bool

    public init(
        modelSelection: ModelSelectionStyle,
        thinking: ThinkingApplyStyle,
        modes: [AgentMode],
        modeControlTitle: String,
        canCompact: Bool,
        canFork: Bool,
        canExportHTML: Bool,
        canRenameSession: Bool,
        canSteerMidTurn: Bool,
        reportsUsage: Bool,
        listsCommands: Bool,
        requestsToolPermission: Bool,
        reportsPlan: Bool,
        supportsActivityExtension: Bool
    ) {
        self.modelSelection = modelSelection
        self.thinking = thinking
        self.modes = modes
        self.modeControlTitle = modeControlTitle
        self.canCompact = canCompact
        self.canFork = canFork
        self.canExportHTML = canExportHTML
        self.canRenameSession = canRenameSession
        self.canSteerMidTurn = canSteerMidTurn
        self.reportsUsage = reportsUsage
        self.listsCommands = listsCommands
        self.requestsToolPermission = requestsToolPermission
        self.reportsPlan = reportsPlan
        self.supportsActivityExtension = supportsActivityExtension
    }
}

public extension AgentKind {
    /// Pi's own modes, mirrored from the `mode` extension's `/mode` command. Pi applies these
    /// as a slash command rather than an RPC, which is why they are a ladder of effort rather
    /// than a permission policy like the other two agents.
    static let piModes: [AgentMode] = [
        AgentMode(id: "xfast", title: "xfast", detail: "Terra · xhigh · no subagents", rank: 0),
        AgentMode(id: "fast", title: "fast", detail: "Sol · xhigh · no subagents", rank: 1),
        AgentMode(id: "smart", title: "smart", detail: "Sol · xhigh · subagents", rank: 2),
        AgentMode(id: "ultra", title: "ultra", detail: "Sol · max · subagents", rank: 3)
    ]

    /// Codex sandbox modes, from `SandboxMode` in the app-server protocol.
    static let codexModes: [AgentMode] = [
        AgentMode(id: "read-only", title: "Read only", detail: "No writes, no network", rank: 0),
        AgentMode(id: "workspace-write", title: "Workspace", detail: "Write inside the workspace", rank: 1),
        AgentMode(id: "danger-full-access", title: "Full access", detail: "No sandbox at all", rank: 2)
    ]

    /// Claude Code permission modes, from `--permission-mode`.
    static let claudeModes: [AgentMode] = [
        AgentMode(id: "plan", title: "Plan", detail: "Research only, no edits", rank: 0),
        AgentMode(id: "manual", title: "Manual", detail: "Ask before every tool", rank: 1),
        AgentMode(id: "acceptEdits", title: "Accept edits", detail: "Auto-approve file edits", rank: 2),
        AgentMode(id: "auto", title: "Auto", detail: "Classifier decides per tool", rank: 3),
        AgentMode(id: "bypassPermissions", title: "Bypass", detail: "Approve everything", rank: 4)
    ]

    var capabilities: AgentCapabilities {
        switch self {
        case .pi:
            AgentCapabilities(
                modelSelection: .queried,
                thinking: .live,
                modes: Self.piModes,
                modeControlTitle: "Effort",
                canCompact: true,
                canFork: true,
                canExportHTML: true,
                canRenameSession: true,
                canSteerMidTurn: true,
                reportsUsage: true,
                listsCommands: true,
                requestsToolPermission: true,
                reportsPlan: false,
                supportsActivityExtension: true
            )
        case .codex:
            AgentCapabilities(
                modelSelection: .queried,
                thinking: .nextTurn,
                modes: Self.codexModes,
                modeControlTitle: "Sandbox",
                canCompact: true,
                canFork: true,
                canExportHTML: false,
                canRenameSession: true,
                canSteerMidTurn: true,
                reportsUsage: true,
                listsCommands: true,
                requestsToolPermission: true,
                reportsPlan: true,
                supportsActivityExtension: false
            )
        case .claude:
            AgentCapabilities(
                modelSelection: .aliases,
                thinking: .relaunch,
                modes: Self.claudeModes,
                modeControlTitle: "Permissions",
                canCompact: true,
                canFork: false,
                canExportHTML: false,
                canRenameSession: false,
                canSteerMidTurn: false,
                reportsUsage: true,
                listsCommands: true,
                requestsToolPermission: true,
                reportsPlan: true,
                supportsActivityExtension: false
            )
        }
    }
}
