/// The one seam between the scheduler/queue and an actual Pi process. Production wiring uses
/// `PiProcessRunExecutor`; every test uses a fake conforming type instead, so scheduling,
/// queueing, timeout, and status-recording behaviour can be exercised without ever spawning
/// `pi` or sending a provider prompt \u2014 the hard rule this whole subsystem is built around.
protocol RunExecuting: Sendable {
    /// Executes one run to completion and reports its outcome. Must observe `Task.isCancelled`
    /// promptly (at least every few seconds) so `RunManager`'s timeout race can actually stop a
    /// hung run instead of waiting the full process lifetime.
    func execute(_ job: RunJob) async -> RunOutcome
}
