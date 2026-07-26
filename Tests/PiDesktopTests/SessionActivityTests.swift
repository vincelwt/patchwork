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

    func testOldFileIsClassifiedIdleWithoutAnyRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiActivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("old.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: url.path
        )

        let activity = try XCTUnwrap(SessionActivityClassifier.classifyFile(at: url))
        XCTAssertEqual(activity.state, .idle)
        XCTAssertNil(activity.runningSince)
    }

    func testMissingFileHasNoActivity() {
        let url = URL(fileURLWithPath: "/tmp/pi-desktop-does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertNil(SessionActivityClassifier.classifyFile(at: url))
    }

    // MARK: Live-process cross-check (the matching rule)

    func testRunningFileWithNoLiveProcessForItsCwdIsIdle() {
        XCTAssertEqual(
            SessionActivityClassifier.resolvedState(fileState: .running, cwd: "/tmp/project-a", liveCwds: ["/tmp/project-b"]),
            .idle
        )
        XCTAssertEqual(
            SessionActivityClassifier.resolvedState(fileState: .running, cwd: "/tmp/project-a", liveCwds: []),
            .idle
        )
    }

    func testRunningFileWithALiveProcessForItsCwdStaysRunning() {
        XCTAssertEqual(
            SessionActivityClassifier.resolvedState(fileState: .running, cwd: "/tmp/project-a", liveCwds: ["/tmp/project-a"]),
            .running
        )
    }

    func testResolvedStateFallsBackToTheFileHeuristicWhenProcessInspectionIsUnavailable() {
        // `nil` means every attempt at inspection failed; a real running session must not be
        // hidden just because `ps`/`lsof` could not be consulted.
        XCTAssertEqual(SessionActivityClassifier.resolvedState(fileState: .running, cwd: "/tmp/project-a", liveCwds: nil), .running)
        XCTAssertEqual(SessionActivityClassifier.resolvedState(fileState: .idle, cwd: "/tmp/project-a", liveCwds: nil), .idle)
    }

    func testResolvedStateNeverPromotesAnIdleFileEvenWithALiveProcess() {
        XCTAssertEqual(
            SessionActivityClassifier.resolvedState(fileState: .idle, cwd: "/tmp/project-a", liveCwds: ["/tmp/project-a"]),
            .idle,
            "A settled turn stays settled regardless of what else is running in that folder"
        )
    }
}

/// A fixed snapshot, never a real process. `ps`/`lsof` are never shelled out to in tests.
private struct FakeProcessSnapshotProvider: ProcessSnapshotProviding {
    var ps: String?
    var cwds: [Int32: String] = [:]

    func psOutput() -> String? { ps }
    func cwd(forPID pid: Int32) -> String? { cwds[pid] }
}

@MainActor
final class SessionActivityMonitorTests: XCTestCase {
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
        let monitor = SessionActivityMonitor(isActiveOverride: true)
        monitor.setTrackedPaths([running.path, idle.path])
        try await waitUntil { monitor.activities.count == 2 }

        XCTAssertEqual(monitor.activity(forPath: running.path)?.state, .running)
        XCTAssertEqual(monitor.activity(forPath: idle.path)?.state, .idle)

        monitor.setTrackedPaths([idle.path])
        XCTAssertNil(monitor.activity(forPath: running.path), "Untracked paths are released immediately")
    }

    func testRunningFileIsDemotedToIdleWhenNoLiveProcessOwnsItsCwd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("running.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: file)

        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(
            ps: "4242 pi pi --mode rpc",
            cwds: [4242: "/completely/unrelated/cwd"]
        ))
        let monitor = SessionActivityMonitor(isActiveOverride: true, processInspector: inspector)
        monitor.setSessionCwds([file.path: directory.standardizedFileURL.path])
        monitor.setTrackedPaths([file.path])

        // The very first tick can race the inspector's own async refresh and falls back to the
        // file heuristic; wait for the cache to warm, then tick again so the cross-check
        // actually applies rather than passing on the fallback alone.
        try await waitUntil { inspector.liveCwds != nil }
        monitor.tickNow()
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .idle }
    }

    func testRunningFileStaysRunningWhenALiveProcessOwnsItsCwd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("running.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: file)

        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(
            ps: "4242 pi pi --mode rpc",
            cwds: [4242: directory.standardizedFileURL.path]
        ))
        let monitor = SessionActivityMonitor(isActiveOverride: true, processInspector: inspector)
        monitor.setSessionCwds([file.path: directory.standardizedFileURL.path])
        monitor.setTrackedPaths([file.path])

        try await waitUntil { inspector.liveCwds != nil }
        monitor.tickNow()
        try await waitUntil { monitor.activity(forPath: file.path)?.state == .running }
    }

    func testMonitorNeverConsultsTheProcessInspectorWithoutARegisteredCwd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("running.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"toolResult\"}}\n".utf8).write(to: file)

        // A snapshot that would demote everything if it were ever consulted.
        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(ps: ""))
        let monitor = SessionActivityMonitor(isActiveOverride: true, processInspector: inspector)
        monitor.setTrackedPaths([file.path])

        try await waitUntil { monitor.activity(forPath: file.path) != nil }
        XCTAssertEqual(monitor.activity(forPath: file.path)?.state, .running, "No cwd registered: the file heuristic alone decides")
        XCTAssertNil(inspector.liveCwds, "Never triggered: nothing asked for the cross-check")
    }

    func testInactiveApplicationNeverPolls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("s.jsonl")
        try Data("{\"type\":\"message\",\"id\":\"1\",\"message\":{\"role\":\"user\"}}\n".utf8).write(to: file)

        let monitor = SessionActivityMonitor(isActiveOverride: false)
        monitor.setTrackedPaths([file.path])
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(monitor.activities.isEmpty, "A background app must not stat or read session files")
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
