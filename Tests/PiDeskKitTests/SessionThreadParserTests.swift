import XCTest
@testable import PiDeskKit

final class SessionThreadParserTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pideskkit-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func write(_ lines: [String], name: String = "session.jsonl") -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func messageLine(role: String, text: String, timestampMs: Int = 1_700_000_000_000, id: String = UUID().uuidString, isError: Bool = false) -> String {
        """
        {"type":"message","id":"\(id)","message":{"role":"\(role)","content":"\(text)","timestamp":\(timestampMs),"isError":\(isError)}}
        """
    }

    // MARK: - thread(at:)

    func testExplicitSessionInfoNameWinsOverFirstUserMessage() throws {
        let url = write([
            #"{"type":"session","id":"sess-1","cwd":"/Users/x/code","timestamp":"2026-01-01T09:00:00.000Z"}"#,
            #"{"type":"session_info","id":"e1","name":"Nightly triage"}"#,
            messageLine(role: "user", text: "Please check CI", id: "e2")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.name, "Nightly triage")
        XCTAssertEqual(thread.id, "sess-1")
        XCTAssertEqual(thread.cwd, "/Users/x/code")
        XCTAssertEqual(thread.folder, "code")
    }

    func testTitleFallsBackToFirstUserMessageWhenNoExplicitName() throws {
        let url = write([
            #"{"type":"session","id":"sess-2","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "Investigate the flaky test suite please", id: "e1")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.name, "Investigate the flaky test suite please")
    }

    func testPreviewIsLastAssistantMessageNotFirstUserMessage() throws {
        // The doc defines Thread.preview as "first line of the last assistant message" —
        // deliberately different from the app's own sidebar preview (first user prompt).
        let url = write([
            #"{"type":"session","id":"sess-3","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "What is 2+2?", timestampMs: 1, id: "e1"),
            messageLine(role: "assistant", text: "It is 4.", timestampMs: 2, id: "e2"),
            messageLine(role: "user", text: "And 3+3?", timestampMs: 3, id: "e3"),
            messageLine(role: "assistant", text: "It is 6.", timestampMs: 4, id: "e4")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.preview, "It is 6.")
    }

    func testCostAccumulatesAcrossMessagesAndCompaction() throws {
        let url = write([
            #"{"type":"session","id":"sess-4","cwd":"/Users/x/code"}"#,
            #"{"type":"message","id":"e1","message":{"role":"assistant","content":"ok","usage":{"cost":{"total":0.5}}}}"#,
            #"{"type":"compaction","id":"e2","summary":"trimmed","usage":{"cost":{"total":0.25}}}"#
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.cost ?? 0, 0.75, accuracy: 0.0001)
    }

    func testMissingSessionEntryFallsBackToFilenameAndFileCwd() throws {
        let url = write([messageLine(role: "user", text: "hi", id: "e1")], name: "019f9dea-abc.jsonl")
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.id, "019f9dea-abc")
        XCTAssertEqual(thread.cwd, tempDirectory.standardizedFileURL.path)
    }

    func testEmptyFileThrowsRatherThanProducingAPhantomThread() throws {
        let url = write([])
        XCTAssertThrowsError(try SessionThreadParser.thread(at: url))
    }

    func testDefaultsForRunningUnreadArchivedAreFalseForTheCallerToOverlay() throws {
        let url = write([
            #"{"type":"session","id":"sess-5","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "hi", id: "e1")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertFalse(thread.running)
        XCTAssertFalse(thread.unread)
        XCTAssertFalse(thread.archived)
        XCTAssertNil(thread.contextPercent)
    }

    // MARK: - messages(at:limit:)

    func testMessagesReturnsOnlyTheLastNInFileOrder() throws {
        let lines = (1...10).map { messageLine(role: $0 % 2 == 0 ? "assistant" : "user", text: "msg \($0)", timestampMs: $0, id: "e\($0)") }
        let url = write([#"{"type":"session","id":"sess-6","cwd":"/Users/x/code"}"#] + lines)
        let messages = try SessionThreadParser.messages(at: url, limit: 3)
        XCTAssertEqual(messages.map(\.text), ["msg 8", "msg 9", "msg 10"])
    }

    func testMessagesMapsRolesAndBashExecutionToToolResult() throws {
        let url = write([
            #"{"type":"session","id":"sess-7","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "run ls", id: "e1"),
            messageLine(role: "bashExecution", text: "file1 file2", id: "e2"),
            messageLine(role: "assistant", text: "done", id: "e3")
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.map(\.role), [.user, .toolResult, .assistant])
    }

    func testMessagesSynthesizesSystemEntriesForCompactionAndBranchSummary() throws {
        let url = write([
            #"{"type":"session","id":"sess-8","cwd":"/Users/x/code"}"#,
            #"{"type":"compaction","id":"e1","summary":"trimmed the middle","timestamp":1}"#,
            #"{"type":"branch_summary","id":"e2","summary":"forked here","timestamp":2}"#
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].text.contains("trimmed the middle"))
        XCTAssertTrue(messages[1].text.contains("forked here"))
    }

    func testMessagesMarksErrorFlag() throws {
        let url = write([
            #"{"type":"session","id":"sess-9","cwd":"/Users/x/code"}"#,
            messageLine(role: "assistant", text: "boom", id: "e1", isError: true)
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.first?.isError, true)
    }

    func testMessagesToleratesUnknownEntryTypesByIgnoringThem() throws {
        let url = write([
            #"{"type":"session","id":"sess-10","cwd":"/Users/x/code"}"#,
            #"{"type":"a_future_entry_type","id":"e1","payload":{"whatever":true}}"#,
            messageLine(role: "user", text: "still works", id: "e2")
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.map(\.text), ["still works"])
    }

    func testMessagesZeroLimitReturnsEmpty() throws {
        let url = write([messageLine(role: "user", text: "hi", id: "e1")])
        XCTAssertEqual(try SessionThreadParser.messages(at: url, limit: 0), [])
    }

    // MARK: - SessionScanner

    func testScannerFindsRootAndOneLevelProjectFilesButNotDeeperNesting() throws {
        let root = tempDirectory!
        let project = root.appendingPathComponent("--Users-x-code--", isDirectory: true)
        let deep = project.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        try "{}".write(to: root.appendingPathComponent("top.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: project.appendingPathComponent("child.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: deep.appendingPathComponent("nested.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

        let found = Set(SessionScanner.discoverSessionFiles(rootURL: root).map(\.lastPathComponent))
        XCTAssertEqual(found, ["top.jsonl", "child.jsonl"])
    }

    func testScannerReturnsEmptyForMissingRootInsteadOfThrowing() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist")
        XCTAssertEqual(SessionScanner.discoverSessionFiles(rootURL: missing), [])
    }

    // MARK: - Real session directory smoke test

    /// Mirrors the app's own `testInstalledSessionDirectorySmokeWhenRequested` convention
    /// (`Tests/PiDesktopTests/SessionParserTests.swift`): skipped by default, opt in with
    /// `PI_DESKTOP_REAL_SESSION_SMOKE=1 swift test` to scan whatever sessions are actually
    /// installed and prove the parser survives real, messy data instead of only fixtures.
    func testInstalledSessionDirectorySmokeWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["PI_DESKTOP_REAL_SESSION_SMOKE"] == "1" else {
            throw XCTSkip("Set PI_DESKTOP_REAL_SESSION_SMOKE=1 to scan the installed Pi session directory")
        }
        let root = SessionScanner.defaultRootURL()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("No installed Pi session directory")
        }
        let files = SessionScanner.discoverSessionFiles(rootURL: root)
        XCTAssertFalse(files.isEmpty)

        var parsed = 0
        for file in files {
            let thread = try SessionThreadParser.thread(at: file)
            XCTAssertFalse(thread.id.isEmpty)
            XCTAssertFalse(thread.cwd.isEmpty)
            let messages = try SessionThreadParser.messages(at: file, limit: 20)
            XCTAssertLessThanOrEqual(messages.count, 20)
            parsed += 1
        }
        XCTAssertEqual(parsed, files.count, "every real session file must parse without throwing")
    }
}
