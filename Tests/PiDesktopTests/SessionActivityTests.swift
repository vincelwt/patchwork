import Combine
import Foundation
import PiDeskKit
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

    func testFreshMeaningfulEntryMeansRunningButMissingEntryIsUnknown() {
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: "toolUse"), age: 1), .running)
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nil, age: 0), .unknown)
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

    func testNewerIncompleteRecordTemporarilyWinsOverPreviousTerminalEntry() throws {
        let tail = Data("""
        {"type":"message","id":"done","message":{"role":"assistant","stopReason":"stop"}}
        {"type":"message","id":"next","message":{"role":"user"
        """.utf8)
        let evidence = SessionActivityClassifier.tailEvidence(inTail: tail)
        XCTAssertEqual(evidence.lastEntry?["id"]?.stringValue, "done")
        XCTAssertTrue(evidence.hasNewerIncompleteRecord)
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: evidence.lastEntry,
                age: freshAge,
                hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
            ),
            .running
        )
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: evidence.lastEntry,
                age: midAge,
                hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
            ),
            .idle,
            "A malformed suffix must stop overriding the prior terminal after the append window"
        )
    }

    func testCompleteMetadataOnlyTailIsNotTreatedAsAnIncompleteWrite() {
        let tail = Data("""
        {"type":"session","version":3,"id":"new","cwd":"/tmp"}
        """.utf8)
        let evidence = SessionActivityClassifier.tailEvidence(inTail: tail)
        XCTAssertNil(evidence.lastEntry)
        XCTAssertFalse(evidence.hasNewerIncompleteRecord)
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: evidence.lastEntry,
                age: freshAge,
                hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
            ),
            .unknown
        )
    }

    func testOlderTruncatedTailFragmentCannotOverrideANewerTerminalEntry() {
        let tail = Data("""
        fragment from an older oversized record"}}
        {"type":"message","id":"done","message":{"role":"assistant","stopReason":"stop"}}
        """.utf8)
        let evidence = SessionActivityClassifier.tailEvidence(inTail: tail)
        XCTAssertEqual(evidence.lastEntry?["id"]?.stringValue, "done")
        XCTAssertFalse(evidence.hasNewerIncompleteRecord)
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: evidence.lastEntry,
                age: freshAge,
                hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
            ),
            .idle
        )
    }

    func testOlderTruncatedFragmentBeforeNewerMetadataDoesNotSignalIncomplete() {
        let tail = Data("""
        fragment from an older oversized record"}}
        {"type":"session_info","name":"renamed"}
        """.utf8)
        let evidence = SessionActivityClassifier.tailEvidence(inTail: tail)
        XCTAssertNil(evidence.lastEntry)
        XCTAssertFalse(evidence.hasNewerIncompleteRecord)
        XCTAssertEqual(
            SessionActivityClassifier.classify(
                lastEntry: evidence.lastEntry,
                age: freshAge,
                hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
            ),
            .unknown
        )
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

    func testCodexBookkeepingCannotMaskACompletedTurn() throws {
        let tail = Data("""
        {"type":"response_item","payload":{"id":"answer","type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Done"}]}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1}}}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """.utf8)
        let entry = try XCTUnwrap(SessionActivityClassifier.lastEntry(
            inTail: tail, transcoder: .make(for: .codex)
        ))
        XCTAssertEqual(entry["message"]?["stopReason"]?.stringValue, "stop")
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: entry, age: 0), .idle)
    }

    func testCodexLifecycleMarkersExposeQuietStartsAndAborts() throws {
        let started = Data("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}}}}
        """.utf8)
        let active = try XCTUnwrap(SessionActivityClassifier.lastEntry(
            inTail: started, transcoder: .make(for: .codex)
        ))
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: active, age: 10), .running)

        let aborted = Data("""
        {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1"}}
        """.utf8)
        let terminal = try XCTUnwrap(SessionActivityClassifier.lastEntry(
            inTail: aborted, transcoder: .make(for: .codex)
        ))
        XCTAssertEqual(terminal["message"]?["stopReason"]?.stringValue, "aborted")
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: terminal, age: 0), .idle)
    }

    func testCodexProgressKeepsARestartedLongTurnRunningAfterStartScrollsAway() throws {
        var lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-long"}}"#
        ]
        for index in 0..<(SessionFileActivityClassifier.codexLifecycleScanLines + 32) {
            lines.append(
                #"{"type":"event_msg","payload":{"type":"agent_reasoning","id":"progress-\#(index)"}}"#
            )
        }
        let tail = Data((lines.joined(separator: "\n") + "\n").utf8)
        let entry = try XCTUnwrap(SessionActivityClassifier.lastEntry(
            inTail: tail, transcoder: .make(for: .codex)
        ))

        XCTAssertEqual(entry["message"]?["role"]?.stringValue, "user")
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: entry, age: midAge), .running)
    }

    func testCodexTerminalMarkerWinsOverFreshPostCompletionBookkeeping() throws {
        var lines = [
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-done"}}"#
        ]
        for index in 0..<8 {
            lines.append(
                #"{"type":"event_msg","payload":{"type":"token_count","id":"after-\#(index)"}}"#
            )
        }
        let tail = Data((lines.joined(separator: "\n") + "\n").utf8)
        let entry = try XCTUnwrap(SessionActivityClassifier.lastEntry(
            inTail: tail, transcoder: .make(for: .codex)
        ))

        XCTAssertEqual(entry["message"]?["stopReason"]?.stringValue, "stop")
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: entry, age: freshAge), .idle)
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

    func testFreshTornFileIsRunningButFreshMetadataOnlyFileIsUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let torn = directory.appendingPathComponent("torn.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"next\",\"message\":{\"role\":\"user\"".utf8).write(to: torn)
        XCTAssertEqual(SessionActivityClassifier.classifyFile(at: torn)?.state, .running)

        let metadata = directory.appendingPathComponent("metadata.jsonl")
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"new\",\"cwd\":\"/tmp\"}\n".utf8).write(to: metadata)
        XCTAssertEqual(SessionActivityClassifier.classifyFile(at: metadata)?.state, .unknown)
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

    func testScanInvalidatesCachedHeartbeatWhenItsFingerprintChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.json")
        try write(
            """
            {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-1"}
            """, name: file.lastPathComponent, in: directory
        )
        let fixedMtime = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: file.path)
        XCTAssertEqual(ActivityHeartbeatStore.scan(directory: directory)["/tmp/a.jsonl"]?.first?.completionId, "answer-1")

        let replacement = directory.appendingPathComponent("replacement.json")
        try Data("""
        {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-2"}
        """.utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        XCTAssertEqual(ActivityHeartbeatStore.scan(directory: directory)["/tmp/a.jsonl"]?.first?.completionId, "answer-2")
    }

    func testScanSeesInPlaceHeartbeatUpdatesWithoutADirectoryChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.json")
        try write(
            """
            {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"running","updatedAt":"2024-01-01T00:00:00.000Z"}
            """, name: file.lastPathComponent, in: directory
        )
        XCTAssertEqual(ActivityHeartbeatStore.scan(directory: directory)["/tmp/a.jsonl"]?.first?.state, "running")

        try Data("""
        {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:01.000Z"}
        """.utf8).write(to: file)
        XCTAssertEqual(ActivityHeartbeatStore.scan(directory: directory)["/tmp/a.jsonl"]?.first?.state, "idle")
    }

    func testSymlinkedHeartbeatInvalidatesWhenItsTargetIsReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("heartbeat.payload")
        let link = directory.appendingPathComponent("heartbeat.json")
        try Data("""
        {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-1"}
        """.utf8).write(to: target)
        let fixedMtime = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(ActivityHeartbeatStore.scan(directory: directory)["/tmp/a.jsonl"]?.first?.completionId, "answer-1")

        let replacement = directory.appendingPathComponent("replacement.payload")
        try Data("""
        {"sessionId":"a","sessionFile":"/tmp/a.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-2"}
        """.utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: replacement, to: target)
        XCTAssertEqual(ActivityHeartbeatStore.scan(directory: directory)["/tmp/a.jsonl"]?.first?.completionId, "answer-2")
    }

    func testScanBoundsMoreThanFiveHundredFilesAndRetainsTheNewest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldMtime = Date(timeIntervalSince1970: 1_000)

        for index in 0...ActivityHeartbeatStore.maxFilesPerScan {
            let name = String(format: "stale-%04d.json", index)
            let file = directory.appendingPathComponent(name)
            try Data("""
            {"sessionId":"stale-\(index)","sessionFile":"/tmp/stale-\(index).jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z"}
            """.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: file.path)
        }

        let newest = directory.appendingPathComponent("newest.json")
        try Data("""
        {"sessionId":"newest","sessionFile":"/tmp/newest.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z"}
        """.utf8).write(to: newest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newest.path
        )

        let result = ActivityHeartbeatStore.scan(directory: directory)
        XCTAssertEqual(result.count, ActivityHeartbeatStore.maxFilesPerScan)
        XCTAssertNotNil(result["/tmp/newest.jsonl"])
        XCTAssertNil(result["/tmp/stale-500.jsonl"])
        XCTAssertEqual(Set(ActivityHeartbeatStore.scan(directory: directory).keys), Set(result.keys))
    }

    func testOversizedHeartbeatIsSkippedBeforeTheBoundedDecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x20, count: ActivityHeartbeatStore.maxFileBytes + 1)
            .write(to: directory.appendingPathComponent("oversized.json"))
        try write(
            """
            {"sessionId":"valid","sessionFile":"/tmp/valid.jsonl","pid":1,"state":"idle","updatedAt":"2024-01-01T00:00:00.000Z"}
            """, name: "valid.json", in: directory
        )

        let result = ActivityHeartbeatStore.scan(directory: directory)
        XCTAssertEqual(Array(result.keys), ["/tmp/valid.jsonl"])
    }

    func testScanOfAMissingDirectoryIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-missing-\(UUID().uuidString)")
        XCTAssertTrue(ActivityHeartbeatStore.scan(directory: missing).isEmpty)
    }
}

private final class SessionActivityTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class GatedSessionActivityTestClock: @unchecked Sendable {
    private let condition = NSCondition()
    private var shouldBlockNextRead = false
    private var blocked = false
    private let value: Date

    init(_ value: Date) { self.value = value }

    func arm() {
        condition.lock()
        shouldBlockNextRead = true
        blocked = false
        condition.unlock()
    }

    func now() -> Date {
        condition.lock()
        if shouldBlockNextRead {
            blocked = true
            condition.broadcast()
            while shouldBlockNextRead { condition.wait() }
        }
        condition.unlock()
        return value
    }

    func isBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blocked
    }

    func release() {
        condition.lock()
        shouldBlockNextRead = false
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
final class SessionActivityMonitorTests: XCTestCase {
    /// An empty, isolated directory: every test in this file must never read the real
    /// `~/.pi/agent/desktop-activity` on the machine running the tests.
    private func emptyHeartbeatDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PiHeartbeats-empty-\(UUID().uuidString)")
    }

    func testMonitorSamplesTheAppTreeWithoutARunningSession() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PiMonitor-\(UUID().uuidString).jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: emptyHeartbeatDirectory())
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.aggregateResources != nil }

        XCTAssertEqual(monitor.activity(forPath: file.path)?.state, .idle)
        XCTAssertGreaterThan(try XCTUnwrap(monitor.aggregateResources).memoryBytes, 0)

        monitor.setTrackedPaths([])
        XCTAssertNil(monitor.aggregateResources)
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

    func testMonitorSeesARunningHeartbeatBeforeTheSessionIsDiscovered() async throws {
        let heartbeatDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiHeartbeats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeatDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: heartbeatDirectory) }

        let heartbeat = heartbeatDirectory.appendingPathComponent("new-thread.json")
        func writeHeartbeat(_ state: String) throws {
            try Data("""
            {"sessionId":"new","sessionFile":"/tmp/not-discovered.jsonl","pid":1,"state":"\(state)","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))"}
            """.utf8).write(to: heartbeat, options: .atomic)
        }

        try writeHeartbeat("running")
        let monitor = SessionActivityMonitor(
            isActiveOverride: false, heartbeatDirectory: heartbeatDirectory, isProcessAlive: { _ in true }
        )
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil(timeout: 1) { monitor.hasRunningActivity }

        try writeHeartbeat("idle")
        try await waitUntil(timeout: 1) { !monitor.hasRunningActivity }
        try writeHeartbeat("running")
        try await waitUntil(timeout: 1) { monitor.hasRunningActivity }
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
        let heartbeat = heartbeatDirectory.appendingPathComponent("s.json")
        let pid = ProcessInfo.processInfo.processIdentifier
        try Data("""
        {"sessionId":"s","sessionFile":"\(file.path)","pid":\(pid),"state":"running","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))","completionId":"old"}
        """.utf8).write(to: heartbeat)

        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: heartbeatDirectory)
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.resources != nil }
        let firstUsage = try XCTUnwrap(monitor.activity(forPath: file.path)?.resources)
        let firstAggregate = try XCTUnwrap(monitor.aggregateResources)
        XCTAssertGreaterThan(firstUsage.memoryBytes, 0)

        do {
            var invalidations = 0
            let cancellable = monitor.objectWillChange.sink { invalidations += 1 }
            var checksum = 0
            for value in 0..<1_000_000 { checksum &+= value }
            XCTAssertNotEqual(checksum, 0)
            try Data("""
            {"sessionId":"s","sessionFile":"\(file.path)","pid":\(pid),"state":"running","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))","completionId":"old"}
            """.utf8).write(to: heartbeat, options: .atomic)
            monitor.tickNow()
            try await waitUntil {
                monitor.activity(forPath: file.path)?.resources != firstUsage
                    && monitor.aggregateResources != firstAggregate
            }
            XCTAssertEqual(invalidations, 0, "Resource-only samples must not invalidate observing views")
            withExtendedLifetime(cancellable) {}
        }

        try FileManager.default.removeItem(at: heartbeat)
        monitor.tickNow()
        try await waitUntil {
            monitor.activity(forPath: file.path)?.state == .idle
                && monitor.activity(forPath: file.path)?.latestCompletedEntryID == "1"
        }
    }

    func testNewCompletionRejectsAnUnpairedStalePreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        let heartbeats = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"a1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
            .write(to: file)
        let heartbeat = heartbeats.appendingPathComponent("s.json")
        try Data("""
        {"sessionId":"s","sessionFile":"\(file.path)","pid":1,"state":"idle","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))","preview":"Earlier answer","previewCompletionId":"a1","stopReason":"stop","completionId":"a1"}
        """.utf8).write(to: heartbeat, options: .atomic)

        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: heartbeats)
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.preview == "Earlier answer" }

        try Data("""
        {"sessionId":"s","sessionFile":"\(file.path)","pid":1,"state":"idle","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date().addingTimeInterval(1)))","preview":"Earlier answer","stopReason":"stop","completionId":"a2"}
        """.utf8).write(to: heartbeat, options: .atomic)
        monitor.tickNow()
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "a2" }

        XCTAssertNil(monitor.activity(forPath: file.path)?.preview)
    }

    func testDisappearedHeartbeatsBeyondTailLimitKeepPriorityForTheNextTick() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        let heartbeats = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var paths: [String] = []
        for index in 0...SessionActivityMonitor.tailReadsPerTick {
            let file = directory.appendingPathComponent("session-\(index).jsonl")
            try Data("{\"type\":\"message\",\"id\":\"a\(index)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
            try Data("{\"sessionId\":\"s\(index)\",\"sessionFile\":\"\(file.path)\",\"pid\":\(index + 1),\"state\":\"running\",\"updatedAt\":\"\(ISO8601DateFormatter.piShared.string(from: Date()))\"}".utf8)
                .write(to: heartbeats.appendingPathComponent("s-\(index).json"))
            paths.append(file.path)
        }
        let monitor = SessionActivityMonitor(
            isActiveOverride: true, heartbeatDirectory: heartbeats, isProcessAlive: { _ in true }
        )
        monitor.setTrackedPaths(paths)
        try await waitUntil { monitor.activities.count == paths.count && monitor.activities.values.allSatisfy { $0.state == .running } }

        for url in try FileManager.default.contentsOfDirectory(at: heartbeats, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
        monitor.tickNow()
        try await waitUntil {
            monitor.activities.values.compactMap(\.latestCompletedEntryID).count == SessionActivityMonitor.tailReadsPerTick
        }
        monitor.tickNow()
        try await waitUntil { monitor.activities.values.compactMap(\.latestCompletedEntryID).count == paths.count }
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

    func testUnchangedAmbiguousIdleHeartbeatStillChecksAChangedJSONLTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        let heartbeats = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"a1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8).write(to: file)
        try Data("{\"sessionId\":\"s\",\"sessionFile\":\"\(file.path)\",\"pid\":1,\"state\":\"idle\",\"updatedAt\":\"2024-01-01T00:00:00.000Z\"}".utf8)
            .write(to: heartbeats.appendingPathComponent("s.json"))
        let monitor = SessionActivityMonitor(isActiveOverride: true, heartbeatDirectory: heartbeats)
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "a1" }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"a2\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8))
        try handle.close()
        monitor.tickNow()
        try await waitUntil { monitor.activity(forPath: file.path)?.latestCompletedEntryID == "a2" }
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

    func testIncompleteAppendVerdictExpiresAtTheRecentWriteBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = SessionActivityTestClock(start)
        let file = directory.appendingPathComponent("terminal-then-torn.jsonl")
        try Data("""
        {"type":"message","id":"done","message":{"role":"assistant","stopReason":"stop"}}
        {"type":"message","id":"next","message":{"role":"user"
        """.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path)

        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: emptyHeartbeatDirectory(),
            now: { clock.now() }
        )
        monitor.setTrackedPaths([file.path])
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .running }

        clock.advance(by: SessionActivityClassifier.recentWriteWindow + 1)
        monitor.tickNow()
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .idle }
    }

    func testIncompleteAppendRetryStaysAheadOfALargeCatalogRotation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = SessionActivityTestClock(start)
        var paths: [String] = []
        for index in 0..<(SessionActivityMonitor.fallbackStatsPerTick * 2) {
            let file = directory.appendingPathComponent("\(index).jsonl")
            let data = index == 0
                ? Data("""
                  {"type":"message","id":"done","message":{"role":"assistant","stopReason":"stop"}}
                  {"type":"message","id":"next","message":{"role":"user"
                  """.utf8)
                : Data("{\"type\":\"message\",\"id\":\"done-\(index)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
            try data.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path)
            paths.append(file.path)
        }

        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: emptyHeartbeatDirectory(),
            now: { clock.now() }
        )
        monitor.setTrackedPaths(paths)
        try await waitUntil { monitor.activity(forPath: paths[0])?.state == .running }

        clock.advance(by: SessionActivityClassifier.recentWriteWindow + 1)
        monitor.tickNow()
        try await waitUntil {
            monitor.activity(forPath: paths[0])?.state == .idle
        }
    }

    func testPollingTaskDoesNotRetainTheMonitor() async throws {
        var monitor: SessionActivityMonitor? = SessionActivityMonitor(
            isActiveOverride: false, heartbeatDirectory: emptyHeartbeatDirectory()
        )
        weak var released: SessionActivityMonitor?
        released = monitor
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

    func testOnlyUnchangedUnambiguousIdleHeartbeatsSkipPolling() {
        let path = "/tmp/session.jsonl"
        let heartbeat = ActivityHeartbeat(
            sessionId: "s", sessionFile: path, sessionDir: nil, pid: 1, state: "idle",
            updatedAt: "2024-01-01T00:00:00.000Z", preview: nil, stopReason: "stop", completionId: "a1"
        )
        let idle = SessionActivity(state: .idle, modifiedAt: Date(), latestCompletedEntryID: "a1")
        XCTAssertEqual(
            SessionActivityMonitor.heartbeatPathsRequiringPoll(
                paths: [path], heartbeats: [path: [heartbeat]], previousHeartbeats: [:], previousActivities: [:]
            ),
            [path]
        )
        XCTAssertTrue(
            SessionActivityMonitor.heartbeatPathsRequiringPoll(
                paths: [path], heartbeats: [path: [heartbeat]], previousHeartbeats: [path: [heartbeat]],
                previousActivities: [path: idle]
            ).isEmpty
        )

        var ambiguous = heartbeat
        ambiguous.completionId = nil
        XCTAssertEqual(
            SessionActivityMonitor.heartbeatPathsRequiringPoll(
                paths: [path], heartbeats: [path: [ambiguous]], previousHeartbeats: [path: [ambiguous]],
                previousActivities: [path: idle]
            ),
            [path]
        )
        XCTAssertEqual(
            SessionActivityMonitor.heartbeatPathsRequiringPoll(
                paths: [path], heartbeats: [:], previousHeartbeats: [path: [heartbeat]],
                previousActivities: [path: idle]
            ),
            [path]
        )

        var changed = heartbeat
        changed.completionId = "a2"
        let running = SessionActivity(state: .running, modifiedAt: Date())
        XCTAssertEqual(
            SessionActivityMonitor.heartbeatPathsRequiringPoll(
                paths: [path], heartbeats: [path: [changed]], previousHeartbeats: [path: [heartbeat]],
                previousActivities: [path: idle]
            ),
            [path]
        )
        XCTAssertEqual(
            SessionActivityMonitor.heartbeatPathsRequiringPoll(
                paths: [path], heartbeats: [path: [heartbeat]], previousHeartbeats: [path: [heartbeat]],
                previousActivities: [path: running]
            ),
            [path]
        )
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

    func testPriorityPathIsIncludedInEveryBoundedFallbackSelection() {
        let paths = (0..<200).map { "session-\($0)" }
        let priority = Set(["session-199"])
        let first = SessionActivityMonitor.pollSelection(
            paths: paths, heartbeatPaths: [], priorityPaths: priority, fallbackCursor: 0
        )
        let second = SessionActivityMonitor.pollSelection(
            paths: paths, heartbeatPaths: [], priorityPaths: priority, fallbackCursor: first.nextCursor
        )

        XCTAssertEqual(first.paths.count, SessionActivityMonitor.fallbackStatsPerTick)
        XCTAssertEqual(second.paths.count, SessionActivityMonitor.fallbackStatsPerTick)
        XCTAssertTrue(first.paths.contains("session-199"))
        XCTAssertTrue(second.paths.contains("session-199"))
        XCTAssertEqual(Set(first.paths).intersection(second.paths), priority)
    }

    func testFocusedPathOrdersAheadOfFullUrgentAndIncompleteBatches() {
        let urgent = Set((0..<SessionActivityMonitor.tailReadsPerTick).map { "urgent-\($0)" })
        let incomplete = Set((0..<SessionActivityMonitor.tailReadsPerTick).map { "incomplete-\($0)" })
        let focus = "focused"
        let paths = Array(urgent).sorted() + Array(incomplete).sorted() + [focus, "ordinary"]

        let ordered = SessionActivityMonitor.orderedPollPaths(
            paths,
            focusedPath: focus,
            urgentPaths: urgent,
            incompletePaths: incomplete
        )

        XCTAssertEqual(ordered.first, focus)
        XCTAssertEqual(Set(ordered.prefix(1 + urgent.count).dropFirst()), urgent)
        XCTAssertEqual(Set(ordered), Set(paths))
        XCTAssertEqual(ordered.count, paths.count)
    }

    func testIncompleteTailRetryQueueExposesOneBatchAndExpiresEveryVerdict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = Date()
        let clock = SessionActivityTestClock(timestamp)
        var paths: [String] = []
        for index in 0..<(SessionActivityMonitor.tailReadsPerTick * 2) {
            let file = directory.appendingPathComponent("session-\(index).jsonl")
            try Data("{\"type\":\"message\",\"id\":\"done-\(index)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
                .write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: timestamp], ofItemAtPath: file.path
            )
            paths.append(file.path)
        }
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: emptyHeartbeatDirectory(),
            now: { clock.now() }
        )
        monitor.setTrackedPaths(paths)
        try await waitUntil { monitor.activities.count == paths.count }

        func appendTornPrompt(to path: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"next\",\"message\":{\"role\":\"user\"".utf8))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: timestamp], ofItemAtPath: path
            )
        }
        let firstBatch = Set(paths.prefix(SessionActivityMonitor.tailReadsPerTick))
        for path in firstBatch { try appendTornPrompt(to: path) }
        monitor.prioritize(paths: firstBatch)
        try await waitUntil {
            firstBatch.allSatisfy { monitor.activity(forPath: $0)?.state == .running }
        }
        XCTAssertEqual(
            monitor.incompleteTailPathCountForTesting,
            SessionActivityMonitor.tailReadsPerTick
        )

        let secondBatch = Set(paths.dropFirst(SessionActivityMonitor.tailReadsPerTick))
        for path in secondBatch { try appendTornPrompt(to: path) }
        monitor.prioritize(paths: secondBatch)
        try await waitUntil {
            secondBatch.allSatisfy { monitor.activity(forPath: $0)?.state == .running }
        }
        XCTAssertEqual(
            monitor.incompleteTailPathCountForTesting,
            SessionActivityMonitor.tailReadsPerTick * 2
        )
        let retryAt = Dictionary(uniqueKeysWithValues: paths.map {
            ($0, timestamp.addingTimeInterval(SessionActivityClassifier.recentWriteWindow))
        })
        XCTAssertTrue(SessionActivityMonitor.dueIncompleteTailPaths(
            paths: paths, retryAtByPath: retryAt, now: timestamp
        ).isEmpty)

        clock.advance(by: SessionActivityClassifier.recentWriteWindow + 1)
        XCTAssertEqual(
            SessionActivityMonitor.dueIncompleteTailPaths(
                paths: paths, retryAtByPath: retryAt, now: clock.now()
            ).count,
            SessionActivityMonitor.tailReadsPerTick
        )
        monitor.tickNow()
        try await waitUntil(timeout: 1) {
            paths.allSatisfy { monitor.activity(forPath: $0)?.state == .idle }
        }
        XCTAssertEqual(monitor.incompleteTailPathCountForTesting, 0)
    }

    func testUrgentPathSurvivesAConfigurationRevisionDuringDetachedPolling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timestamp = Date()
        let clock = GatedSessionActivityTestClock(timestamp)
        var paths: [String] = []
        for index in 0..<200 {
            let file = directory.appendingPathComponent("session-\(index).jsonl")
            try Data("{\"type\":\"message\",\"id\":\"done-\(index)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
                .write(to: file)
            paths.append(file.path)
        }
        let monitor = SessionActivityMonitor(
            isActiveOverride: true,
            heartbeatDirectory: emptyHeartbeatDirectory(),
            now: { clock.now() }
        )
        monitor.setTrackedPaths(paths)
        try await waitUntil {
            monitor.activities.count == SessionActivityMonitor.fallbackStatsPerTick
        }

        let urgentPath = paths[199]
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: urgentPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"prompt\",\"message\":{\"role\":\"user\"}}\n".utf8))
        try handle.close()
        let extra = directory.appendingPathComponent("extra.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"done-extra\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
            .write(to: extra)

        clock.arm()
        defer { clock.release() }
        monitor.prioritize(paths: [urgentPath])
        try await waitUntil { clock.isBlocked() }
        monitor.setTrackedPaths(paths + [extra.path])
        clock.release()

        try await waitUntil(timeout: 1) {
            monitor.activity(forPath: urgentPath)?.state == .running
        }
    }

    func testPriorityTransitionReadsATranscriptNewerThanAnIdleHeartbeat() async throws {
        try await assertPriorityTransition(completionIDs: ["a1"])
    }

    func testPriorityTransitionReadsAfterAnIdleHeartbeatWithoutACompletionID() async throws {
        try await assertPriorityTransition(completionIDs: [])
    }

    func testPriorityTransitionReadsAfterIdleHeartbeatsWithConflictingCompletions() async throws {
        try await assertPriorityTransition(completionIDs: ["a0", "a1"])
    }

    private func assertPriorityTransition(completionIDs: [String]) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        let heartbeats = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let file = directory.appendingPathComponent("background.jsonl")
        try Data("""
        {"type":"message","id":"a1","message":{"role":"assistant","stopReason":"stop"}}
        {"type":"message","id":"u2","message":{"role":"user","content":"continue"}}
        """.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: file.path
        )
        let values: [String?] = completionIDs.isEmpty ? [nil] : completionIDs.map(Optional.some)
        for (index, completionID) in values.enumerated() {
            let completionField = completionID.map { ",\"completionId\":\"\($0)\"" } ?? ""
            try Data("""
            {"sessionId":"s","sessionFile":"\(file.path)","pid":\(index + 1),"state":"idle","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: now.addingTimeInterval(-5)))"\(completionField)}
            """.utf8).write(to: heartbeats.appendingPathComponent("s-\(index).json"))
        }

        let monitor = SessionActivityMonitor(
            isActiveOverride: false,
            heartbeatDirectory: heartbeats,
            isProcessAlive: { _ in false }
        )
        monitor.setTrackedPaths([file.path])
        try await waitUntil(timeout: 1) { monitor.activity(forPath: file.path)?.state == .idle }
        if completionIDs == ["a1"] {
            XCTAssertEqual(monitor.activity(forPath: file.path)?.latestCompletedEntryID, "a1")
        }

        // The background phase has already observed the newer transcript. Selecting it must
        // still inspect that tail without requiring another write or heartbeat update.
        monitor.setPriorityPath(file.path)
        try await waitUntil(timeout: 1) { monitor.activity(forPath: file.path)?.state == .running }
    }

    func testSelectedFileWatcherOverridesAStaleIdleHeartbeatWithoutWaitingForBackgroundPoll() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        let heartbeats = directory.appendingPathComponent("heartbeats", isDirectory: true)
        try FileManager.default.createDirectory(at: heartbeats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("selected.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"a1\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
            .write(to: file)
        try await Task.sleep(nanoseconds: 20_000_000)
        try Data("""
        {"sessionId":"s","sessionFile":"\(file.path)","pid":1,"state":"idle","updatedAt":"\(ISO8601DateFormatter.piShared.string(from: Date()))","completionId":"a1"}
        """.utf8).write(to: heartbeats.appendingPathComponent("s.json"))

        let monitor = SessionActivityMonitor(
            isActiveOverride: false,
            heartbeatDirectory: heartbeats,
            isProcessAlive: { _ in false }
        )
        monitor.setTrackedPaths([file.path])
        monitor.setPriorityPath(file.path)
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil(timeout: 1) {
            monitor.activity(forPath: file.path)?.latestCompletedEntryID == "a1"
        }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"u2\",\"message\":{\"role\":\"user\",\"content\":\"go\"}}\n".utf8))
        try await waitUntil(timeout: 1) { monitor.activity(forPath: file.path)?.state == .running }

        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"a2\",\"message\":{\"role\":\"assistant\",\"content\":\"done\",\"stopReason\":\"stop\"}}\n".utf8))
        try handle.close()
        try await waitUntil(timeout: 1) {
            monitor.activity(forPath: file.path)?.state == .idle
                && monitor.activity(forPath: file.path)?.latestCompletedEntryID == "a2"
        }
    }

    func testSelectedWatcherAttachesWhenAProvisionalFileAppearsAndAfterReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("provisional.jsonl")

        let monitor = SessionActivityMonitor(
            isActiveOverride: false,
            heartbeatDirectory: emptyHeartbeatDirectory()
        )
        monitor.setTrackedPaths([file.path])
        monitor.setPriorityPath(file.path)
        monitor.start()
        defer { monitor.stop() }

        try Data("{\"type\":\"message\",\"id\":\"u1\",\"message\":{\"role\":\"user\"}}\n".utf8)
            .write(to: file)
        try await waitUntil(timeout: 1) { monitor.activity(forPath: file.path)?.state == .running }

        let replaced = directory.appendingPathComponent("old.jsonl")
        try FileManager.default.moveItem(at: file, to: replaced)
        try Data("{\"type\":\"message\",\"id\":\"a2\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n".utf8)
            .write(to: file)
        try await waitUntil(timeout: 1) {
            monitor.activity(forPath: file.path)?.latestCompletedEntryID == "a2"
        }
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
