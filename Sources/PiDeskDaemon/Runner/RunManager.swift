import Foundation
import PiDeskKit

/// Enforces `timeoutSeconds` uniformly for every executor, real or fake: races `execute(job)`
/// against a timer. If the timer wins, the execution task is cancelled \u2014 a cooperative
/// executor (both `PiProcessRunExecutor` and any well-behaved test fake) notices
/// `Task.isCancelled` within a few seconds and unwinds; structured concurrency then waits for
/// that unwind before this function returns, so a run's process/resources are never left
/// dangling after `run(_:)` completes.
struct RunManager: Sendable {
    let executor: RunExecuting

    func run(_ job: RunJob) async -> RunOutcome {
        var boundedJob = job
        boundedJob.timeoutSeconds = ScheduleEngine.boundedTimeoutSeconds(job.timeoutSeconds)
        let timeoutSeconds = boundedJob.timeoutSeconds
        return await withTaskGroup(of: RunOutcome?.self) { group in
            group.addTask { await executor.execute(boundedJob) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                return nil // sentinel: the deadline won the race
            }
            defer { group.cancelAll() }

            guard let first = await group.next() else {
                return .failed("The run produced no outcome.")
            }
            if let outcome = first { return outcome }
            group.cancelAll()
            var cancelledOutcome: RunOutcome?
            while let next = await group.next() {
                if let next {
                    cancelledOutcome = next
                    break
                }
            }
            // The executor owns the delivery boundary. Preserve what it learned while unwinding
            // so a timeout after dispatch can never masquerade as a definitely unsent prompt.
            let resolved = cancelledOutcome
            return RunOutcome(
                status: .timeout, error: "Run exceeded its \(timeoutSeconds)s timeout.",
                summary: resolved?.summary,
                resolvedThreadId: resolved?.resolvedThreadId,
                resolvedThreadPath: resolved?.resolvedThreadPath,
                retryable: resolved?.retryable == true && resolved?.promptStartedAt == nil,
                promptStartedAt: resolved?.promptStartedAt,
                promptAcceptedAt: resolved?.promptAcceptedAt
            )
        }
    }
}
