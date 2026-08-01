import XCTest
@testable import PatchworkDaemon

final class RunManagerTests: XCTestCase {
    private func job(timeoutSeconds: Int) -> RunJob {
        RunJob(id: "run_x", scheduleId: nil, trigger: .manual, target: .newThread(cwd: "/tmp", namePattern: nil), prompt: "hi", mode: nil, timeoutSeconds: timeoutSeconds, queuedAt: Date())
    }

    func testFastSuccessReturnsWithoutWaitingForTheTimeout() async {
        let executor = FakeRunExecutor { _ in RunOutcome(status: .ok, error: nil, summary: "quick") }
        let manager = RunManager(executor: executor)
        let start = Date()
        let outcome = await manager.run(job(timeoutSeconds: 30))
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testHangingExecutorIsCutOffAtTheTimeout() async {
        let executor = FakeRunExecutor(behavior: FakeRunExecutor.hanging())
        let manager = RunManager(executor: executor)
        let start = Date()
        let outcome = await manager.run(job(timeoutSeconds: 1))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome.status, .timeout)
        XCTAssertNotNil(outcome.error)
        // Bounded well above the 1s deadline (cooperative shutdown + scheduling slack) but far
        // below "actually hung".
        XCTAssertLessThan(elapsed, 10)
    }

    func testCancellationActuallyReachesTheExecutor() async {
        let sawCancellation = Flag()
        let executor = FakeRunExecutor { _ in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await sawCancellation.set()
            return RunOutcome(status: .timeout, error: "cancelled", summary: nil)
        }
        let manager = RunManager(executor: executor)
        _ = await manager.run(job(timeoutSeconds: 1))
        let observed = await sawCancellation.value
        XCTAssertTrue(observed, "the executor must observe Task.isCancelled once the deadline wins the race")
    }

    func testTimeoutPreservesAnAcceptedPromptBoundaryAndSuppressesRetry() async {
        let started = Date(timeIntervalSince1970: 100)
        let accepted = Date(timeIntervalSince1970: 101)
        let executor = FakeRunExecutor { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return RunOutcome(
                status: .interrupted, error: "cancelled", summary: "partial answer",
                resolvedThreadId: "thread-1", resolvedThreadPath: "/tmp/thread-1.jsonl",
                retryable: true, promptStartedAt: started, promptAcceptedAt: accepted
            )
        }

        let outcome = await RunManager(executor: executor).run(job(timeoutSeconds: 1))

        XCTAssertEqual(outcome.status, .timeout)
        XCTAssertEqual(outcome.summary, "partial answer")
        XCTAssertEqual(outcome.resolvedThreadId, "thread-1")
        XCTAssertEqual(outcome.resolvedThreadPath, "/tmp/thread-1.jsonl")
        XCTAssertEqual(outcome.promptStartedAt, started)
        XCTAssertEqual(outcome.promptAcceptedAt, accepted)
        XCTAssertFalse(outcome.retryable)
    }

    func testTimeoutKeepsRetryableOnlyWhenPromptDeliveryNeverStarted() async {
        let executor = FakeRunExecutor { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return RunOutcome(
                status: .interrupted, error: "cancelled", summary: nil,
                resolvedThreadId: "thread-2", retryable: true
            )
        }

        let outcome = await RunManager(executor: executor).run(job(timeoutSeconds: 1))

        XCTAssertEqual(outcome.status, .timeout)
        XCTAssertTrue(outcome.retryable)
        XCTAssertNil(outcome.promptStartedAt)
        XCTAssertEqual(outcome.resolvedThreadId, "thread-2")
    }

    func testTimeoutIsPerJobNotGlobal() async {
        let executor = FakeRunExecutor { job in
            RunOutcome(status: .ok, error: nil, summary: "\(job.timeoutSeconds)")
        }
        let manager = RunManager(executor: executor)
        let short = await manager.run(job(timeoutSeconds: 1))
        let long = await manager.run(job(timeoutSeconds: 60))
        XCTAssertEqual(short.summary, "1")
        XCTAssertEqual(long.summary, "60")
    }

    func testCorruptTimeoutValuesAreBoundedBeforeExecutionWithoutOverflow() async {
        let executor = FakeRunExecutor { job in
            RunOutcome(status: .ok, error: nil, summary: "\(job.timeoutSeconds)")
        }
        let manager = RunManager(executor: executor)

        let oversized = await manager.run(job(timeoutSeconds: .max))
        let negative = await manager.run(job(timeoutSeconds: .min))

        XCTAssertEqual(oversized.summary, "\(ScheduleEngine.maximumTimeoutSeconds)")
        XCTAssertEqual(negative.summary, "1")
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}
