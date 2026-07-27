import Foundation
import XCTest
@testable import PiDesktop

final class SessionActivityClassifierTests: XCTestCase {
    private func message(role: String, stopReason: String? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["role": .string(role)]
        if let stopReason { body["stopReason"] = .string(stopReason) }
        return .object([
            "type": .string("message"),
            "id": .string("entry-1"),
            "message": .object(body)
        ])
    }

    // Within the fresh-write grace period: a write this recent always means running.
    private let freshAge: TimeInterval = 2
    // Past the fresh-write grace period but at or under the stale-non-terminal cutoff, so a
    // non-terminal entry's own role/stop-reason decides.
    private let midAge: TimeInterval = 10
    // Past the stale-non-terminal cutoff but well under the outer idle window: any non-terminal
    // entry is now presumed stalled (e.g. a killed terminal) rather than still running.
    private let staleAge: TimeInterval = 30

    // MARK: Running

    func testLastEntryIsAUserMessageMeansRunning() {
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "user"), age: midAge), .running)
    }

    func testAssistantAwaitingToolUseMeansRunning() {
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: "toolUse"), age: midAge),
            .running
        )
    }

    func testToolResultMeansRunning() {
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "toolResult"), age: midAge), .running)
    }

    func testBashExecutionMeansRunning() {
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "bashExecution"), age: midAge), .running)
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: .object(["type": .string("bashExecution"), "id": .string("x")]),
                age: midAge
            ),
            .running
        )
    }

    func testAnyNonTerminalEntryWrittenSecondsAgoMeansRunning() {
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: "toolUse"), age: 1), .running)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nil, age: 0), .running)
    }

    // MARK: Idle

    func testTerminalStopReasonWinsEvenWhenTheWriteIsVeryRecent() {
        // A killed-and-relaunched terminal can leave a fresh mtime behind an already-settled
        // turn; the stop reason must win so the session does not appear to resume running.
        for reason in ["stop", "length", "error", "aborted"] {
            XCTAssertEqual(
                SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: reason), age: freshAge),
                .idle,
                "\(reason) should settle the session even moments after the write"
            )
        }
    }

    func testTerminalStopReasonsMeanIdle() {
        for reason in ["stop", "length", "error", "aborted"] {
            XCTAssertEqual(
                SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: reason), age: midAge),
                .idle,
                "\(reason) should settle the session"
            )
        }
    }

    func testStaleNonTerminalEntryBecomesIdleWellBeforeTheOuterIdleWindow() {
        // A terminal killed mid-turn must not linger as "running" for the full 90s idle window.
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "user"), age: staleAge), .idle)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "toolResult"), age: staleAge), .idle)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: "toolUse"), age: staleAge), .idle)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "assistant"), age: staleAge), .idle)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nil, age: staleAge), .idle)
    }

    func testOldMtimeAlwaysMeansIdle() {
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: message(role: "toolResult"), age: 600),
            .idle,
            "A stale file cannot be running whatever its last entry says"
        )
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "user"), age: 91), .idle)
    }

    // MARK: Unknown

    func testAssistantWithoutAStopReasonIsUnknown() {
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "assistant"), age: midAge), .unknown)
    }

    func testUnrelatedEntryTypesAreUnknown() {
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: .object(["type": .string("session_info"), "name": .string("x")]),
                age: midAge
            ),
            .unknown
        )
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nil, age: midAge), .unknown)
    }

    func testBoundaryExactlyAtEachThreshold() {
        let terminal = message(role: "assistant", stopReason: "stop")
        // The terminal stop reason wins at every age up to the outer idle window.
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: terminal, age: 0), .idle)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: terminal, age: SessionActivityClassifier.idleWindow), .idle)

        // A non-terminal entry rides the fresh-write window through its exact boundary…
        let nonTerminal = message(role: "user")
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: nonTerminal, age: SessionActivityClassifier.recentWriteWindow),
            .running
        )
        // …then the entry's own role decides through the stale-non-terminal boundary…
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: nonTerminal, age: SessionActivityClassifier.staleNonTerminalWindow),
            .running
        )
        // …one second later it is presumed stalled…
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: nonTerminal, age: SessionActivityClassifier.staleNonTerminalWindow + 1),
            .idle
        )
        // …all the way out to the idle window, one second past which the age alone would have
        // settled it anyway.
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nonTerminal, age: SessionActivityClassifier.idleWindow), .idle)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nonTerminal, age: SessionActivityClassifier.idleWindow + 1), .idle)
    }

    // MARK: Tail extraction

    func testLastEntryIsTakenFromTheEndOfTheTail() {
        let tail = Data("""
        {"type":"message","id":"1","message":{"role":"user"}}
        {"type":"message","id":"2","message":{"role":"assistant","stopReason":"stop"}}
        """.utf8)
        let entry = SessionActivityClassifier.lastEntry(inTail: tail)
        XCTAssertEqual(entry?["id"]?.stringValue, "2")
    }

    func testPartiallyWrittenFinalLineFallsBackToThePreviousEntry() {
        let tail = Data("""
        {"type":"message","id":"1","message":{"role":"toolResult"}}
        {"type":"message","id":"2","messa
        """.utf8)
        let entry = SessionActivityClassifier.lastEntry(inTail: tail)
        XCTAssertEqual(entry?["id"]?.stringValue, "1", "A torn write must not hide the real last entry")
    }

    func testTruncatedLeadingLineIsIgnored() {
        // A 256 KB tail normally starts mid-record; that fragment must never be parsed.
        let tail = Data("""
        ,"content":"garbage tail of a huge record"}}
        {"type":"message","id":"9","message":{"role":"user"}}
        """.utf8)
        XCTAssertEqual(SessionActivityClassifier.lastEntry(inTail: tail)?["id"]?.stringValue, "9")
    }

    func testEmptyTailHasNoEntry() {
        XCTAssertNil(SessionActivityClassifier.lastEntry(inTail: Data()))
        XCTAssertNil(SessionActivityClassifier.lastEntry(inTail: Data("\n\n".utf8)))
    }

    func testCRLFTerminatedRecordStillDecodes() {
        let tail = Data("{\"type\":\"message\",\"id\":\"7\",\"message\":{\"role\":\"user\"}}\r\n".utf8)
        XCTAssertEqual(SessionActivityClassifier.lastEntry(inTail: tail)?["id"]?.stringValue, "7")
    }

    // MARK: End-to-end on a real file

    func testFileClassificationReadsOnlyTheTailAndDetectsRunning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("session.jsonl")
        // Larger than the tail limit, so only the end can possibly be read.
        let filler = String(repeating: "{\"type\":\"message\",\"id\":\"pad\",\"message\":{\"role\":\"user\"}}\n", count: 6_000)
        let content = filler + "{\"type\":\"message\",\"id\":\"last\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"toolUse\"}}\n"
        try Data(content.utf8).write(to: url)
        XCTAssertGreaterThan(
            try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            SessionActivityClassifier.tailByteLimit
        )

        // Force a mtime past the fresh-write grace period but under the stale-non-terminal cut,
        // so the entry, not the freshness, decides.
        let modified = Date().addingTimeInterval(-10)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

        let activity = try XCTUnwrap(SessionActivityClassifier.classifyFile(at: url))
        XCTAssertEqual(activity.state, .running)
        XCTAssertEqual(activity.modifiedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1.5)
        XCTAssertEqual(activity.lastStopReason, "toolUse")

        let tail = try XCTUnwrap(SessionActivityClassifier.readTail(at: url))
        XCTAssertLessThanOrEqual(tail.count, SessionActivityClassifier.tailByteLimit)
        XCTAssertEqual(SessionActivityClassifier.lastEntry(inTail: tail)?["id"]?.stringValue, "last")
    }

    func testOldFileIsIdleButStillExposesItsLatestCompletionID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("old.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: url.path
        )

        let activity = try XCTUnwrap(SessionActivityClassifier.classifyFile(at: url))
        XCTAssertEqual(activity.state, .idle)
        XCTAssertEqual(activity.latestCompletedEntryID, "1")
        XCTAssertNil(activity.runningSince)
    }

    func testMissingFileHasNoActivity() {
        let url = URL(fileURLWithPath: "/tmp/pi-desktop-does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertNil(SessionActivityClassifier.classifyFile(at: url))
    }
}

// MARK: - Heartbeat classification (the matching rule)

final class ActivityHeartbeatClassifierTests: XCTestCase {
    private func heartbeat(
        state: String = "running",
        pid: Int32 = 111,
        updatedSecondsAgo: TimeInterval = 0,
        now: Date = Date()
    ) -> ActivityHeartbeat {
        ActivityHeartbeat(
            sessionId: "s1", sessionFile: "/tmp/s1.jsonl", sessionDir: "/tmp", pid: pid, state: state,
            updatedAt: ISO8601DateFormatter.piShared.string(from: now.addingTimeInterval(-updatedSecondsAgo)),
            preview: nil, stopReason: nil
        )
    }

    func testFreshRunningHeartbeatWithALivePidIsRunning() {
        let now = Date()
        XCTAssertTrue(
            ActivityHeartbeatClassifier.isRunning(heartbeat(updatedSecondsAgo: 1, now: now), now: now, isProcessAlive: { _ in true })
        )
    }

    func testStaleRunningHeartbeatIsNotRunningEvenWithALivePid() {
        // A crashed process leaves "running" behind forever unless freshness is enforced.
        let now = Date()
        XCTAssertFalse(
            ActivityHeartbeatClassifier.isRunning(
                heartbeat(updatedSecondsAgo: ActivityHeartbeatClassifier.freshnessWindow + 1, now: now),
                now: now,
                isProcessAlive: { _ in true }
            )
        )
    }

    func testJustInsideTheFreshnessBoundaryIsStillRunning() {
        // Not exactly at the boundary: ISO8601's millisecond-precision round trip can truncate a
        // handful of microseconds, which would make an exact-boundary comparison flaky.
        let now = Date()
        XCTAssertTrue(
            ActivityHeartbeatClassifier.isRunning(
                heartbeat(updatedSecondsAgo: ActivityHeartbeatClassifier.freshnessWindow - 0.5, now: now),
                now: now,
                isProcessAlive: { _ in true }
            )
        )
    }

    func testFreshRunningHeartbeatWithADeadPidIsNotRunning() {
        // The process crashed just after its last beat: fresh timestamp, but nothing is alive.
        let now = Date()
        XCTAssertFalse(
            ActivityHeartbeatClassifier.isRunning(heartbeat(updatedSecondsAgo: 1, now: now), now: now, isProcessAlive: { _ in false })
        )
    }

    func testIdleStateIsNeverRunningRegardlessOfFreshnessOrPid() {
        let now = Date()
        XCTAssertFalse(
            ActivityHeartbeatClassifier.isRunning(
                heartbeat(state: "idle", updatedSecondsAgo: 0, now: now), now: now, isProcessAlive: { _ in true }
            )
        )
    }

    func testUnparseableTimestampIsNotRunning() {
        let now = Date()
        let malformed = ActivityHeartbeat(
            sessionId: "s1", sessionFile: "/tmp/s1.jsonl", sessionDir: "/tmp", pid: 1, state: "running",
            updatedAt: "not-a-date", preview: nil, stopReason: nil
        )
        XCTAssertFalse(ActivityHeartbeatClassifier.isRunning(malformed, now: now, isProcessAlive: { _ in true }))
    }

    func testResolvedSessionPathPrefersSessionFileThenFallsBackToSessionDirAndId() {
        let withFile = ActivityHeartbeat(
            sessionId: "abc", sessionFile: "/tmp/project/abc.jsonl", sessionDir: "/tmp/other",
            pid: 1, state: "idle", updatedAt: "x", preview: nil, stopReason: nil
        )
        XCTAssertEqual(withFile.resolvedSessionPath, "/tmp/project/abc.jsonl")

        let withoutFile = ActivityHeartbeat(
            sessionId: "abc", sessionFile: nil, sessionDir: "/tmp/project",
            pid: 1, state: "idle", updatedAt: "x", preview: nil, stopReason: nil
        )
        XCTAssertEqual(withoutFile.resolvedSessionPath, "/tmp/project/abc.jsonl")

        let neither = ActivityHeartbeat(
            sessionId: "abc", sessionFile: nil, sessionDir: nil,
            pid: 1, state: "idle", updatedAt: "x", preview: nil, stopReason: nil
        )
        XCTAssertNil(neither.resolvedSessionPath)
    }

    func testProcessAlivenessDoesNotShellOut() {
        // This exercises the real `kill(pid, 0)`-based default directly: no `ps`/`lsof` process.
        XCTAssertTrue(ActivityHeartbeatClassifier.isProcessAlive(pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(ActivityHeartbeatClassifier.isProcessAlive(pid: 0))
        XCTAssertFalse(ActivityHeartbeatClassifier.isProcessAlive(pid: -1))
    }
}

final class ActivityHeartbeatStoreTests: XCTestCase {
    private func write(_ json: String, name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    func testScanDecodesValidRecordsAndSkipsMalformedOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try write(
            """
            {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"running","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-1"}
            """, name: "a.json", in: directory
        )
        try write(
            """
            {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":2,"state":"idle","updatedAt":"2024-01-01T00:00:01.000Z"}
            """, name: "a-2.json", in: directory
        )
        try write("not json at all", name: "b.json", in: directory)
        try write("ignored, wrong extension", name: "c.txt", in: directory)

        let result = ActivityHeartbeatStore.scan(directory: directory)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["/tmp/a.jsonl"]?.count, 2)
        XCTAssertEqual(Set(result["/tmp/a.jsonl"]?.map(\.pid) ?? []), [1, 2])
        XCTAssertEqual(result["/tmp/a.jsonl"]?.first(where: { $0.pid == 1 })?.completionId, "answer-1")
    }

    func testScanOfAMissingDirectoryIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-missing-\(UUID().uuidString)")
        XCTAssertTrue(ActivityHeartbeatStore.scan(directory: missing).isEmpty)
    }
}

@MainActor
final class SessionActivityMonitorTests: XCTestCase {
    /// An empty, isolated directory: every test in this file must never read the real
    /// `~/.pi/agent/desktop-activity` on the machine running the tests.
    private func emptyHeartbeatDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-empty-\(UUID().uuidString)")
    }

    func testMonitorClassifiesTrackedPathsAndDropsRemovedOnes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let running = directory.appendingPathComponent("running.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: running)
        let idle = directory.appendingPathComponent("idle.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: idle)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)],
            ofItemAtPath: idle.path
        )

        // `isActiveOverride` avoids depending on a foreground test host.
        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: emptyHeartbeatDirectory())
        monitor.setTrackedPaths([running.path, idle.path])
        try await waitUntil { monitor.activities.count == 2 }

        XCTAssertEqual(monitor.activity(forPath: running.path)?.state, .running)
        XCTAssertEqual(monitor.activity(forPath: idle.path)?.state, .idle)

        monitor.setTrackedPaths([idle.path])
        XCTAssertNil(monitor.activity(forPath: running.path), "Untracked paths are released immediately")
    }

    func testHeartbeatOverridesAStaleLookingFileToStayRunning() async throws {
        // The file itself looks long-idle (old mtime, terminal stop reason), but a fresh
        // heartbeat with a live pid says otherwise — e.g. Pi is mid-tool-call and has not
        // touched the JSONL in a while. The heartbeat wins outright.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)

        let heartbeatDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: heartbeatDirectory, withIntermediateDirectories: true)
        try Data("""
        {"sessionId":"s","sessionFile":"\(file.path)","pid":4242,"state":"running","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))"}
        """.utf8).write(to: heartbeatDirectory.appendingPathComponent("s.json"))

        let monitor = SessionActivityMonitor(
            isActiveOverride: true, heartbeatDirectory: heartbeatDirectory, isProcessAlive: { _ in true }
        )
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .running }
    }

    func testLiveWriterWinsOverAnIdleAttachmentForTheSameSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
        let heartbeats = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeats, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter.piShared.string(from: Date())
        try Data("{\"sessionId\":\"s\",\"sessionFile\":\"\(file.path)\",\"pid\":1,\"state\":\"running\",\"updatedAt\":\"\(now)\"}".utf8)
            .write(to: heartbeats.appendingPathComponent("s-1.json"))
        try Data("{\"sessionId\":\"s\",\"sessionFile\":\"\(file.path)\",\"pid\":2,\"state\":\"idle\",\"updatedAt\":\"\(now)\"}".utf8)
            .write(to: heartbeats.appendingPathComponent("s-2.json"))

        let monitor = SessionActivityMonitor(
            isActiveOverride: true, heartbeatDirectory: heartbeats, isProcessAlive: { $0 == 1 }
        )
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .running }
    }

    func testHeartbeatWithADeadPidReportsIdleEvenIfFresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"user\"}}\n".utf8).write(to: file)

        let heartbeatDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: heartbeatDirectory, withIntermediateDirectories: true)
        try Data("""
        {"sessionId":"s","sessionFile":"\(file.path)","pid":9999,"state":"running","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))"}
        """.utf8).write(to: heartbeatDirectory.appendingPathComponent("s.json"))

        let monitor = SessionActivityMonitor(
            isActiveOverride: true, heartbeatDirectory: heartbeatDirectory, isProcessAlive: { _ in false }
        )
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .idle }
    }

    func testNoHeartbeatFallsBackToTheFileHeuristic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("running.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: file)

        // An empty heartbeat directory: nothing to consult, so the file heuristic alone decides.
        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: emptyHeartbeatDirectory())
        monitor.setTrackedPaths([file.path])

        try await waitUntil { monitor.activity(forPath: file.path) != nil }
        XCTAssertEqual(monitor.activity(forPath: file.path)?.state, .running, "No heartbeat: the file heuristic alone decides")
    }

    func testPollingTaskDoesNotRetainTheMonitor() async throws {
        var monitor: SessionActivityMonitor? = SessionActivityMonitor(
            isActiveOverride: false, heartbeatDirectory: emptyHeartbeatDirectory()
        )
        weak var released = monitor
        monitor?.start()
        monitor = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(released)
    }

    func testBackgroundApplicationStillPollsForCompletedAnswers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("s.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"background-answer\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)

        let monitor = SessionActivityMonitor(isActiveOverride: false, heartbeatDirectory: emptyHeartbeatDirectory())
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "background-answer" }
        XCTAssertEqual(SessionActivityMonitor.backgroundPollInterval, 15)
    }

    func testFallbackStatsAreBoundedAndRoundRobinWhileHeartbeatsStayImmediate() {
        let paths = (0..<200).map { "session-\($0)" }
        let heartbeat = Set(["session-199"])
        let first = SessionActivityMonitor.pollSelection(paths: paths, heartbeatPaths: heartbeat, fallbackCursor: 0)
        let second = SessionActivityMonitor.pollSelection(
            paths: paths, heartbeatPaths: heartbeat, fallbackCursor: first.nextCursor
        )

        XCTAssertEqual(first.paths.count, SessionActivityMonitor.fallbackStatsPerTick + 1)
        XCTAssertEqual(second.paths.count, SessionActivityMonitor.fallbackStatsPerTick + 1)
        XCTAssertTrue(first.paths.contains("session-199"))
        XCTAssertTrue(second.paths.contains("session-199"))
        XCTAssertTrue(Set(first.paths).intersection(second.paths).subtracting(heartbeat).isEmpty)
    }

    /// The exact flicker the user reported: an ambiguous tail read (no heartbeat, and the file
    /// heuristic itself returns `.unknown`) must never overwrite an already-known verdict.
    func testAmbiguousFileReadIsStickyAndNeverFlipsAnAlreadyKnownState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("session.jsonl")
        // A user entry at a mid-range age: unambiguously running.
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"user\"}}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: file.path)

        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: emptyHeartbeatDirectory())
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .running }

        // Now make the last entry ambiguous (an assistant message with no stop reason at all,
        // i.e. still-decoding/unknown) without changing its age bucket.
        try Data("{\"type\":\"message\",\"id\":\"2\",\"message\":{\"role\":\"assistant\"}}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: file.path)
        monitor.tickNow()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(monitor.activity(forPath: file.path)?.state, .running, "An unknown read must stay on the last known verdict")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}
