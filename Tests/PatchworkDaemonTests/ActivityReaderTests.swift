import XCTest
@testable import PatchworkDaemon

final class ActivityReaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func writeHeartbeat(
        sessionId: String,
        state: String,
        updatedAt: Date,
        pid: Int32?,
        startedAt: Date? = nil
    ) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var json = "{\"sessionId\":\"\(sessionId)\",\"sessionFile\":\"/tmp/\(sessionId).jsonl\",\"cwd\":\"/tmp\",\"state\":\"\(state)\",\"updatedAt\":\"\(formatter.string(from: updatedAt))\""
        if let pid { json += ",\"pid\":\(pid)" }
        if let startedAt { json += ",\"startedAt\":\"\(formatter.string(from: startedAt))\"" }
        json += "}"
        let file = directory.appendingPathComponent("\(sessionId).json")
        try? json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testMissingDirectoryDegradesToEmptyRatherThanThrowing() {
        let missing = directory.appendingPathComponent("does-not-exist")
        let heartbeats = ActivityReader.readHeartbeats(directory: missing)
        XCTAssertTrue(heartbeats.isEmpty)
    }

    func testFreshRunningHeartbeatWithALivePidIsRunning() {
        writeHeartbeat(sessionId: "s1", state: "running", updatedAt: Date(), pid: getpid())
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertEqual(heartbeats.count, 1)
        XCTAssertTrue(ActivityReader.isRunning(heartbeats[0]))
    }

    func testStaleUpdatedAtIsNotRunning() {
        writeHeartbeat(sessionId: "s2", state: "running", updatedAt: Date().addingTimeInterval(-60), pid: getpid())
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertFalse(ActivityReader.isRunning(heartbeats[0]))
    }

    func testIdleStateIsNotRunningEvenIfFresh() {
        writeHeartbeat(sessionId: "s3", state: "idle", updatedAt: Date(), pid: getpid())
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertFalse(ActivityReader.isRunning(heartbeats[0]))
    }

    func testDeadPidIsNotRunningEvenIfFreshAndStateSaysRunning() {
        // pid 999999 is astronomically unlikely to be a live process in a test sandbox; if this
        // ever flakes, the fix is a higher, still-implausible pid, not removing the check.
        writeHeartbeat(sessionId: "s4", state: "running", updatedAt: Date(), pid: 999_999)
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertFalse(ActivityReader.isRunning(heartbeats[0]))
    }

    func testMissingPidIsNotRunning() {
        writeHeartbeat(sessionId: "s5", state: "running", updatedAt: Date(), pid: nil)
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertFalse(ActivityReader.isRunning(heartbeats[0]))
    }

    func testMalformedHeartbeatFileIsSkippedNotThrown() {
        try? "{ not json".write(to: directory.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        writeHeartbeat(sessionId: "s6", state: "running", updatedAt: Date(), pid: getpid())
        let heartbeats = ActivityReader.readHeartbeats(directory: directory, logger: TestSupport.logger(in: directory))
        XCTAssertEqual(heartbeats.count, 1)
        XCTAssertEqual(heartbeats.first?.sessionId, "s6")
    }

    func testOutOfRangePidDegradesToMissingInsteadOfTrapping() throws {
        for (name, pid) in [("too-large", Int64(Int32.max) + 1), ("too-small", Int64(Int32.min) - 1)] {
            try """
            {"sessionId":"\(name)","state":"running","updatedAt":"2024-01-01T00:00:00.000Z","pid":\(pid)}
            """.write(
                to: directory.appendingPathComponent("\(name).json"),
                atomically: true,
                encoding: .utf8
            )
        }

        let heartbeats = ActivityReader.readHeartbeats(directory: directory)

        XCTAssertEqual(Set(heartbeats.map(\.sessionId)), ["too-large", "too-small"])
        XCTAssertTrue(heartbeats.allSatisfy { $0.pid == nil })
        XCTAssertTrue(heartbeats.allSatisfy { !ActivityReader.isRunning($0) })
    }

    func testEmptyAndRelativeSessionFilesDegradeToIDOnlyHeartbeats() throws {
        for (name, path) in [("empty-path", ""), ("relative-path", "sessions/thread.jsonl")] {
            try """
            {"sessionId":"\(name)","sessionFile":"\(path)","state":"idle","updatedAt":"2024-01-01T00:00:00.000Z"}
            """.write(
                to: directory.appendingPathComponent("\(name).json"),
                atomically: true,
                encoding: .utf8
            )
        }

        let heartbeats = ActivityReader.readHeartbeats(directory: directory)

        XCTAssertEqual(Set(heartbeats.map(\.sessionId)), ["empty-path", "relative-path"])
        XCTAssertTrue(heartbeats.allSatisfy { $0.sessionFile == nil })
    }

    func testNonJSONFilesInTheDirectoryAreIgnored() {
        try? "hello".write(to: directory.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        writeHeartbeat(sessionId: "s7", state: "idle", updatedAt: Date(), pid: getpid())
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertEqual(heartbeats.count, 1)
    }

    func testReadBoundsMoreThanFiveHundredFilesAndRetainsTheNewest() throws {
        let oldMtime = Date(timeIntervalSince1970: 1_000)
        for index in 0...ActivityReader.maxFilesPerScan {
            let file = writeHeartbeat(
                sessionId: String(format: "stale-%04d", index),
                state: "idle",
                updatedAt: Date(timeIntervalSince1970: 1_000),
                pid: nil
            )
            try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: file.path)
        }
        let newest = writeHeartbeat(
            sessionId: "newest", state: "idle", updatedAt: Date(timeIntervalSince1970: 2_000), pid: nil
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newest.path
        )

        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        let sessionIDs = Set(heartbeats.map(\.sessionId))
        XCTAssertEqual(heartbeats.count, ActivityReader.maxFilesPerScan)
        XCTAssertTrue(sessionIDs.contains("newest"))
        XCTAssertFalse(sessionIDs.contains("stale-0500"))
        XCTAssertEqual(
            Set(ActivityReader.readHeartbeats(directory: directory).map(\.sessionId)), sessionIDs
        )
    }

    func testOversizedHeartbeatFileIsSkipped() throws {
        try Data(repeating: 0x20, count: ActivityReader.maxFileBytes + 1)
            .write(to: directory.appendingPathComponent("oversized.json"))
        writeHeartbeat(sessionId: "valid", state: "idle", updatedAt: Date(), pid: nil)

        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertEqual(heartbeats.map(\.sessionId), ["valid"])
    }

    func testReadSeesInPlaceHeartbeatUpdatesWithoutADirectoryChange() throws {
        let file = directory.appendingPathComponent("live.json")
        try Data("""
        {"sessionId":"live","sessionFile":"/tmp/live.jsonl","state":"running","updatedAt":"2024-01-01T00:00:00.000Z"}
        """.utf8).write(to: file)
        XCTAssertEqual(ActivityReader.readHeartbeats(directory: directory).first?.state, "running")

        try Data("""
        {"sessionId":"live","sessionFile":"/tmp/live.jsonl","state":"idle","updatedAt":"2024-01-01T00:00:01.000Z"}
        """.utf8).write(to: file)
        XCTAssertEqual(ActivityReader.readHeartbeats(directory: directory).first?.state, "idle")
    }

    func testSymlinkedHeartbeatInvalidatesWhenTargetIsReplaced() throws {
        let target = directory.appendingPathComponent("heartbeat.payload")
        let link = directory.appendingPathComponent("heartbeat.json")
        let fixedMtime = Date(timeIntervalSince1970: 1_000)
        try Data("""
        {"sessionId":"linked","sessionFile":"/tmp/linked.jsonl","state":"idle","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-1"}
        """.utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(ActivityReader.readHeartbeats(directory: directory).first?.completionId, "answer-1")

        let replacement = directory.appendingPathComponent("replacement.payload")
        try Data("""
        {"sessionId":"linked","sessionFile":"/tmp/linked.jsonl","state":"idle","updatedAt":"2024-01-01T00:00:00.000Z","completionId":"answer-2"}
        """.utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: replacement, to: target)

        XCTAssertEqual(ActivityReader.readHeartbeats(directory: directory).first?.completionId, "answer-2")
    }

    func testProcessAliveSelfPidIsAlive() {
        XCTAssertTrue(ActivityReader.isProcessAlive(pid: getpid()))
    }

    func testProcessAliveRejectsNonPositivePids() {
        XCTAssertFalse(ActivityReader.isProcessAlive(pid: 0))
        XCTAssertFalse(ActivityReader.isProcessAlive(pid: -1))
    }
}
