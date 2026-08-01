import Foundation
import PatchworkKit

/// Durable identity for one physical transcript. Session ids are not unique after a history is
/// copied, while the standardized file path is already the storage and archive identity.
struct ThreadInstanceKey: Hashable, Sendable {
    let path: String

    init(path: String) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

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
            return "Patchwork's background service cannot run \(agent.displayName) threads yet; open this thread in the Mac app."
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

    var existingThreadPath: String? {
        if case let .existingThread(_, path, _, _) = self { return path }
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

    /// Mutual-exclusion identity for `RunQueue`, leases, and runtime reservations. Public session
    /// ids can be duplicated by copying a history; the physical transcript path cannot.
    var threadInstanceKey: ThreadInstanceKey? {
        existingThreadPath.map(ThreadInstanceKey.init(path:))
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
    /// A preallocated identity for agents that can create or resume an exact fresh session.
    var initialSessionID: String?
    /// A durable fail-closed barrier immediately before the executor may spawn an agent.
    var onExecutionStart: (@Sendable () async -> PromptDispatchPreparation)?
    var onPromptDispatch: (@Sendable (Date) async -> PromptDispatchPreparation)?
    var onPromptAccepted: (@Sendable (Date) async -> Void)?
    /// Called as soon as a fresh runtime reports the path it will own. The file may not exist yet;
    /// this early identity is only for queue mutual exclusion and must never be published.
    var onThreadIdentityResolved: (@Sendable (_ threadID: String, _ path: String) async -> Bool)?
    /// Called once a fresh-session prompt is accepted and the agent has reported the physical
    /// transcript identity. This is a persisted/publication boundary, not queue ownership: the
    /// earlier identity callback already bound the predicted path before prompt delivery.
    var onThreadReady: (@Sendable (_ threadID: String, _ path: String) async -> Void)?
    var onCompletion: (@Sendable (RunOutcome) async -> Void)?

    init(
        id: String, scheduleId: String?, occurrenceId: String? = nil,
        scheduledAt: Date? = nil, attempt: Int = 1, trigger: RunTrigger,
        target: RunTarget, prompt: String, mode: String?, timeoutSeconds: Int,
        queuedAt: Date, initialSessionID: String? = nil,
        onExecutionStart: (@Sendable () async -> PromptDispatchPreparation)? = nil,
        onPromptDispatch: (@Sendable (Date) async -> PromptDispatchPreparation)? = nil,
        onPromptAccepted: (@Sendable (Date) async -> Void)? = nil,
        onThreadIdentityResolved: (@Sendable (_ threadID: String, _ path: String) async -> Bool)? = nil,
        onThreadReady: (@Sendable (_ threadID: String, _ path: String) async -> Void)? = nil,
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
        self.initialSessionID = initialSessionID
        self.onExecutionStart = onExecutionStart
        self.onPromptDispatch = onPromptDispatch
        self.onPromptAccepted = onPromptAccepted
        self.onThreadIdentityResolved = onThreadIdentityResolved
        self.onThreadReady = onThreadReady
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
    /// Set by RunQueue after the terminal snapshot append. A scheduled occurrence cannot settle
    /// until this is true, otherwise a storage outage would erase its only durable run result.
    var terminalRecordPersisted: Bool

    init(
        status: RunStatus, error: String?, summary: String?,
        resolvedThreadId: String? = nil, resolvedThreadPath: String? = nil,
        retryable: Bool = false, promptStartedAt: Date? = nil,
        promptAcceptedAt: Date? = nil, terminalRecordPersisted: Bool = true
    ) {
        self.status = status
        self.error = error
        self.summary = summary
        self.resolvedThreadId = resolvedThreadId
        self.resolvedThreadPath = resolvedThreadPath
        self.retryable = retryable
        self.promptStartedAt = promptStartedAt
        self.promptAcceptedAt = promptAcceptedAt
        self.terminalRecordPersisted = terminalRecordPersisted
    }

    static func failed(_ message: String, retryable: Bool = false) -> RunOutcome {
        RunOutcome(status: .failed, error: message, summary: nil, retryable: retryable)
    }
}
