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
struct RunJob: Sendable {
    var id: String
    var scheduleId: String?
    var trigger: RunTrigger
    var target: RunTarget
    var prompt: String
    var mode: String?
    var timeoutSeconds: Int
    var queuedAt: Date
}

struct RunOutcome: Sendable {
    var status: RunStatus
    var error: String?
    var summary: String?
    /// For a `newThread` target, the session Pi actually created.
    var resolvedThreadId: String?
    var resolvedThreadPath: String?

    static func failed(_ message: String) -> RunOutcome { RunOutcome(status: .failed, error: message, summary: nil) }
}
