import XCTest
import PatchworkKit
@testable import PatchworkDaemon

final class ResilientSchedulerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func schedule(
        id: String, due: Date, trigger: ScheduleTrigger = .interval(everySeconds: 60, startAt: nil),
        target: ScheduleTarget
    ) -> Schedule {
        Schedule(
            id: id, name: id, target: target, prompt: "work", trigger: trigger,
            policy: SchedulePolicy(catchUpMissed: false),
            createdAt: due.addingTimeInterval(-60), updatedAt: due.addingTimeInterval(-60),
            nextRunAt: due
        )
    }

    private func poll(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testOverdueAutomationsPersistBeforeRunningAndExecuteOldestFirstWithoutDuplicates() async throws {
        let now = Date()
        _ = TestSupport.writeSessionFile(in: directory, id: "old-thread", cwd: directory.path)
        _ = TestSupport.writeSessionFile(in: directory, id: "new-thread", cwd: directory.path)
        let gate = Gate()
        let persistenceObserved = LockedFlag()
        let schedulesURL = directory.appendingPathComponent("schedules.json")
        let executor = FakeRunExecutor { _ in
            if let data = FileManager.default.contents(atPath: schedulesURL.path),
               let schedules = try? PatchworkJSON.decoder.decode([Schedule].self, from: data),
               schedules.count == 2, schedules.allSatisfy({ $0.pendingOccurrence != nil }) {
                persistenceObserved.set()
            }
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor, concurrency: 1)
        try await core.scheduleStore.upsert(schedule(
            id: "newer", due: now.addingTimeInterval(-60),
            target: .existingThread(threadId: "new-thread")
        ))
        try await core.scheduleStore.upsert(schedule(
            id: "older", due: now.addingTimeInterval(-3_600),
            target: .existingThread(threadId: "old-thread")
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 2)
        let firstStarted = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(firstStarted)
        let persistedBeforeExecution = await poll { persistenceObserved.value }
        XCTAssertTrue(persistedBeforeExecution)
        let duplicate = await core.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(duplicate, 0, "one pending occurrence prevents a duplicate")

        await gate.release()
        let bothStarted = await poll { executor.executedJobs.count == 2 }
        XCTAssertTrue(bothStarted)
        XCTAssertEqual(executor.executedJobs.compactMap(\.scheduleId), ["older", "newer"])
        let bothFinished = await poll {
            let schedules = await core.scheduleStore.all()
            return schedules.allSatisfy { $0.pendingOccurrence == nil && ($0.nextRunAt ?? .distantPast) > now }
        }
        XCTAssertTrue(bothFinished)
    }

    func testNewThreadOccurrencePublishesAndRecordsItsMaterializedTranscript() async throws {
        let now = Date()
        let threadID = "scheduled-created"
        let root = try XCTUnwrap(directory)
        let transcript = directory.appendingPathComponent("sessions/\(threadID).jsonl")
        let callbackObservedPublication = LockedFlag()
        let executor = FakeRunExecutor { job in
            let writer = Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return TestSupport.writeSessionFile(
                    in: root, id: threadID, cwd: root.path,
                    lines: [#"{"type":"message","id":"user","role":"user","content":[{"type":"text","text":"work"}]}"#]
                )
            }
            await job.onThreadReady?(threadID, transcript.path)
            let overlay = DaemonWorktreeProjects.loadSnapshot(
                from: root.appendingPathComponent("overlay.json")
            )
            if overlay.managedThreadPaths.contains(transcript.path) {
                callbackObservedPublication.set()
            }
            _ = await writer.value
            return RunOutcome(
                status: .ok, error: nil, summary: "done",
                resolvedThreadId: threadID, resolvedThreadPath: transcript.path,
                promptStartedAt: now, promptAcceptedAt: now
            )
        }
        let core = TestSupport.makeCore(in: directory, executor: executor)
        let publications = LockedThreadPublications()
        let published = expectation(description: "new scheduled thread published")
        published.assertForOverFulfill = true
        _ = core.bus.subscribe { name, data in
            guard name == "thread",
                  let thread = try? PatchworkJSON.decoder.decode(PatchworkThread.self, from: data),
                  thread.id == threadID else { return }
            publications.append(thread)
            published.fulfill()
        }
        try await core.scheduleStore.upsert(schedule(
            id: "new-thread", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: "Scheduled {date}")
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(
            callbackObservedPublication.value,
            "onThreadReady must not return before the transcript is managed and published"
        )
        let presented = await core.threadStore.thread(idOrPath: transcript.path)
        XCTAssertEqual(presented?.id, threadID)
        let overlay = DaemonWorktreeProjects.loadSnapshot(
            from: directory.appendingPathComponent("overlay.json")
        )
        XCTAssertTrue(overlay.managedThreadPaths.contains(transcript.path))
        let settled = await poll {
            await core.scheduleStore.get(id: "new-thread")?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        let idleAfterCompletion = await core.threadStore.thread(idOrPath: transcript.path)
        XCTAssertEqual(idleAfterCompletion?.running, false)
        XCTAssertEqual(publications.values.count, 1, "completion recovery must not republish a successful ready callback")
    }

    func testAcceptedReadyPublicationFailureRecoversExactlyOnceAtCompletion() async throws {
        let now = Date()
        let root = try XCTUnwrap(directory)
        let threadID = "ready-recovery"
        let transcript = root.appendingPathComponent("sessions/\(threadID).jsonl")
        let executor = FakeRunExecutor { job in
            let cancelledReady = Task {
                await job.onThreadReady?(threadID, transcript.path)
            }
            cancelledReady.cancel()
            await cancelledReady.value
            _ = TestSupport.writeSessionFile(
                in: root, id: threadID, cwd: root.path,
                lines: [#"{"type":"message","id":"user","role":"user","content":[{"type":"text","text":"work"}]}"#]
            )
            return RunOutcome(
                status: .ok, error: nil, summary: "done",
                resolvedThreadId: threadID, resolvedThreadPath: transcript.path,
                promptStartedAt: now, promptAcceptedAt: now
            )
        }
        let core = TestSupport.makeCore(in: root, executor: executor)
        let publications = LockedThreadPublications()
        let published = expectation(description: "completion recovered created thread")
        published.assertForOverFulfill = true
        _ = core.bus.subscribe { name, data in
            guard name == "thread",
                  let thread = try? PatchworkJSON.decoder.decode(PatchworkThread.self, from: data),
                  thread.id == threadID else { return }
            publications.append(thread)
            published.fulfill()
        }
        try await core.scheduleStore.upsert(schedule(
            id: "ready-recovery", due: now.addingTimeInterval(-60),
            trigger: .once(at: now.addingTimeInterval(-60)),
            target: .newThread(cwd: root.path, namePattern: nil)
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        await fulfillment(of: [published], timeout: 2)
        let settled = await poll {
            await core.scheduleStore.get(id: "ready-recovery")?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(publications.values.count, 1)
        XCTAssertEqual(publications.values.first?.running, false)
    }

    func testResolvedRetryableFreshRunResumesTheSameThreadOnRetry() async throws {
        let now = Date()
        let root = try XCTUnwrap(directory)
        let executor = FakeRunExecutor { job in
            if case .newThread = job.target {
                guard let threadID = job.initialSessionID else {
                    return RunOutcome.failed("missing preallocated identity")
                }
                let transcript = root.appendingPathComponent("sessions/\(threadID).jsonl")
                _ = TestSupport.writeSessionFile(in: root, id: threadID, cwd: root.path)
                _ = await job.onThreadIdentityResolved?(threadID, transcript.path)
                return RunOutcome(
                    status: .failed, error: "temporary pre-prompt failure", summary: nil,
                    retryable: true
                )
            }
            return RunOutcome(status: .ok, error: nil, summary: "resumed")
        }
        let core = TestSupport.makeCore(
            in: root, executor: executor, schedulerRetryDelays: [0]
        )
        try await core.scheduleStore.upsert(schedule(
            id: "resolved-no-retry", due: now.addingTimeInterval(-60),
            trigger: .once(at: now.addingTimeInterval(-60)),
            target: .newThread(cwd: root.path, namePattern: nil)
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        let retryReady = await poll {
            await core.scheduleStore.get(id: "resolved-no-retry")?.pendingOccurrence?.runId == nil
        }
        XCTAssertTrue(retryReady)
        XCTAssertEqual(executor.executedJobs.count, 1)
        let retried = await core.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(retried, 1)
        let settled = await poll {
            await core.scheduleStore.get(id: "resolved-no-retry")?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.count, 2)
        let threadID = try XCTUnwrap(executor.executedJobs[0].initialSessionID)
        let transcript = root.appendingPathComponent("sessions/\(threadID).jsonl")
        guard case let .existingThread(resumedID, resumedPath, _, _) = executor.executedJobs[1].target else {
            return XCTFail("the retry must resume the first physical transcript")
        }
        XCTAssertEqual(resumedID, threadID)
        XCTAssertEqual(resumedPath, transcript.standardizedFileURL.path)
    }

    func testRestartRecoversResolvedPiFreshThreadWithoutCreatingAnother() async throws {
        try await assertRestartRecoversResolvedFreshThread(agent: .pi)
    }

    func testRestartRecoversResolvedCodexFreshThreadWithoutCreatingAnother() async throws {
        try await assertRestartRecoversResolvedFreshThread(agent: .codex)
    }

    func testFreshSchedulePersistsStartingAndPreallocatedIdentityBeforeExecutorRuns() async throws {
        let now = Date()
        let schedulesURL = directory.appendingPathComponent("schedules.json")
        let observed = LockedFlag()
        let executor = FakeRunExecutor { job in
            guard let data = FileManager.default.contents(atPath: schedulesURL.path),
                  let schedules = try? PatchworkJSON.decoder.decode([Schedule].self, from: data),
                  let occurrence = schedules.first?.pendingOccurrence,
                  occurrence.phase == .starting,
                  occurrence.threadId == job.initialSessionID,
                  occurrence.threadPath == nil,
                  job.initialSessionID.flatMap(UUID.init(uuidString:)) != nil else {
                return RunOutcome.failed("starting state was not durable")
            }
            observed.set()
            return RunOutcome(status: .ok, error: nil, summary: nil)
        }
        let core = TestSupport.makeCore(in: directory, executor: executor)
        try await core.scheduleStore.upsert(schedule(
            id: "starting-barrier", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        let didObserve = await poll { observed.value }
        XCTAssertTrue(didObserve)
        XCTAssertEqual(executor.executedJobs.count, 1)
    }

    func testRestartRetriesPiStartingOccurrenceWithTheSamePreallocatedIdentity() async throws {
        try await assertRestartRetriesReusableStartingOccurrence(agent: .pi)
    }

    func testRestartRetriesClaudePredictedPathWithTheSamePreallocatedIdentity() async throws {
        try await assertRestartRetriesReusableStartingOccurrence(agent: .claude)
    }

    private func assertRestartRetriesReusableStartingOccurrence(agent: AgentKind) async throws {
        let now = Date()
        let threadID = UUID().uuidString.lowercased()
        let runID = "run-starting-\(agent.rawValue)"
        let predictedPath = agent == .claude
            ? ClaudeProtocolAdapter.transcriptPath(
                sessionID: threadID, cwd: URL(fileURLWithPath: directory.path)
            )
            : nil
        let occurrence = ScheduleOccurrence(
            id: "occ-starting-\(agent.rawValue)", scheduledAt: now.addingTimeInterval(-60),
            phase: .starting, attemptCount: 1, notBefore: now, runId: runID,
            threadId: threadID, threadPath: predictedPath
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "starting-\(agent.rawValue)", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.agent = agent
        saved.pendingOccurrence = occurrence
        saved.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(saved)

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        let fired = await recovered.scheduler.tick(now: now)
        let afterRecovery = await recovered.scheduleStore.get(id: saved.id)
        XCTAssertEqual(fired, 1, "state after recovery: \(String(describing: afterRecovery))")
        let didExecute = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(didExecute)
        XCTAssertEqual(executor.executedJobs.first?.initialSessionID, threadID)
        XCTAssertEqual(executor.executedJobs.first?.target.agent, agent)
        let didSettle = await poll {
            await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence == nil
        }
        XCTAssertTrue(didSettle)
    }

    func testRestartRecoversOccurrenceIdentityWithoutRunHistory() async throws {
        let now = Date()
        let threadID = "occurrence-owned-identity"
        let transcript = TestSupport.writeSessionFile(
            in: directory, id: threadID, cwd: directory.path
        )
        let runID = "run-occurrence-owned"
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "occurrence-owned", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = ScheduleOccurrence(
            id: "occ-occurrence-owned", scheduledAt: now.addingTimeInterval(-60),
            phase: .starting, attemptCount: 1, notBefore: now, runId: runID,
            threadId: threadID, threadPath: transcript.path
        )
        try await writer.scheduleStore.upsert(saved)

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        let fired = await recovered.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        let settled = await poll {
            await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.count, 1)
        guard case let .existingThread(resumedID, resumedPath, _, _) = executor.executedJobs[0].target else {
            return XCTFail("restart must resume the occurrence-owned transcript")
        }
        XCTAssertEqual(resumedID, threadID)
        XCTAssertEqual(resumedPath, transcript.standardizedFileURL.path)
        let run = await recovered.runHistoryStore.get(id: runID)
        XCTAssertEqual(run?.threadId, threadID)
        XCTAssertEqual(run?.threadPath, transcript.standardizedFileURL.path)
        XCTAssertEqual(run?.status, .interrupted)
        let presented = await recovered.threadStore.thread(idOrPath: transcript.path)
        XCTAssertEqual(presented?.id, threadID)
    }

    func testMalformedMaterializedTranscriptKeepsBreadcrumbUntilReconciliation() async throws {
        let now = Date()
        let threadID = "deferred-parse"
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let transcript = sessions.appendingPathComponent("\(threadID).jsonl")
        try "{incomplete\n".write(to: transcript, atomically: true, encoding: .utf8)
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "deferred-parse", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = ScheduleOccurrence(
            id: "occ-deferred-parse", scheduledAt: now.addingTimeInterval(-60),
            phase: .starting, attemptCount: 1, notBefore: now,
            runId: "run-deferred-parse", threadId: threadID, threadPath: transcript.path
        )
        try await writer.scheduleStore.upsert(saved)

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        let first = await recovered.scheduler.tick(now: now)
        XCTAssertEqual(first, 0)
        let pending = await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence
        XCTAssertNotNil(pending)

        _ = TestSupport.writeSessionFile(in: directory, id: threadID, cwd: directory.path)
        let second = await recovered.scheduler.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(second, 1)
        let settled = await poll {
            await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.count, 1)
        let presented = await recovered.threadStore.thread(idOrPath: transcript.path)
        XCTAssertEqual(presented?.id, threadID)
    }

    func testScheduleClearWriteFailureReconcilesWithoutRepublishing() async throws {
        let now = Date()
        let threadID = "deferred-clear"
        let transcript = TestSupport.writeSessionFile(
            in: directory, id: threadID, cwd: directory.path
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "deferred-clear", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = ScheduleOccurrence(
            id: "occ-deferred-clear", scheduledAt: now.addingTimeInterval(-60),
            phase: .starting, attemptCount: 1, notBefore: now,
            runId: "run-deferred-clear", threadId: threadID, threadPath: transcript.path
        )
        try await writer.scheduleStore.upsert(saved)

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        let publications = LockedThreadPublications()
        let schedulesURL = directory.appendingPathComponent("schedules.json")
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: schedulesURL.path
            )
        }
        _ = recovered.bus.subscribe { name, data in
            guard name == "thread",
                  let thread = try? PatchworkJSON.decoder.decode(PatchworkThread.self, from: data),
                  thread.id == threadID else { return }
            publications.append(thread)
        }
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: schedulesURL.path
        )

        let first = await recovered.scheduler.tick(now: now)
        try FileManager.default.setAttributes(
            [.immutable: false], ofItemAtPath: schedulesURL.path
        )
        XCTAssertEqual(first, 0)
        let pending = await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence
        XCTAssertNotNil(pending)
        XCTAssertEqual(publications.values.count, 1)

        let second = await recovered.scheduler.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(second, 1)
        let settled = await poll {
            await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(publications.values.count, 1)
        XCTAssertEqual(executor.executedJobs.count, 1)
    }

    private func assertRestartRecoversResolvedFreshThread(agent: AgentKind) async throws {
        let now = Date()
        let root = try XCTUnwrap(directory)
        let threadID = agent == .pi
            ? "restart-pi-thread"
            : "33333333-3333-4333-8333-333333333333"
        let codexRoot = root.appendingPathComponent("codex-restart", isDirectory: true)
        let transcript = agent == .pi
            ? TestSupport.writeSessionFile(in: root, id: threadID, cwd: root.path)
            : TestSupport.writeCodexRollout(in: codexRoot, id: threadID, cwd: root.path)
        let runID = "run-restart-\(agent.rawValue)"
        let occurrence = ScheduleOccurrence(
            id: "occ-restart-\(agent.rawValue)",
            scheduledAt: now.addingTimeInterval(-60), phase: .pending,
            attemptCount: 1, notBefore: now, runId: runID
        )

        let writer = TestSupport.makeCore(in: root)
        var persisted = schedule(
            id: "restart-\(agent.rawValue)", due: now.addingTimeInterval(-60),
            target: .newThread(
                cwd: root.path,
                namePattern: agent == .codex ? "Named restart" : nil
            )
        )
        persisted.agent = agent
        persisted.pendingOccurrence = occurrence
        persisted.lastRunAt = occurrence.scheduledAt
        persisted.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(persisted)
        await writer.runHistoryStore.record(Run(
            id: runID, scheduleId: persisted.id, threadId: threadID,
            threadPath: transcript.path, trigger: .schedule,
            startedAt: now.addingTimeInterval(-30), status: .running,
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt,
            attempt: 1, retryable: true, agent: agent
        ))

        let executor = FakeRunExecutor()
        let extraRoots: [(agent: AgentKind, url: URL)] = agent == .codex
            ? [(agent: .codex, url: codexRoot)]
            : []
        let recovered = TestSupport.makeCore(
            in: root, executor: executor, schedulerRetryDelays: [0],
            extraSessionRoots: extraRoots
        )
        let publications = LockedThreadPublications()
        let published = expectation(description: "restart recovered \(agent.rawValue) transcript")
        published.assertForOverFulfill = true
        _ = recovered.bus.subscribe { name, data in
            guard name == "thread",
                  let thread = try? PatchworkJSON.decoder.decode(PatchworkThread.self, from: data),
                  thread.id == threadID else { return }
            publications.append(thread)
            published.fulfill()
        }

        let fired = await recovered.scheduler.tick(now: now)
        XCTAssertEqual(fired, 0)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        let recoveredSchedule = await recovered.scheduleStore.get(id: persisted.id)
        XCTAssertNil(recoveredSchedule?.pendingOccurrence)
        XCTAssertEqual(recoveredSchedule?.lastStatus, .interrupted)
        let recoveredRun = await recovered.runHistoryStore.get(id: runID)
        XCTAssertEqual(recoveredRun?.status, .interrupted)
        XCTAssertEqual(recoveredRun?.threadId, threadID)
        XCTAssertEqual(recoveredRun?.threadPath, transcript.standardizedFileURL.path)
        XCTAssertEqual(recoveredRun?.retryable, false)
        XCTAssertEqual(publications.values.count, 1)
        XCTAssertEqual(publications.values.first?.running, false)
        let presented = await recovered.threadStore.thread(idOrPath: transcript.path)
        XCTAssertEqual(presented?.id, threadID)
        let overlay = DaemonWorktreeProjects.loadSnapshot(
            from: root.appendingPathComponent("overlay.json")
        )
        XCTAssertTrue(overlay.managedThreadPaths.contains(transcript.standardizedFileURL.path))

        let second = await recovered.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(second, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        XCTAssertEqual(publications.values.count, 1)
    }

    func testRejectedScheduledPiModeStillPublishesItsMaterializedTranscript() async throws {
        try await assertRejectedPreAcceptanceRunPublishesCreatedThread(agent: .pi)
    }

    func testRejectedScheduledCodexPromptStillPublishesItsMaterializedTranscript() async throws {
        try await assertRejectedPreAcceptanceRunPublishesCreatedThread(agent: .codex)
    }

    private func assertRejectedPreAcceptanceRunPublishesCreatedThread(
        agent: AgentKind
    ) async throws {
        let now = Date()
        let root = try XCTUnwrap(directory)
        let threadID = agent == .pi
            ? "11111111-1111-4111-8111-111111111111"
            : "22222222-2222-4222-8222-222222222222"
        let codexRoot = root.appendingPathComponent("codex-sessions", isDirectory: true)
        let transcript = agent == .pi
            ? root.appendingPathComponent("sessions/\(threadID).jsonl")
            : codexRoot.appendingPathComponent(
                "2026/07/31/rollout-2026-07-31T00-00-00-\(threadID).jsonl"
            )
        let executor = FakeRunExecutor { _ in
            if agent == .pi {
                _ = TestSupport.writeSessionFile(in: root, id: threadID, cwd: root.path)
            } else {
                _ = TestSupport.writeCodexRollout(in: codexRoot, id: threadID, cwd: root.path)
            }
            return RunOutcome(
                status: .failed,
                error: agent == .pi ? "mode rejected" : "prompt rejected",
                summary: nil,
                resolvedThreadId: threadID,
                resolvedThreadPath: transcript.path,
                promptStartedAt: agent == .codex ? now : nil
            )
        }
        let extraRoots: [(agent: AgentKind, url: URL)] = agent == .codex
            ? [(agent: .codex, url: codexRoot)]
            : []
        let core = TestSupport.makeCore(
            in: root, executor: executor, extraSessionRoots: extraRoots
        )
        let publications = LockedThreadPublications()
        let published = expectation(description: "recovered \(agent.rawValue) thread published")
        published.assertForOverFulfill = true
        _ = core.bus.subscribe { name, data in
            guard name == "thread",
                  let thread = try? PatchworkJSON.decoder.decode(PatchworkThread.self, from: data),
                  thread.id == threadID else { return }
            publications.append(thread)
            published.fulfill()
        }
        var rejected = schedule(
            id: "rejected-\(agent.rawValue)", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: root.path, namePattern: "Rejected run")
        )
        rejected.agent = agent
        if agent == .pi { rejected.mode = "ultra" }
        try await core.scheduleStore.upsert(rejected)

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        await fulfillment(of: [published], timeout: 2)
        let settled = await poll {
            await core.scheduleStore.get(id: rejected.id)?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)

        let values = publications.values
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.agent, agent)
        XCTAssertEqual(values.first?.running, false, "a rejected run must not leave a ghost pulse")
        let presented = await core.threadStore.thread(idOrPath: transcript.path)
        XCTAssertEqual(presented?.id, threadID)
        let overlay = DaemonWorktreeProjects.loadSnapshot(
            from: root.appendingPathComponent("overlay.json")
        )
        XCTAssertTrue(overlay.managedThreadPaths.contains(transcript.path))
        let runs = await core.runHistoryStore.query(
            scheduleId: rejected.id, threadId: threadID, limit: 10
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .failed)
        XCTAssertEqual(runs.first?.threadPath, transcript.path)
    }

    func testSameTickSkipPolicyStillAppliesToTwoSchedulesForOneThread() async throws {
        let now = Date()
        _ = TestSupport.writeSessionFile(in: directory, id: "shared-thread", cwd: directory.path)
        let gate = Gate()
        let executor = FakeRunExecutor { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor, concurrency: 1)
        try await core.scheduleStore.upsert(schedule(
            id: "first", due: now.addingTimeInterval(-120),
            target: .existingThread(threadId: "shared-thread")
        ))
        try await core.scheduleStore.upsert(schedule(
            id: "second", due: now.addingTimeInterval(-60),
            target: .existingThread(threadId: "shared-thread")
        ))

        let fired = await core.scheduler.tick(now: now)
        let skipped = await core.scheduleStore.get(id: "second")
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(skipped?.lastStatus, .skipped)
        XCTAssertNil(skipped?.pendingOccurrence)
        let started = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(started)
        await gate.release()
    }

    func testFullQueueDefersTheSameOccurrenceWithoutSpendingAnAttempt() async throws {
        try await assertFullQueueDefersTheSameOccurrence(
            trigger: .interval(everySeconds: 60, startAt: nil)
        )
    }

    func testFullQueueDefersAHeartbeatOnlyUntilCapacityReturns() async throws {
        try await assertFullQueueDefersTheSameOccurrence(trigger: .heartbeat(everySeconds: 60))
    }

    private func assertFullQueueDefersTheSameOccurrence(trigger: ScheduleTrigger) async throws {
        let now = Date()
        let gate = Gate()
        let executor = FakeRunExecutor { _ in
            await gate.waitForRelease()
            return RunOutcome(status: .ok, error: nil, summary: "done")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor)
        let queue = RunQueue(
            concurrencyLimit: 1,
            executor: executor,
            historyStore: core.runHistoryStore,
            bus: core.bus,
            logger: core.logger,
            maxPendingJobs: 1
        )
        let scheduler = Scheduler(
            scheduleStore: core.scheduleStore,
            runHistoryStore: core.runHistoryStore,
            runQueue: queue,
            threadStore: core.threadStore,
            leaseStore: core.leaseStore,
            bus: core.bus,
            logger: core.logger
        )
        // The production scheduler performs relaunch recovery before schedules can be created via
        // the API. Prime that empty recovery pass so this test models a new due heartbeat, not a
        // heartbeat that was already overdue when the daemon reopened.
        _ = await scheduler.tick(now: now.addingTimeInterval(-120))
        func filler(_ id: String) -> RunJob {
            RunJob(
                id: id,
                scheduleId: nil,
                trigger: .manual,
                target: .newThread(cwd: directory.path, namePattern: nil),
                prompt: "fill",
                mode: nil,
                timeoutSeconds: 30,
                queuedAt: now
            )
        }

        _ = await queue.enqueue(filler("run-filler-active"))
        _ = await queue.enqueue(filler("run-filler-queued"))
        let queueFilled = await poll {
            let active = await queue.activeCount()
            let queued = await queue.queuedCount()
            return active == 1 && queued == 1
        }
        XCTAssertTrue(queueFilled)

        var due = schedule(
            id: "capacity-retry",
            due: now.addingTimeInterval(-60),
            trigger: trigger,
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        due.lastStatus = .ok
        try await core.scheduleStore.upsert(due)

        let firstFired = await scheduler.tick(now: now)
        XCTAssertEqual(firstFired, 0)
        let firstSchedule = await core.scheduleStore.get(id: due.id)
        let first = try XCTUnwrap(firstSchedule?.pendingOccurrence)
        XCTAssertEqual(first.attemptCount, 0)
        XCTAssertNil(first.runId)
        XCTAssertEqual(firstSchedule?.lastStatus, .ok)

        let secondFired = await scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(secondFired, 0)
        let secondSchedule = await core.scheduleStore.get(id: due.id)
        let second = try XCTUnwrap(secondSchedule?.pendingOccurrence)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.attemptCount, 0)
        XCTAssertNil(second.runId)
        let deferredRuns = await core.runHistoryStore.query(
            scheduleId: due.id, threadId: nil, limit: 10
        )
        XCTAssertTrue(deferredRuns.isEmpty)

        await gate.release()
        let drained = await poll {
            let active = await queue.activeCount()
            let queued = await queue.queuedCount()
            return active == 0 && queued == 0
        }
        XCTAssertTrue(drained)
        let finalFired = await scheduler.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(finalFired, 1)
        let settled = await poll {
            await core.scheduleStore.get(id: due.id)?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        let runs = await core.runHistoryStore.query(scheduleId: due.id, threadId: nil, limit: 10)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.attempt, 1)
        XCTAssertEqual(runs.first?.status, .ok)
    }

    func testTransientPrePromptFailureRetriesAfterDaemonRecreation() async throws {
        let now = Date()
        let firstExecutor = FakeRunExecutor { _ in
            RunOutcome(status: .failed, error: "temporary pipe failure", summary: nil, retryable: true)
        }
        let first = TestSupport.makeCore(
            in: directory, executor: firstExecutor, schedulerRetryDelays: [60]
        )
        try await first.scheduleStore.upsert(schedule(
            id: "retry", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))
        let firstFired = await first.scheduler.tick(now: now)
        XCTAssertEqual(firstFired, 1)
        let retryPersisted = await poll {
            guard let pending = await first.scheduleStore.get(id: "retry")?.pendingOccurrence else { return false }
            return pending.attemptCount == 1 && pending.runId == nil && pending.notBefore > now
        }
        XCTAssertTrue(retryPersisted)
        let persistedSchedule = await first.scheduleStore.get(id: "retry")
        let retryAt = try XCTUnwrap(persistedSchedule?.pendingOccurrence?.notBefore)

        let secondExecutor = FakeRunExecutor()
        let second = TestSupport.makeCore(
            in: directory, executor: secondExecutor, schedulerRetryDelays: [60]
        )
        let tooEarly = await second.scheduler.tick(now: retryAt.addingTimeInterval(-1))
        XCTAssertEqual(tooEarly, 0, "relaunch preserves the persisted backoff")
        let secondFired = await second.scheduler.tick(now: retryAt.addingTimeInterval(1))
        XCTAssertEqual(secondFired, 1)
        let retried = await poll { secondExecutor.executedJobs.count == 1 }
        XCTAssertTrue(retried)
        let settled = await poll { await second.scheduleStore.get(id: "retry")?.pendingOccurrence == nil }
        XCTAssertTrue(settled)

        let runs = await second.runHistoryStore.query(scheduleId: "retry", threadId: nil, limit: 10)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(Set(runs.map(\.status)), [.failed, .ok])
        XCTAssertEqual(Set(runs.compactMap(\.attempt)), [1, 2])
    }

    func testRetryableExistingThreadFailureRetriesBeforePromptDispatch() async throws {
        let now = Date()
        _ = TestSupport.writeSessionFile(
            in: directory, id: "existing-retry-thread", cwd: directory.path
        )
        let executor = FakeRunExecutor { job in
            job.attempt == 1
                ? RunOutcome(
                    status: .failed, error: "temporary startup failure", summary: nil,
                    retryable: true
                )
                : RunOutcome(status: .ok, error: nil, summary: "retried")
        }
        let core = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        try await core.scheduleStore.upsert(schedule(
            id: "existing-retry", due: now.addingTimeInterval(-60),
            target: .existingThread(threadId: "existing-retry-thread")
        ))

        let firstFired = await core.scheduler.tick(now: now)
        XCTAssertEqual(firstFired, 1)
        let retryReady = await poll {
            await core.scheduleStore.get(id: "existing-retry")?.pendingOccurrence?.runId == nil
        }
        XCTAssertTrue(retryReady)
        let retryFired = await core.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(retryFired, 1)
        let settled = await poll {
            await core.scheduleStore.get(id: "existing-retry")?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.map(\.attempt), [1, 2])
        XCTAssertTrue(executor.executedJobs.allSatisfy {
            $0.target.existingThreadID == "existing-retry-thread"
        })
    }

    func testTerminalHistoryFailureRetainsOccurrenceUntilTheSnapshotFlushes() async throws {
        let now = Date()
        _ = TestSupport.writeSessionFile(
            in: directory, id: "history-terminal-thread", cwd: directory.path
        )
        let historyFile = directory.appendingPathComponent("runs.jsonl")
        let executor = FakeRunExecutor { _ in
            try? FileManager.default.setAttributes(
                [.immutable: true], ofItemAtPath: historyFile.path
            )
            return RunOutcome(status: .ok, error: nil, summary: "durable result")
        }
        let core = TestSupport.makeCore(in: directory, executor: executor)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: historyFile.path
            )
        }
        try await core.scheduleStore.upsert(schedule(
            id: "terminal-history", due: now.addingTimeInterval(-60),
            target: .existingThread(threadId: "history-terminal-thread")
        ))

        let fired = await core.scheduler.tick(now: now)
        XCTAssertEqual(fired, 1)
        let terminalWasDirty = await poll {
            guard let occurrence = await core.scheduleStore.get(
                id: "terminal-history"
            )?.pendingOccurrence, let runID = occurrence.runId,
            await core.runHistoryStore.get(id: runID)?.status == .ok else { return false }
            return !(await core.runHistoryStore.isPersisted(id: runID))
        }
        XCTAssertTrue(terminalWasDirty)
        XCTAssertEqual(executor.executedJobs.count, 1)

        try FileManager.default.setAttributes(
            [.immutable: false], ofItemAtPath: historyFile.path
        )
        _ = await core.scheduler.tick(now: now.addingTimeInterval(1))
        let settled = await poll {
            await core.scheduleStore.get(id: "terminal-history")?.pendingOccurrence == nil
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.count, 1, "history repair must not execute the prompt again")
        let reopened = RunHistoryStore(
            fileURL: historyFile, logger: TestSupport.logger(in: directory)
        )
        let runs = await reopened.query(
            scheduleId: "terminal-history", threadId: nil, limit: 10
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .ok)
    }

    func testRestartRetainsIdentitylessCodexStartWithoutResending() async throws {
        let now = Date()
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "codex-identity-unknown", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.agent = .codex
        saved.pendingOccurrence = ScheduleOccurrence(
            id: "occ-codex-identity-unknown", scheduledAt: now.addingTimeInterval(-60),
            phase: .starting, attemptCount: 1, notBefore: now,
            runId: "run-codex-identity-unknown"
        )
        try await writer.scheduleStore.upsert(saved)
        await writer.runHistoryStore.record(Run(
            id: "run-codex-identity-unknown", scheduleId: saved.id,
            trigger: .schedule, startedAt: now.addingTimeInterval(-10), status: .running,
            occurrenceId: saved.pendingOccurrence?.id,
            scheduledAt: saved.pendingOccurrence?.scheduledAt, attempt: 1, agent: .codex
        ))

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        let fired = await recovered.scheduler.tick(now: now)
        XCTAssertEqual(fired, 0)

        let occurrence = await recovered.scheduleStore.get(id: saved.id)?.pendingOccurrence
        XCTAssertEqual(occurrence?.phase, .starting)
        XCTAssertEqual(occurrence?.runId, "run-codex-identity-unknown")
        XCTAssertNil(occurrence?.threadId)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        let run = await recovered.runHistoryStore.get(id: "run-codex-identity-unknown")
        XCTAssertEqual(run?.status, .interrupted)
    }

    func testOfflineLaunchPersistsWorkWithoutDispatchingUntilConnectivityReturns() async throws {
        let now = Date()
        let online = LockedFlag()
        let executor = FakeRunExecutor()
        let core = TestSupport.makeCore(
            in: directory, executor: executor, networkAvailable: { online.value }
        )
        try await core.scheduleStore.upsert(schedule(
            id: "offline", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        let whileOffline = await core.scheduler.tick(now: now)
        let pending = await core.scheduleStore.get(id: "offline")?.pendingOccurrence
        XCTAssertEqual(whileOffline, 0)
        XCTAssertEqual(pending?.attemptCount, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)

        online.set()
        let afterReconnect = await core.scheduler.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(afterReconnect, 1)
        let ran = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(ran)
    }

    func testPermanentFailureDoesNotRetry() async throws {
        let now = Date()
        let executor = FakeRunExecutor { _ in
            RunOutcome(status: .failed, error: "invalid configuration", summary: nil)
        }
        let core = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        try await core.scheduleStore.upsert(schedule(
            id: "permanent", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        _ = await core.scheduler.tick(now: now)
        let settled = await poll {
            await core.scheduleStore.get(id: "permanent")?.pendingOccurrence == nil
        }
        _ = await core.scheduler.tick(now: now.addingTimeInterval(1))

        XCTAssertTrue(settled)
        XCTAssertEqual(executor.executedJobs.count, 1)
    }

    func testRetryCountIsBounded() async throws {
        let now = Date()
        let executor = FakeRunExecutor { _ in
            RunOutcome(status: .failed, error: "still offline", summary: nil, retryable: true)
        }
        let core = TestSupport.makeCore(
            in: directory, executor: executor, schedulerRetryDelays: [0]
        )
        try await core.scheduleStore.upsert(schedule(
            id: "bounded", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        ))

        _ = await core.scheduler.tick(now: now)
        let firstFinished = await poll {
            await core.scheduleStore.get(id: "bounded")?.pendingOccurrence?.runId == nil
        }
        XCTAssertTrue(firstFinished)
        _ = await core.scheduler.tick(now: Date().addingTimeInterval(1))
        let exhausted = await poll {
            await core.scheduleStore.get(id: "bounded")?.pendingOccurrence == nil
        }
        XCTAssertTrue(exhausted)

        XCTAssertEqual(executor.executedJobs.count, 2)
        let finalSchedule = await core.scheduleStore.get(id: "bounded")
        XCTAssertEqual(finalSchedule?.lastStatus, .failed)
    }

    func testUnknownOccurrencePhaseIsPreservedAndNeverGuessed() async throws {
        let now = Date()
        let executor = FakeRunExecutor()
        let core = TestSupport.makeCore(in: directory, executor: executor)
        var saved = schedule(
            id: "future", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = ScheduleOccurrence(
            id: "occ-future", scheduledAt: now.addingTimeInterval(-60),
            phase: .other("future-phase"), notBefore: now
        )
        try await core.scheduleStore.upsert(saved)

        let fired = await core.scheduler.tick(now: now)
        let persisted = await core.scheduleStore.get(id: "future")?.pendingOccurrence
        XCTAssertEqual(fired, 0)
        XCTAssertTrue(executor.executedJobs.isEmpty)
        XCTAssertEqual(persisted?.phase.rawValue, "future-phase")
    }

    func testQueuedWorkFromPreviousDaemonRetriesWithoutSpendingAnAttempt() async throws {
        let now = Date()
        let occurrence = ScheduleOccurrence(
            id: "occ-queued", scheduledAt: now.addingTimeInterval(-60),
            attemptCount: 1, notBefore: now, runId: "run-queued"
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "queued", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = occurrence
        saved.lastRunAt = occurrence.scheduledAt
        saved.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(saved)
        await writer.runHistoryStore.record(Run(
            id: "run-queued", scheduleId: "queued", trigger: .schedule,
            startedAt: now, status: .queued, occurrenceId: occurrence.id,
            scheduledAt: occurrence.scheduledAt, attempt: 1
        ))

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        await recovered.start()
        let ran = await poll { executor.executedJobs.count == 1 }
        XCTAssertTrue(ran)
        await recovered.stop()

        XCTAssertEqual(executor.executedJobs.first?.attempt, 1)
    }

    func testAcceptedRunFromPreviousDaemonIsInterruptedAndNeverResent() async throws {
        let now = Date()
        let occurrence = ScheduleOccurrence(
            id: "occ-accepted", scheduledAt: now.addingTimeInterval(-60),
            phase: .accepted, attemptCount: 1, notBefore: now,
            runId: "run-accepted"
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "accepted", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = occurrence
        saved.lastRunAt = occurrence.scheduledAt
        saved.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(saved)
        await writer.runHistoryStore.record(Run(
            id: "run-accepted", scheduleId: "accepted", trigger: .schedule,
            startedAt: now.addingTimeInterval(-30), status: .running,
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt, attempt: 1,
            promptStartedAt: now.addingTimeInterval(-20), promptAcceptedAt: now.addingTimeInterval(-19)
        ))

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        await recovered.start()
        let recoveredOccurrence = await poll { await recovered.scheduleStore.get(id: "accepted")?.pendingOccurrence == nil }
        XCTAssertTrue(recoveredOccurrence)
        await recovered.stop()

        XCTAssertTrue(executor.executedJobs.isEmpty)
        let recoveredSchedule = await recovered.scheduleStore.get(id: "accepted")
        let recoveredRun = await recovered.runHistoryStore.get(id: "run-accepted")
        XCTAssertEqual(recoveredSchedule?.lastStatus, .interrupted)
        XCTAssertEqual(recoveredRun?.status, .interrupted)
    }

    func testRestartKeepsAcceptedOccurrenceUntilInterruptedHistoryIsDurable() async throws {
        let now = Date()
        let occurrence = ScheduleOccurrence(
            id: "occ-accepted-dirty", scheduledAt: now.addingTimeInterval(-60),
            phase: .accepted, attemptCount: 1, notBefore: now,
            runId: "run-accepted-dirty"
        )
        let writer = TestSupport.makeCore(in: directory)
        var saved = schedule(
            id: "accepted-dirty", due: now.addingTimeInterval(-60),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        saved.pendingOccurrence = occurrence
        saved.lastRunAt = occurrence.scheduledAt
        saved.nextRunAt = now.addingTimeInterval(60)
        try await writer.scheduleStore.upsert(saved)
        await writer.runHistoryStore.record(Run(
            id: "run-accepted-dirty", scheduleId: saved.id, trigger: .schedule,
            startedAt: now.addingTimeInterval(-30), status: .running,
            occurrenceId: occurrence.id, scheduledAt: occurrence.scheduledAt, attempt: 1,
            promptStartedAt: now.addingTimeInterval(-20),
            promptAcceptedAt: now.addingTimeInterval(-19)
        ))
        let historyFile = directory.appendingPathComponent("runs.jsonl")
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: historyFile.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: historyFile.path
            )
        }

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        let firstFired = await recovered.scheduler.tick(now: now)
        let retainedOccurrence = await recovered.scheduleStore.get(
            id: saved.id
        )?.pendingOccurrence
        let dirtyRun = await recovered.runHistoryStore.get(id: occurrence.runId!)
        let dirtyPersisted = await recovered.runHistoryStore.isPersisted(
            id: occurrence.runId!
        )
        XCTAssertEqual(firstFired, 0)
        XCTAssertNotNil(
            retainedOccurrence,
            "the no-resend breadcrumb must survive a failed terminal history append"
        )
        XCTAssertEqual(dirtyRun?.status, .interrupted)
        XCTAssertFalse(dirtyPersisted)
        XCTAssertTrue(executor.executedJobs.isEmpty)

        try FileManager.default.setAttributes(
            [.immutable: false], ofItemAtPath: historyFile.path
        )
        let secondFired = await recovered.scheduler.tick(now: now.addingTimeInterval(1))
        let settledOccurrence = await recovered.scheduleStore.get(
            id: saved.id
        )?.pendingOccurrence
        XCTAssertEqual(secondFired, 0)
        XCTAssertNil(settledOccurrence)
        XCTAssertTrue(executor.executedJobs.isEmpty)

        let reopened = RunHistoryStore(
            fileURL: historyFile, logger: TestSupport.logger(in: directory)
        )
        let durableRun = await reopened.get(id: occurrence.runId!)
        XCTAssertEqual(durableRun?.status, .interrupted)
    }

    func testHeartbeatPendingAtRelaunchIsDiscardedInsteadOfReplayed() async throws {
        let now = Date()
        let writer = TestSupport.makeCore(in: directory)
        let saved = schedule(
            id: "heartbeat", due: now.addingTimeInterval(-3_600),
            trigger: .heartbeat(everySeconds: 900),
            target: .newThread(cwd: directory.path, namePattern: nil)
        )
        try await writer.scheduleStore.upsert(saved)

        let executor = FakeRunExecutor()
        let recovered = TestSupport.makeCore(in: directory, executor: executor)
        await recovered.start()
        let resynced = await poll {
            (await recovered.scheduleStore.get(id: "heartbeat")?.nextRunAt ?? .distantPast) > now
        }
        XCTAssertTrue(resynced)
        await recovered.stop()

        XCTAssertTrue(executor.executedJobs.isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

private final class LockedThreadPublications: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PatchworkThread] = []

    var values: [PatchworkThread] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ thread: PatchworkThread) {
        lock.lock()
        stored.append(thread)
        lock.unlock()
    }
}
