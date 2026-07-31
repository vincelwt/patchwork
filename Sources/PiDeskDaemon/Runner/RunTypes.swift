import Foundation
import PiDeskKit

enum RunnerError: Error, LocalizedError, Sendable {
    case agentNotFound(AgentKind)
    /// The daemon can read this agent's threads but cannot drive its runtime yet. Said out loud
    /// rather than silently launching `pi` against someone else's transcript.
    case agentNotExecutable(AgentKind)
    /// The agent is driveable, but has no equivalent for this particular command.
    case unsupportedCommand(agent: AgentKind, what: String)
    case timedOut(afterSeconds: TimeInterval)
    case processExited(String)
    case ioFailure(String)

    static let piNotFound = RunnerError.agentNotFound(.pi)

    var errorDescription: String? {
        switch self {
        case let .agentNotFound(agent):
            let descriptor = AgentCatalog.descriptor(for: agent)
            return "\(agent.displayName) was not found. Set \(descriptor.executableOverrideKey) or install \(descriptor.executableNames[0]) in ~/.local/bin."
        case let .agentNotExecutable(agent):
            return "Pi Desktop's background service cannot run \(agent.displayName) threads yet; open this thread in the Mac app."
        case let .unsupportedCommand(agent, what):
            return "\(agent.displayName) does not support \(what)."
        case let .timedOut(seconds): return "Pi did not respond within \(Int(seconds))s."
        case let .processExited(detail): return detail.isEmpty ? "Pi exited unexpectedly." : "Pi exited: \(detail)"
        case let .ioFailure(detail): return detail
        }
    }

    /// Safe to retry only before prompt delivery begins. A missing or undrivable agent is
    /// configuration, not a temporary outage; process/pipe failures are definite non-delivery at
    /// that stage.
    var retryableBeforePrompt: Bool {
        switch self {
        case .timedOut, .processExited, .ioFailure: true
        case .agentNotFound, .agentNotExecutable, .unsupportedCommand: false
        }
    }
}

/// Where a run's prompt goes. `newThread` has no identity until Pi creates the session, so it
/// never collides with anything for concurrency/skip-if-running purposes.
enum RunTarget: Sendable, Equatable {
    case existingThread(threadId: String, path: String, cwd: String, agent: AgentKind = .pi)
    case newThread(cwd: String, namePattern: String?, agent: AgentKind = .pi)

    var existingThreadID: String? {
        if case let .existingThread(threadId, _, _, _) = self { return threadId }
        return nil
    }

    var cwd: String {
        switch self {
        case let .existingThread(_, _, cwd, _): cwd
        case let .newThread(cwd, _, _): cwd
        }
    }

    var agent: AgentKind {
        switch self {
        case let .existingThread(_, _, _, agent): agent
        case let .newThread(_, _, agent): agent
        }
    }

    /// Mutual-exclusion key for `RunQueue`. Agent-qualified so two agents that ever mint the same
    /// session id cannot block each other's runs.
    var exclusionKey: String? {
        existingThreadID.map { RunTarget.exclusionKey(agent: agent, threadID: $0) }
    }

    static func exclusionKey(agent: AgentKind, threadID: String) -> String {
        "\(agent.rawValue):\(threadID)"
    }

    /// The bare thread id inside an exclusion key, for callers that compare against thread ids.
    static func threadID(inExclusionKey key: String) -> String {
        key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? key
    }
}

/// One unit of work for the runner: fully resolved, so `RunExecuting` never has to look anything
/// up (no schedule/thread-store access) \u2014 the only thing a fake test executor needs is this
/// struct.
enum PromptDispatchPreparation: Sendable {
    case ready
    case retry
    case cancelled
}

struct RunJob: Sendable {
    var id: String
    var scheduleId: String?
    var occurrenceId: String?
    var scheduledAt: Date?
    var attempt: Int
    var trigger: RunTrigger
    var target: RunTarget
    var prompt: String
    var mode: String?
    var timeoutSeconds: Int
    var queuedAt: Date
    var onPromptDispatch: (@Sendable (Date) async -> PromptDispatchPreparation)?
    var onPromptAccepted: (@Sendable (Date) async -> Void)?
    var onCompletion: (@Sendable (RunOutcome) async -> Void)?

    init(
        id: String, scheduleId: String?, occurrenceId: String? = nil,
        scheduledAt: Date? = nil, attempt: Int = 1, trigger: RunTrigger,
        target: RunTarget, prompt: String, mode: String?, timeoutSeconds: Int,
        queuedAt: Date, onPromptDispatch: (@Sendable (Date) async -> PromptDispatchPreparation)? = nil,
        onPromptAccepted: (@Sendable (Date) async -> Void)? = nil,
        onCompletion: (@Sendable (RunOutcome) async -> Void)? = nil
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.occurrenceId = occurrenceId
        self.scheduledAt = scheduledAt
        self.attempt = attempt
        self.trigger = trigger
        self.target = target
        self.prompt = prompt
        self.mode = mode
        self.timeoutSeconds = timeoutSeconds
        self.queuedAt = queuedAt
        self.onPromptDispatch = onPromptDispatch
        self.onPromptAccepted = onPromptAccepted
        self.onCompletion = onCompletion
    }
}

struct RunOutcome: Sendable {
    var status: RunStatus
    var error: String?
    var summary: String?
    /// For a `newThread` target, the session Pi actually created.
    var resolvedThreadId: String?
    var resolvedThreadPath: String?
    var retryable: Bool
    var promptStartedAt: Date?
    var promptAcceptedAt: Date?

    init(
        status: RunStatus, error: String?, summary: String?,
        resolvedThreadId: String? = nil, resolvedThreadPath: String? = nil,
        retryable: Bool = false, promptStartedAt: Date? = nil,
        promptAcceptedAt: Date? = nil
    ) {
        self.status = status
        self.error = error
        self.summary = summary
        self.resolvedThreadId = resolvedThreadId
        self.resolvedThreadPath = resolvedThreadPath
        self.retryable = retryable
        self.promptStartedAt = promptStartedAt
        self.promptAcceptedAt = promptAcceptedAt
    }

    static func failed(_ message: String, retryable: Bool = false) -> RunOutcome {
        RunOutcome(status: .failed, error: message, summary: nil, retryable: retryable)
    }
}
