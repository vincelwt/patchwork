import Foundation
import PatchworkKit

/// Enforces `timeoutSeconds` uniformly for every executor, real or fake: races `execute(job)`
/// against a timer. If the timer wins, the execution task is cancelled \u2014 a cooperative
/// executor (both `PiProcessRunExecutor` and any well-behaved test fake) notices
/// `Task.isCancelled` within a few seconds and unwinds; structured concurrency then waits for
/// that unwind before this function returns, so a run's process/resources are never left
/// dangling after `run(_:)` completes.
struct RunManager: Sendable {
    let executor: RunExecuting

    func run(_ job: RunJob) async -> RunOutcome {
        await withTaskGroup(of: RunOutcome?.self) { group in
            group.addTask { await executor.execute(job) }
            group.addTask {
                let seconds = max(1, job.timeoutSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return nil // sentinel: the deadline won the race
            }
            defer { group.cancelAll() }

            guard let first = await group.next() else {
                return .failed("The run produced no outcome.")
            }
            if let outcome = first { return outcome }
            // If the scheduler's durable occurrence still says prompt delivery never began,
            // this is definite non-delivery and may be retried. Dispatching/accepted state always
            // wins over this hint and suppresses a resend.
            return RunOutcome(
                status: .timeout, error: "Run exceeded its \(job.timeoutSeconds)s timeout.",
                summary: nil, retryable: true
            )
        }
    }
}
