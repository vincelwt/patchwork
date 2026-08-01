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

/// How an agent applies its lower-latency, higher-cost execution option.
public enum FastModeApplyStyle: String, Codable, Hashable, Sendable {
    /// Pi's activity extension owns `/codex-fast` and publishes the authoritative status chip.
    case extensionCommand
    /// The native protocol updates a setting on the current thread without restarting it.
    case threadSetting
    /// The setting is launch-scoped, so the same conversation is resumed in a new process.
    case relaunch
    case unsupported
}

/// What the composer's left-to-right ladder actually changes for an agent.
public enum AgentLadder: String, Codable, Hashable, Sendable {
    /// A fixed set of named operating modes the agent declares (Pi's `/mode`).
    case modes
    /// The agent's own model list, weakest to strongest. Agents that present models in a picker
    /// order them strongest-first, so the ladder is that list reversed.
    case models
}

/// How the control plane can make an empty conversation durable without sending a provider
/// prompt. `sessionName` is still prompt-free, but the runtime's start acknowledgement alone is
/// not enough: the name command is the write barrier that creates the transcript.
public enum IdleThreadCreationStyle: String, Codable, Hashable, Sendable {
    case processStart
    case sessionName
    case unavailable
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
    public var fastMode: FastModeApplyStyle
    /// Ordered modes for the composer control. Empty hides the control entirely.
    public var modes: [AgentMode]
    /// Which axis the composer ladder drives.
    public var ladder: AgentLadder
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
    public var idleThreadCreation: IdleThreadCreationStyle

    /// Kept as the product-level gate used by existing call sites. A true value means the control
    /// plane has a prompt-free materialization sequence, not necessarily that process launch by
    /// itself writes the transcript.
    public var persistsSessionBeforeFirstPrompt: Bool { idleThreadCreation != .unavailable }

    public init(
        modelSelection: ModelSelectionStyle,
        thinking: ThinkingApplyStyle,
        fastMode: FastModeApplyStyle,
        modes: [AgentMode],
        ladder: AgentLadder = .modes,
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
        supportsActivityExtension: Bool,
        idleThreadCreation: IdleThreadCreationStyle
    ) {
        self.modelSelection = modelSelection
        self.thinking = thinking
        self.fastMode = fastMode
        self.modes = modes
        self.ladder = ladder
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
        self.idleThreadCreation = idleThreadCreation
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
                fastMode: .extensionCommand,
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
                supportsActivityExtension: true,
                idleThreadCreation: .processStart
            )
        case .codex:
            AgentCapabilities(
                modelSelection: .queried,
                thinking: .nextTurn,
                fastMode: .threadSetting,
                modes: Self.codexModes,
                ladder: .models,
                modeControlTitle: "Model",
                canCompact: true,
                canFork: true,
                canExportHTML: false,
                canRenameSession: true,
                canSteerMidTurn: true,
                reportsUsage: true,
                listsCommands: true,
                requestsToolPermission: true,
                reportsPlan: true,
                supportsActivityExtension: false,
                idleThreadCreation: .sessionName
            )
        case .claude:
            AgentCapabilities(
                modelSelection: .aliases,
                thinking: .relaunch,
                fastMode: .relaunch,
                modes: Self.claudeModes,
                ladder: .models,
                modeControlTitle: "Model",
                canCompact: true,
                canFork: false,
                canExportHTML: false,
                canRenameSession: true,
                canSteerMidTurn: true,
                reportsUsage: true,
                listsCommands: true,
                requestsToolPermission: true,
                reportsPlan: true,
                supportsActivityExtension: false,
                idleThreadCreation: .unavailable
            )
        }
    }
}

/// Every reasoning level any supported agent can report, weakest first.
///
/// This lives beside the adapters rather than in the app's picker: an adapter has to emit levels
/// from this list or they are filtered out of every UI that shows them, so the list and the code
/// that produces it belong in one place.
public enum AgentThinkingLevels {
    public static let all = ["off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// Narrows an agent's reported levels to the ones this build understands, preserving the
    /// canonical weak-to-strong order. An empty result degrades to "off" rather than to nothing.
    public static func supported(_ reported: [String]) -> [String] {
        let known = all.filter { reported.contains($0) }
        return known.isEmpty ? ["off"] : known
    }
}

/// How each agent names the tools that can open a pull request, and where the command text
/// lives in their arguments.
///
/// This exists because pull-request detection used to match one hardcoded shape — a tool called
/// `bash` with a `command` argument. Pi and Claude Code happen to fit it; Codex calls its shell
/// `exec_command` with a `cmd` argument, wraps shell calls inside a `exec` script, and can also
/// open a pull request through an MCP tool that never touches a shell at all. Every Codex pull
/// request was therefore invisible: no toolbar link, no Open PRs bucket, no review watching.
public struct AgentToolShapes: Sendable {
    /// Tools that run a shell command, lowercased.
    public let shellToolNames: Set<String>
    /// Tools whose invocation *is* a pull request, whatever their arguments say.
    public let pullRequestToolNames: Set<String>
    /// True when a shell tool's argument can be a *program* that calls the shell, rather than a
    /// shell command itself. Shell quoting rules do not apply inside one, so a command there is
    /// matched literally. A false positive is harmless: a link is only adopted if the call's
    /// result actually contains one.
    public let allowsScriptedCommands: Bool

    public init(
        shellToolNames: Set<String>,
        pullRequestToolNames: Set<String>,
        allowsScriptedCommands: Bool = false
    ) {
        self.shellToolNames = shellToolNames
        self.pullRequestToolNames = pullRequestToolNames
        self.allowsScriptedCommands = allowsScriptedCommands
    }

    public func isShellTool(_ name: String) -> Bool { shellToolNames.contains(name.lowercased()) }

    /// MCP tool names arrive namespaced and vary by server, so this matches on the suffix.
    public func opensPullRequest(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return pullRequestToolNames.contains { lowered == $0 || lowered.hasSuffix($0) }
    }
}

public extension AgentKind {
    var toolShapes: AgentToolShapes {
        switch self {
        case .pi:
            AgentToolShapes(shellToolNames: ["bash"], pullRequestToolNames: [])
        case .codex:
            AgentToolShapes(
                // `exec` runs a script that calls `exec_command`, so the command text is nested
                // rather than a top-level argument; both are scanned the same way.
                shellToolNames: ["exec", "exec_command", "shell", "local_shell", "run"],
                pullRequestToolNames: ["_create_pull_request", "create_pull_request"],
                allowsScriptedCommands: true
            )
        case .claude:
            AgentToolShapes(shellToolNames: ["bash"], pullRequestToolNames: ["create_pull_request"])
        }
    }
}
