import Foundation
import PiDeskKit

enum RunnerError: Error, LocalizedError, Sendable {
    case piNotFound
    case timedOut(afterSeconds: TimeInterval)
    case processExited(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .piNotFound: "Pi CLI was not found. Set PI_DESKTOP_PI_PATH or install pi in ~/.local/bin."
        case let .timedOut(seconds): "Pi did not respond within \(Int(seconds))s."
        case let .processExited(detail): detail.isEmpty ? "Pi exited unexpectedly." : "Pi exited: \(detail)"
        case let .ioFailure(detail): detail
        }
    }

    /// Safe to retry only before prompt delivery begins. Missing Pi is configuration, not a
    /// temporary outage; process/pipe failures are definite non-delivery at that stage.
    var retryableBeforePrompt: Bool {
        switch self {
        case .timedOut, .processExited, .ioFailure: true
        case .piNotFound: false
        }
    }
}

/// Where a run's prompt goes. `newThread` has no identity until Pi creates the session, so it
/// never collides with anything for concurrency/skip-if-running purposes.
enum RunTarget: Sendable, Equatable {
    case existingThread(threadId: String, path: String, cwd: String)
    case newThread(cwd: String, namePattern: String?)

    var existingThreadID: String? {
        if case let .existingThread(threadId, _, _) = self { return threadId }
        return nil
    }

    var cwd: String {
        switch self {
        case let .existingThread(_, _, cwd): cwd
        case let .newThread(cwd, _): cwd
        }
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
