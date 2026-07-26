import XCTest
@testable import PiDeskDaemon

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
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}
