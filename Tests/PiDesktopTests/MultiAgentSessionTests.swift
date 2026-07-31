import PiDeskKit
import XCTest
@testable import PiDesktop

/// End-to-end cover for reading another agent's history: the transcoders feed the app's real
/// parser, so these assert on `SessionSummary`/`ConversationPage`, not on intermediate JSON.
final class MultiAgentSessionTests: XCTestCase {
    private var root: URL!
    private var piRoot: URL!
    private var codexRoot: URL!
    private var claudeRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-agent-\(UUID().uuidString)", isDirectory: true)
        piRoot = root.appendingPathComponent("pi", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        for url in [piRoot!, codexRoot!, claudeRoot!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func makeRepository() -> FileSessionRepository {
        FileSessionRepository(
            rootURL: piRoot,
            roots: [(.pi, piRoot), (.codex, codexRoot), (.claude, claudeRoot)],
            summaryCache: SessionSummaryCache(
                fileURL: root.appendingPathComponent("cache-\(UUID().uuidString).json")
            )
        )
    }

    // MARK: - Fixtures

    private func writePiSession() throws -> URL {
        let url = piRoot.appendingPathComponent("pi-thread.jsonl")
        try write([
            #"{"type":"session","id":"pi-1","cwd":"/tmp/pi-project","timestamp":"2026-07-30T10:00:00.000Z"}"#,
            #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-07-30T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"pi question"}]}}"#,
            #"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-07-30T10:00:02.000Z","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"pi answer"}],"usage":{"input":10,"output":4}}}"#
        ], to: url)
        return url
    }

    private func writeCodexSession() throws -> URL {
        let url = codexRoot.appendingPathComponent("2026/07/30/rollout-2026-07-30T10-00-00-abc.jsonl")
        try write([
            #"{"timestamp":"2026-07-30T10:00:00.000Z","type":"session_meta","payload":{"session_id":"cdx-1","cwd":"/tmp/codex-project","timestamp":"2026-07-30T10:00:00.000Z","thread_source":"user"}}"#,
            #"{"timestamp":"2026-07-30T10:00:00.500Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","reasoning_effort":"high"}}"#,
            #"{"timestamp":"2026-07-30T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<app-context>harness</app-context>"}]}}"#,
            #"{"timestamp":"2026-07-30T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"codex question"}]}}"#,
            #"{"timestamp":"2026-07-30T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1","arguments":"{\"cmd\":\"ls\"}"}}"#,
            #"{"timestamp":"2026-07-30T10:00:04.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"file.txt"}}"#,
            #"{"timestamp":"2026-07-30T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":99999},"last_token_usage":{"input_tokens":30,"cached_input_tokens":10,"output_tokens":7}}}}"#,
            #"{"timestamp":"2026-07-30T10:00:06.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex answer"}]}}"#,
            #"{"timestamp":"2026-07-30T10:00:07.000Z","type":"world_state","payload":{"full":true}}"#
        ], to: url)
        return url
    }

    private func writeClaudeSession() throws -> URL {
        let url = claudeRoot.appendingPathComponent("-tmp-claude-project/sess-1.jsonl")
        try write([
            #"{"type":"user","uuid":"u1","parentUuid":null,"cwd":"/tmp/claude-project","sessionId":"sess-1","timestamp":"2026-07-30T10:00:01.000Z","message":{"role":"user","content":"claude question"}}"#,
            #"{"type":"ai-title","aiTitle":"Claude titled thread","sessionId":"sess-1"}"#,
            #"{"type":"assistant","uuid":"u2","parentUuid":"u1","cwd":"/tmp/claude-project","sessionId":"sess-1","timestamp":"2026-07-30T10:00:02.000Z","message":{"role":"assistant","model":"claude-fable-5","stop_reason":"tool_use","content":[{"type":"thinking","thinking":"planning","signature":"s"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":11,"output_tokens":2,"cache_read_input_tokens":5}}}"#,
            #"{"type":"user","uuid":"u3","parentUuid":"u2","cwd":"/tmp/claude-project","sessionId":"sess-1","timestamp":"2026-07-30T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file.txt"}]}}"#,
            #"{"type":"assistant","uuid":"sc1","parentUuid":"u2","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#,
            #"{"type":"assistant","uuid":"u4","parentUuid":"u3","cwd":"/tmp/claude-project","sessionId":"sess-1","timestamp":"2026-07-30T10:00:04.000Z","message":{"role":"assistant","model":"claude-fable-5","stop_reason":"end_turn","content":[{"type":"text","text":"claude answer"}],"usage":{"input_tokens":13,"output_tokens":6}}}"#,
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"sess-1","content":"ignored"}"#
        ], to: url)
        return url
    }

    // MARK: - Discovery

    func testDiscoveryFindsEveryAgentAndTagsEachSummary() async throws {
        _ = try writePiSession()
        _ = try writeCodexSession()
        _ = try writeClaudeSession()

        let sessions = try await makeRepository().discoverSessions(archivedIDs: [])
        let byAgent = Dictionary(grouping: sessions, by: \.agent)
        XCTAssertEqual(byAgent[.pi]?.count, 1)
        XCTAssertEqual(byAgent[.codex]?.count, 1)
        XCTAssertEqual(byAgent[.claude]?.count, 1)

        XCTAssertEqual(byAgent[.pi]?.first?.cwd.path, "/tmp/pi-project")
        XCTAssertEqual(byAgent[.codex]?.first?.cwd.path, "/tmp/codex-project")
        XCTAssertEqual(byAgent[.claude]?.first?.cwd.path, "/tmp/claude-project")
    }

    /// Codex nests rollouts three directories deep; a one-level scan would find nothing at all.
    func testCodexRolloutsAreFoundThreeDirectoriesDeep() async throws {
        _ = try writeCodexSession()
        let sessions = try await makeRepository().discoverSessions(archivedIDs: [])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "cdx-1")
    }

    func testCodexSubagentRolloutIsNotListed() async throws {
        _ = try writeCodexSession()
        try write([
            #"{"type":"session_meta","payload":{"session_id":"cdx-sub","cwd":"/tmp/codex-project","thread_source":"subagent"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"sub work"}]}}"#
        ], to: codexRoot.appendingPathComponent("2026/07/30/rollout-2026-07-30T11-00-00-sub.jsonl"))

        let sessions = try await makeRepository().discoverSessions(archivedIDs: [])
        XCTAssertEqual(sessions.map(\.id), ["cdx-1"])
    }

    /// Codex writes other JSONL under its tree; only `rollout-` files are conversations.
    func testCodexNonRolloutFilesAreIgnored() async throws {
        _ = try writeCodexSession()
        try write([#"{"type":"session_meta","payload":{"session_id":"nope","cwd":"/x"}}"#],
                  to: codexRoot.appendingPathComponent("2026/07/30/notes.jsonl"))
        let sessions = try await makeRepository().discoverSessions(archivedIDs: [])
        XCTAssertEqual(sessions.map(\.id), ["cdx-1"])
    }

    // MARK: - Summaries

    func testCodexSummaryUsesTheFirstRealUserTurnNotTheHarnessContext() async throws {
        let url = try writeCodexSession()
        let summary = try await makeRepository().refreshSummary(at: url, archivedIDs: [])
        XCTAssertEqual(summary.agent, .codex)
        XCTAssertEqual(summary.preview, "codex question")
        XCTAssertEqual(summary.model, "gpt-5.6-sol")
        XCTAssertEqual(summary.thinkingLevel, "high")
        // Only the last-turn delta counts, and the cached portion is split out of input.
        XCTAssertEqual(summary.metrics.input, 20)
        XCTAssertEqual(summary.metrics.cacheRead, 10)
        XCTAssertEqual(summary.metrics.output, 7)
    }

    func testClaudeSummaryTakesItsNameFromTheIdlessTitleRecord() async throws {
        let url = try writeClaudeSession()
        let summary = try await makeRepository().refreshSummary(at: url, archivedIDs: [])
        XCTAssertEqual(summary.agent, .claude)
        XCTAssertEqual(summary.name, "Claude titled thread")
        XCTAssertEqual(summary.id, "sess-1")
        XCTAssertEqual(summary.cwd.path, "/tmp/claude-project")
        XCTAssertEqual(summary.model, "claude-fable-5")
        XCTAssertEqual(summary.metrics.cacheRead, 5)
    }

    func testPiSummaryIsUnchangedByTheTranscoderSeam() async throws {
        let url = try writePiSession()
        let summary = try await makeRepository().refreshSummary(at: url, archivedIDs: [])
        XCTAssertEqual(summary.agent, .pi)
        XCTAssertEqual(summary.id, "pi-1")
        XCTAssertEqual(summary.preview, "pi question")
        XCTAssertEqual(summary.metrics.input, 10)
    }

    // MARK: - Transcripts

    func testCodexLinearTranscriptRendersEveryTurnInOrder() async throws {
        let url = try writeCodexSession()
        let conversation = try await makeRepository().loadConversation(from: url)
        let roles = conversation.messages.map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(conversation.messages.first?.textContent, "codex question")
        XCTAssertEqual(conversation.messages.last?.textContent, "codex answer")

        let call = conversation.messages[1]
        guard case let .toolCall(payload) = call.blocks.first?.kind else {
            return XCTFail("expected a tool call block")
        }
        XCTAssertEqual(payload.name, "exec_command")
        XCTAssertEqual(conversation.messages[2].toolCallID, "call_1")
    }

    /// The backward pager and the forward parser have to agree, or opening a conversation shows
    /// something different from scrolling back into it.
    func testCodexPagingAgreesWithFullParse() async throws {
        let url = try writeCodexSession()
        let repository = makeRepository()
        let full = try await repository.loadConversation(from: url)
        let page = try await repository.loadNewestConversationPage(from: url)
        XCTAssertEqual(page.messages.map(\.id), full.messages.map(\.id))
        XCTAssertEqual(page.leafID, full.messages.last?.id)
        XCTAssertTrue(page.hasNoMoreHistory)
    }

    func testCodexPagingWalksBackwardsAcrossPages() async throws {
        let url = try writeCodexSession()
        let repository = makeRepository()
        let full = try await repository.loadConversation(from: url)

        var collected: [String] = []
        var page = try SessionParser.conversationPage(
            at: url, target: 1, alignToTurnBoundary: false, transcoder: .make(for: .codex)
        )
        collected.insert(contentsOf: page.messages.map(\.id), at: 0)
        var guardrail = 0
        while let cursor = page.olderCursor, guardrail < 20 {
            guardrail += 1
            page = try SessionParser.conversationPage(
                at: url, cursor: cursor, target: 1, alignToTurnBoundary: false, transcoder: .make(for: .codex)
            )
            collected.insert(contentsOf: page.messages.map(\.id), at: 0)
        }
        XCTAssertEqual(collected, full.messages.map(\.id))
    }

    func testClaudeTranscriptFollowsRealParentPointersAndDropsSidechains() async throws {
        let url = try writeClaudeSession()
        let conversation = try await makeRepository().loadConversation(from: url)
        XCTAssertEqual(conversation.messages.map(\.id), ["u1", "u2", "u3", "u4"])
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertFalse(
            conversation.messages.contains { $0.textContent.contains("subagent chatter") },
            "a sidechain turn is a separate transcript"
        )
        XCTAssertEqual(conversation.messages[2].toolCallID, "toolu_1")
        XCTAssertEqual(conversation.messages[1].stopReason, "toolUse")
        XCTAssertEqual(conversation.messages[3].stopReason, "stop")
    }

    func testClaudeTailScanMatchesTheFullParse() async throws {
        let url = try writeClaudeSession()
        let repository = makeRepository()
        let full = try await repository.loadConversation(from: url)
        let tail = try await repository.loadConversationTail(from: url, limit: 50)
        XCTAssertEqual(tail.conversation.messages.map(\.id), full.messages.map(\.id))
        XCTAssertTrue(tail.isComplete)
    }

    func testAgentForFileURLResolvesFromTheOwningRoot() throws {
        let repository = makeRepository()
        XCTAssertEqual(repository.agent(for: piRoot.appendingPathComponent("x.jsonl")), .pi)
        XCTAssertEqual(repository.agent(for: codexRoot.appendingPathComponent("2026/07/30/rollout-a.jsonl")), .codex)
        XCTAssertEqual(repository.agent(for: claudeRoot.appendingPathComponent("p/a.jsonl")), .claude)
    }

    /// Opt-in scan of the machine's real Codex and Claude history. Fixtures cannot cover the
    /// shapes a year of real transcripts contains, and this is read-only: it parses files and
    /// asserts the results are sane, and never launches an agent or sends a prompt.
    /// Enable with `PI_DESKTOP_REAL_SESSION_SMOKE=1 swift test`.
    func testRealInstalledHistoryParsesWhenRequested() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PI_DESKTOP_REAL_SESSION_SMOKE"] == "1",
            "Set PI_DESKTOP_REAL_SESSION_SMOKE=1 to scan the installed session directories"
        )
        let repository = FileSessionRepository(
            summaryCache: SessionSummaryCache(
                fileURL: root.appendingPathComponent("real-smoke-\(UUID().uuidString).json")
            )
        )
        let sessions = try await repository.discoverSessions(archivedIDs: [])
        for agent in AgentKind.allCases {
            let owned = sessions.filter { $0.agent == agent }
            guard let newest = owned.first else { continue }
            XCTAssertFalse(newest.displayName.isEmpty, "\(agent) summary needs a name")
            XCTAssertFalse(newest.isSubsession, "a subsession must never be listed")
            let page = try await repository.loadNewestConversationPage(from: newest.fileURL)
            XCTAssertLessThanOrEqual(page.messages.count, ConversationPage.maximumMessageCount)
            let unknown = page.messages.filter { $0.role == .unknown }
            XCTAssertLessThanOrEqual(
                Double(unknown.count), Double(max(1, page.messages.count)) * 0.2,
                "\(agent): too many records fell through to the unknown fallback"
            )
        }
    }

    func testEmptyAndMalformedSessionsDoNotBreakDiscovery() async throws {
        _ = try writePiSession()
        try write([""], to: codexRoot.appendingPathComponent("2026/07/30/rollout-empty.jsonl"))
        try write(["not json", "{", #"{"type":"response_item"}"#],
                  to: codexRoot.appendingPathComponent("2026/07/30/rollout-broken.jsonl"))
        let sessions = try await makeRepository().discoverSessions(archivedIDs: [])
        XCTAssertTrue(sessions.contains { $0.agent == .pi })
        // The broken files still produce bounded, listable placeholders rather than throwing.
        XCTAssertEqual(sessions.count, 3)
    }
}
