import XCTest
@testable import PatchworkKit

/// The daemon's own thread parser reading Codex and Claude transcripts through
/// `AgentSessionTranscoder`, using real JSONL fixtures rather than a provider call.
final class MultiAgentThreadParserTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("patchworkkit-multiagent-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Codex

    private let codexSession = #"{"type":"session_meta","timestamp":"2026-07-31T09:00:00.000Z","payload":{"session_id":"cdx-1","cwd":"/Users/x/code/app","timestamp":"2026-07-31T09:00:00.000Z"}}"#

    func testCodexRolloutBecomesAThreadWithTitleAndAssistantPreview() throws {
        let url = write([
            codexSession,
            #"{"type":"response_item","timestamp":"2026-07-31T09:00:01.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the failing build"}]}}"#,
            #"{"type":"response_item","timestamp":"2026-07-31T09:00:09.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Build is green again."}]}}"#
        ], name: "rollout-2026-07-31T09-00-00-cdx1.jsonl")

        let thread = try SessionThreadParser.thread(at: url, transcoder: .make(for: .codex))
        XCTAssertEqual(thread.id, "cdx-1")
        XCTAssertEqual(thread.cwd, "/Users/x/code/app")
        XCTAssertEqual(thread.folder, "app")
        XCTAssertEqual(thread.name, "Fix the failing build")
        XCTAssertEqual(thread.preview, "Build is green again.")
    }

    func testCodexSubagentRolloutIsNotAUserThread() {
        let url = write([
            #"{"type":"session_meta","payload":{"session_id":"cdx-sub","cwd":"/Users/x/code","thread_source":"subagent"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"internal task"}]}}"#
        ], name: "rollout-sub.jsonl")

        XCTAssertThrowsError(try SessionThreadParser.thread(at: url, transcoder: .make(for: .codex))) { error in
            guard case SessionThreadParser.ParseError.subsession = error else {
                return XCTFail("a subagent rollout must be reported as a subsession, got \(error)")
            }
        }
    }

    /// A rollout is a linear log with no parent pointers, so every record is on the active path.
    func testCodexMessagesArriveInFileOrder() throws {
        let url = write([
            codexSession,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"three"}]}}"#
        ], name: "rollout-order.jsonl")

        let messages = try SessionThreadParser.messages(at: url, limit: 10, transcoder: .make(for: .codex))
        XCTAssertEqual(messages.map(\.text), ["one", "two", "three"])
    }

    func testCodexRecordsTheDefaultParserCannotReadAreSkippedNotFatal() throws {
        let url = write([
            codexSession,
            #"{"type":"world_state","payload":{"anything":1}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"still here"}]}}"#
        ], name: "rollout-unknown.jsonl")

        let thread = try SessionThreadParser.thread(at: url, transcoder: .make(for: .codex))
        XCTAssertEqual(thread.preview, "still here")
    }

    // MARK: - Claude

    func testClaudeThreadReadsCwdAndSessionIDFromConversationEntries() throws {
        // Claude writes no session header at all: the identity rides on every entry.
        let url = write([
            #"{"type":"user","uuid":"u1","sessionId":"claude-1","cwd":"/Users/x/code/site","timestamp":"2026-07-31T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Audit the CSS"}]}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"claude-1","cwd":"/Users/x/code/site","timestamp":"2026-07-31T10:00:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Removed four dead rules."}]}}"#
        ], name: "claude-1.jsonl")

        let thread = try SessionThreadParser.thread(at: url, transcoder: .make(for: .claude))
        XCTAssertEqual(thread.id, "claude-1")
        XCTAssertEqual(thread.cwd, "/Users/x/code/site")
        XCTAssertEqual(thread.folder, "site")
        XCTAssertEqual(thread.name, "Audit the CSS")
        XCTAssertEqual(thread.preview, "Removed four dead rules.")
    }

    /// Claude's title arrives as an id-less `session_info`, which must still win over the first
    /// user prompt even though it is on no entry chain.
    func testClaudeIDLessTitleRecordNamesTheThread() throws {
        let url = write([
            #"{"type":"user","uuid":"u1","sessionId":"claude-2","cwd":"/Users/x/code","message":{"role":"user","content":[{"type":"text","text":"first prompt"}]}}"#,
            #"{"type":"custom-title","customTitle":"CSS audit"}"#
        ], name: "claude-2.jsonl")

        let thread = try SessionThreadParser.thread(at: url, transcoder: .make(for: .claude))
        XCTAssertEqual(thread.name, "CSS audit")
    }

    func testClaudeSidechainTurnsAreNotPartOfTheThread() throws {
        let url = write([
            #"{"type":"user","uuid":"u1","sessionId":"claude-3","cwd":"/Users/x/code","message":{"role":"user","content":[{"type":"text","text":"main task"}]}}"#,
            #"{"type":"assistant","uuid":"s1","isSidechain":true,"sessionId":"claude-3","cwd":"/Users/x/code","message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"claude-3","cwd":"/Users/x/code","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#
        ], name: "claude-3.jsonl")

        let messages = try SessionThreadParser.messages(at: url, limit: 10, transcoder: .make(for: .claude))
        XCTAssertEqual(messages.map(\.text), ["main task", "done"])
    }

    // MARK: - Pi is unchanged

    func testPiTranscoderIsStillTheIdentityPath() throws {
        let url = write([
            #"{"type":"session","id":"pi-1","cwd":"/Users/x/code"}"#,
            #"{"type":"message","id":"u","message":{"role":"user","content":"hello"}}"#
        ])
        let explicit = try SessionThreadParser.thread(at: url, transcoder: .pi)
        let defaulted = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(explicit, defaulted)
        XCTAssertEqual(defaulted.agent, .pi)
    }

    func testPiSessionMarkedSubsessionIsAlsoRefused() {
        let url = write([
            #"{"type":"session","id":"pi-sub","cwd":"/Users/x/code","subsession":true}"#,
            #"{"type":"message","id":"u","message":{"role":"user","content":"nested"}}"#
        ])
        XCTAssertThrowsError(try SessionThreadParser.thread(at: url)) { error in
            guard case SessionThreadParser.ParseError.subsession = error else {
                return XCTFail("expected subsession, got \(error)")
            }
        }
    }
}

/// `PatchworkThread`/`Schedule`/`Run` gaining an agent must not change how older wire data decodes.
final class AgentWireCompatibilityTests: XCTestCase {
    private func decode<Value: Decodable>(_ json: String, as type: Value.Type) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testThreadWithoutAnAgentFieldDecodesAsPi() throws {
        let thread = try decode(#"{"id":"t1","path":"/tmp/t1.jsonl","name":"Old"}"#, as: PatchworkThread.self)
        XCTAssertEqual(thread.agent, .pi)
    }

    func testUnknownAgentNameDoesNotFailTheThreadList() throws {
        let response = try decode(
            #"{"threads":[{"id":"t1","agent":"gemini"},{"id":"t2","agent":"codex"}]}"#,
            as: ThreadListResponse.self
        )
        XCTAssertEqual(response.threads.map(\.agent), [.pi, .codex])
    }

    func testThreadRoundTripsItsAgent() throws {
        let original = PatchworkThread(
            id: "t1", path: "/tmp/t1.jsonl", name: "Codex thread", cwd: "/tmp", folder: "tmp",
            createdAt: .distantPast, updatedAt: .distantPast, agent: .codex
        )
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(PatchworkThread.self, from: encoded).agent, .codex)
    }

    func testCreateThreadRequestWithoutAnAgentMeansPi() throws {
        let request = try decode(#"{"cwd":"/tmp"}"#, as: CreateThreadRequest.self)
        XCTAssertNil(request.agent)
        XCTAssertEqual(try decode(#"{"cwd":"/tmp","agent":"claude"}"#, as: CreateThreadRequest.self).agent, .claude)
    }

    func testScheduleAndRunWithoutAnAgentStillDecode() throws {
        let schedule = try decode(
            #"{"id":"sch_1","name":"n","target":{"kind":"newThread","cwd":"/tmp"},"trigger":{"kind":"heartbeat","everySeconds":900}}"#,
            as: Schedule.self
        )
        XCTAssertNil(schedule.agent)
        let run = try decode(#"{"id":"run_1","status":"ok","trigger":"api"}"#, as: Run.self)
        XCTAssertNil(run.agent)
    }
}
