import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

private final class CrossAgentSubmissionRuntime: AgentRuntimeProtocol {
    let agent: AgentKind
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    private(set) var promptCount = 0
    private var sessionFile = ""
    private var sessionID = ""
    private var streaming = false

    init(agent: AgentKind) { self.agent = agent }

    func start(cwd: URL, sessionPath: URL?) throws {
        isRunning = true
        sessionFile = sessionPath?.standardizedFileURL.path ?? cwd.appendingPathComponent("new.jsonl").path
        sessionID = sessionPath?.deletingPathExtension().lastPathComponent ?? "new"
    }

    func stop() { isRunning = false }

    func send(
        type: String,
        payload: [String: JSONValue],
        completion: ((Result<JSONValue, Error>) -> Void)?
    ) {
        let data: JSONValue
        switch type {
        case "get_state":
            data = .object([
                "isStreaming": .bool(streaming),
                "sessionFile": .string(sessionFile),
                "sessionId": .string(sessionID)
            ])
        case "get_available_models":
            data = .object(["models": .array([])])
        case "get_available_thinking_levels":
            data = .object(["levels": .array([.string("off")])])
        case "prompt":
            promptCount += 1
            streaming = true
            data = .object([:])
        default:
            data = .object([:])
        }
        completion?(.success(.object(["success": .bool(true), "data": data])))
    }

    func sendUncorrelated(_ value: JSONValue) {}
}

private struct CrossAgentSubmissionGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

/// Covers the two submission acknowledgements the app has to reconcile: Pi publishes the user
/// message live, while Codex and Claude normally expose it when their native transcript reaches
/// disk. No agent process is launched and no provider prompt is sent.
@MainActor
final class AppStoreCrossAgentSubmissionTests: XCTestCase {
    private var root: URL!
    private var piRoot: URL!
    private var codexRoot: URL!
    private var claudeRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiCrossAgentSubmission-\(UUID().uuidString)", isDirectory: true)
        piRoot = root.appendingPathComponent("pi", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        for directory in [piRoot!, codexRoot!, claudeRoot!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDurableEchoReplacesOneOptimisticRowForEveryAgentWithoutHidingARepeatedPrompt() async throws {
        for agent in AgentKind.allCases {
            let file = try writeInitialTranscript(for: agent)
            let repository = FileSessionRepository(
                rootURL: piRoot,
                roots: [(.pi, piRoot), (.codex, codexRoot), (.claude, claudeRoot)],
                summaryCache: SessionSummaryCache(
                    fileURL: root.appendingPathComponent("summary-\(agent.rawValue).json")
                )
            )
            let summary = try await repository.refreshSummary(at: file, archivedIDs: [])
            let targetRuntime = CrossAgentSubmissionRuntime(agent: agent)
            let initialRuntime = agent == .pi
                ? targetRuntime
                : CrossAgentSubmissionRuntime(agent: .pi)
            let store = AppStore(
                repository: repository,
                gitService: CrossAgentSubmissionGitService(),
                runtime: initialRuntime,
                runtimeFactory: { kind in
                    kind == agent ? targetRuntime : CrossAgentSubmissionRuntime(agent: kind)
                },
                persistence: AppPersistence(
                    baseURL: root.appendingPathComponent("state-\(agent.rawValue)", isDirectory: true)
                ),
                activityPresenter: ActivityPresenter(),
                isActiveOverride: true,
                runtimeRetirementScheduler: { _, _ in {} }
            )
            store.cachedScheduleService = InMemoryScheduleService()
            store.sessions = [summary]
            store.selectSession(summary)
            try await waitUntil {
                !store.isConversationLoading
                    && store.messages.filter { $0.role == .user && $0.textContent == "repeat me" }.count == 1
            }

            store.draft = "repeat me"
            store.submitDraft()
            XCTAssertEqual(targetRuntime.promptCount, 1, agent.rawValue)
            XCTAssertEqual(
                store.messages.filter { $0.role == .user && $0.textContent == "repeat me" }.count,
                2,
                "\(agent.rawValue): the old durable turn and the new optimistic turn are both real"
            )
            XCTAssertEqual(store.messages.filter { $0.id.hasPrefix("local-") }.count, 1, agent.rawValue)

            try appendDurableUser(to: file, agent: agent)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)],
                ofItemAtPath: file.path
            )
            store.selectSession(summary)
            try await waitUntil {
                store.messages.contains { $0.id == "new-user" }
                    && !store.messages.contains { $0.id.hasPrefix("local-") }
            }

            XCTAssertEqual(targetRuntime.promptCount, 1, "\(agent.rawValue): hydration must never resend")
            XCTAssertEqual(
                store.messages.filter { $0.role == .user && $0.textContent == "repeat me" }.count,
                2,
                "\(agent.rawValue): exactly one row per intentional submission"
            )
        }
    }

    private func writeInitialTranscript(for agent: AgentKind) throws -> URL {
        let file: URL
        let lines: [[String: Any]]
        switch agent {
        case .pi:
            file = piRoot.appendingPathComponent("pi.jsonl")
            lines = [
                ["type": "session", "id": "pi-thread", "cwd": root.path],
                [
                    "type": "message", "id": "old-user", "parentId": NSNull(),
                    "timestamp": "2020-01-01T00:00:01.000Z",
                    "message": ["role": "user", "content": "repeat me"]
                ],
                [
                    "type": "message", "id": "old-answer", "parentId": "old-user",
                    "timestamp": "2020-01-01T00:00:02.000Z",
                    "message": ["role": "assistant", "content": "old answer", "stopReason": "stop"]
                ]
            ]
        case .codex:
            file = codexRoot.appendingPathComponent("2026/07/31/rollout-cross-agent.jsonl")
            lines = [
                [
                    "timestamp": "2020-01-01T00:00:00.000Z", "type": "session_meta",
                    "payload": ["session_id": "codex-thread", "cwd": root.path, "thread_source": "user"]
                ],
                [
                    "timestamp": "2020-01-01T00:00:01.000Z", "type": "response_item",
                    "payload": [
                        "id": "old-user", "type": "message", "role": "user",
                        "content": [["type": "input_text", "text": "repeat me"]]
                    ]
                ],
                [
                    "timestamp": "2020-01-01T00:00:02.000Z", "type": "response_item",
                    "payload": [
                        "id": "old-answer", "type": "message", "role": "assistant",
                        "phase": "final_answer",
                        "content": [["type": "output_text", "text": "old answer"]]
                    ]
                ]
            ]
        case .claude:
            file = claudeRoot.appendingPathComponent("project/claude-thread.jsonl")
            lines = [
                [
                    "type": "user", "uuid": "old-user", "parentUuid": NSNull(),
                    "sessionId": "claude-thread", "cwd": root.path,
                    "timestamp": "2020-01-01T00:00:01.000Z",
                    "message": ["role": "user", "content": "repeat me"]
                ],
                [
                    "type": "assistant", "uuid": "old-answer", "parentUuid": "old-user",
                    "sessionId": "claude-thread", "cwd": root.path,
                    "timestamp": "2020-01-01T00:00:02.000Z",
                    "message": [
                        "role": "assistant", "stop_reason": "end_turn",
                        "content": [["type": "text", "text": "old answer"]]
                    ]
                ]
            ]
        }
        try write(lines, to: file)
        return file
    }

    private func appendDurableUser(to file: URL, agent: AgentKind) throws {
        let timestamp = ISO8601DateFormatter.piFractional.string(from: Date().addingTimeInterval(1))
        let entry: [String: Any]
        switch agent {
        case .pi:
            entry = [
                "type": "message", "id": "new-user", "parentId": "old-answer",
                "timestamp": timestamp,
                "message": ["role": "user", "content": "repeat me"]
            ]
        case .codex:
            entry = [
                "timestamp": timestamp, "type": "response_item",
                "payload": [
                    "id": "new-user", "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "repeat me"]]
                ]
            ]
        case .claude:
            entry = [
                "type": "user", "uuid": "new-user", "parentUuid": "old-answer",
                "sessionId": "claude-thread", "cwd": root.path, "timestamp": timestamp,
                "message": ["role": "user", "content": "repeat me"]
            ]
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: entry) + Data([0x0A]))
        try handle.synchronize()
    }

    private func write(_ lines: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try lines.reduce(into: Data()) { result, line in
            result.append(try JSONSerialization.data(withJSONObject: line))
            result.append(0x0A)
        }
        try data.write(to: file)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Condition was not met within \(timeout)s")
    }
}

private extension ISO8601DateFormatter {
    static let piFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
