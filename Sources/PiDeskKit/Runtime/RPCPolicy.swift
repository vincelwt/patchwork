import Foundation

/// Timeout policy per RPC command.
///
/// Safe state queries can be failed authoritatively when Pi does not answer. Commands that
/// may already have taken effect (prompt/steer/follow_up, compaction, renames, mode changes)
/// must never be reported as a rejection, because the caller would then roll back or resubmit
/// and Pi would receive the prompt twice.
public enum RPCTimeoutPolicy {
    public enum Outcome: Equatable {
        /// Pi did not answer and definitely did nothing: safe to surface as a failure.
        case authoritativeFailure(after: TimeInterval)
        /// Pi did not answer but the command may have been applied: surface as unknown.
        case outcomeUnknown(after: TimeInterval)
    }

    public static let stateQueryTimeout: TimeInterval = 30
    /// Compaction legitimately exceeds 30s, so its acceptance window is much wider.
    public static let compactionTimeout: TimeInterval = 900
    public static let sideEffectTimeout: TimeInterval = 300

    /// Read-only commands with no side effects.
    public static let stateQueries: Set<String> = [
        "get_state",
        "get_session_stats",
        "get_fork_messages",
        "get_entries",
        "get_commands"
    ]

    public static func outcome(for command: String) -> Outcome {
        if stateQueries.contains(command) { return .authoritativeFailure(after: stateQueryTimeout) }
        if command == "compact" { return .outcomeUnknown(after: compactionTimeout) }
        return .outcomeUnknown(after: sideEffectTimeout)
    }

    public static func error(for command: String) -> AgentRuntimeError {
        switch outcome(for: command) {
        case let .authoritativeFailure(after): return .timedOut(command, seconds: after)
        case .outcomeUnknown: return .outcomeUnknown(command)
        }
    }

    public static func delay(for command: String) -> TimeInterval {
        switch outcome(for: command) {
        case let .authoritativeFailure(after): return after
        case let .outcomeUnknown(after): return after
        }
    }
}

/// Classifies RPC failures so the store can tell "Pi refused" from "Pi never confirmed".
public enum RPCFailureHandling {
    /// True when the command may still have been applied, so callers must not roll back
    /// drafts, remove optimistic messages, or resubmit.
    public static func isOutcomeUnknown(_ error: Error) -> Bool {
        if case AgentRuntimeError.outcomeUnknown = error { return true }
        return false
    }
}

/// A monotonic runtime generation token. Every pending response and every event callback
/// captures the token that was live when it was created, so a stopped runtime can never
/// publish into its replacement even if its callback was already queued to main.
public final class RuntimeGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    public let sequence: Int

    public init(sequence: Int) { self.sequence = sequence }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidated
    }

    public func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }
}

/// Generation-scoped pending-response registry.
///
/// Extracted from `AgentRuntimeClient` so the race that matters (a late response or a queued
/// callback from a stopped runtime landing in its replacement) is deterministically testable
/// without spawning a process.
public final class RPCPendingRegistry {
    public typealias Callback = (Result<PiJSONValue, Error>) -> Void

    private struct Entry {
        let generation: RuntimeGeneration
        let command: String
        let callback: Callback
    }

    private var entries: [String: Entry] = [:]

    public func register(id: String, command: String, generation: RuntimeGeneration, callback: @escaping Callback) {
        entries[id] = Entry(generation: generation, command: command, callback: callback)
    }

    public var count: Int { entries.count }

    public func contains(id: String) -> Bool { entries[id] != nil }

    /// Removes a pending entry for delivery of a *successful* response. Returns nil when the
    /// entry is unknown or belongs to a superseded generation, in which case the response is
    /// dropped instead of published.
    public func takeForDelivery(id: String, currentGeneration: RuntimeGeneration) -> Callback? {
        guard let entry = entries[id] else { return nil }
        guard entry.generation === currentGeneration, entry.generation.isValid else {
            entries.removeValue(forKey: id)
            return nil
        }
        entries.removeValue(forKey: id)
        return entry.callback
    }

    /// Removes an entry for timeout handling only if it still belongs to the given generation.
    public func takeForTimeout(id: String, generation: RuntimeGeneration) -> Callback? {
        guard let entry = entries[id], entry.generation === generation else { return nil }
        entries.removeValue(forKey: id)
        return entry.callback
    }

    public func remove(id: String) -> Callback? {
        entries.removeValue(forKey: id)?.callback
    }

    /// Drains every pending callback paired with the command it was registered for, so a caller
    /// rejecting them all (a stop or a crash) can classify each one instead of reporting every
    /// in-flight command with the same blunt error. Terminal rejections are always delivered so
    /// callers complete exactly once, even for a generation that has just been retired.
    public func drainAll() -> [(command: String, callback: Callback)] {
        let drained = entries.values.map { (command: $0.command, callback: $0.callback) }
        entries.removeAll()
        return drained
    }
}

/// Terminates and reaps a replaced Pi process off the main thread with a short graceful
/// deadline before escalating to SIGKILL, so runtimes never overlap or leak as zombies.
public enum PiProcessReaper {
    public static let queue = DispatchQueue(label: "dev.pi.desktop.reaper", qos: .utility)
    public static let gracefulDeadline: TimeInterval = 2.0

    /// `terminate()` is sent synchronously by the caller (already off main) so the old
    /// runtime is signalled before a replacement is spawned; waiting/escalation is handed
    /// to the reaper queue.
    public static func reap(
        _ process: Process,
        gracefulDeadline: TimeInterval = PiProcessReaper.gracefulDeadline,
        completion: (() -> Void)? = nil
    ) {
        guard process.isRunning else {
            completion?()
            return
        }
        process.terminate()
        queue.async {
            let deadline = Date().addingTimeInterval(gracefulDeadline)
            while process.isRunning, Date() < deadline {
                usleep(40_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            completion?()
        }
    }
}
