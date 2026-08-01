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

    private func writeHeartbeat(sessionId: String, state: String, updatedAt: Date, pid: Int32?, startedAt: Date? = nil) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var json = "{\"sessionId\":\"\(sessionId)\",\"sessionFile\":\"/tmp/\(sessionId).jsonl\",\"cwd\":\"/tmp\",\"state\":\"\(state)\",\"updatedAt\":\"\(formatter.string(from: updatedAt))\""
        if let pid { json += ",\"pid\":\(pid)" }
        if let startedAt { json += ",\"startedAt\":\"\(formatter.string(from: startedAt))\"" }
        json += "}"
        try? json.write(to: directory.appendingPathComponent("\(sessionId).json"), atomically: true, encoding: .utf8)
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

    func testNonJSONFilesInTheDirectoryAreIgnored() {
        try? "hello".write(to: directory.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        writeHeartbeat(sessionId: "s7", state: "idle", updatedAt: Date(), pid: getpid())
        let heartbeats = ActivityReader.readHeartbeats(directory: directory)
        XCTAssertEqual(heartbeats.count, 1)
    }

    func testProcessAliveSelfPidIsAlive() {
        XCTAssertTrue(ActivityReader.isProcessAlive(pid: getpid()))
    }

    func testProcessAliveRejectsNonPositivePids() {
        XCTAssertFalse(ActivityReader.isProcessAlive(pid: 0))
        XCTAssertFalse(ActivityReader.isProcessAlive(pid: -1))
    }
}
