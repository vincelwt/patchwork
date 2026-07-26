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

    // A mid-window age (older than the "just written" grace period, younger than the idle cut)
    // so the verdict comes from the entry itself.
    private let midAge: TimeInterval = 20

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

    func testAnyEntryWrittenSecondsAgoMeansRunning() {
        // Even a terminal stop reason: the file is being written right now.
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: "stop"), age: 1),
            .running
        )
        XCTAssertEqual(SessionActivityClassifier.classify(lastEntry: nil, age: 0), .running)
    }

    // MARK: Idle

    func testTerminalStopReasonsMeanIdle() {
        for reason in ["stop", "length", "error", "aborted"] {
            XCTAssertEqual(
                SessionActivityClassifier.classify(lastEntry: message(role: "assistant", stopReason: reason), age: midAge),
                .idle,
                "\(reason) should settle the session"
            )
        }
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
        let entry = message(role: "assistant", stopReason: "stop")
        // At the recent-write boundary the write itself wins.
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: entry, age: SessionActivityClassifier.recentWriteWindow),
            .running
        )
        // At the idle boundary the entry still decides; one second later it cannot.
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: message(role: "user"), age: SessionActivityClassifier.idleWindow),
            .running
        )
        XCTAssertEqual(
            SessionActivityClassifier.classify(lastEntry: message(role: "user"), age: SessionActivityClassifier.idleWindow + 1),
            .idle
        )
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

        // Force a mid-window mtime so the entry, not the freshness, decides.
        let modified = Date().addingTimeInterval(-30)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

        let activity = try XCTUnwrap(SessionActivityClassifier.classifyFile(at: url))
        XCTAssertEqual(activity.state, .running)
        XCTAssertEqual(activity.modifiedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1.5)

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
