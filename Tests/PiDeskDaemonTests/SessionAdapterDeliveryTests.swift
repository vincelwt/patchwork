import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// An adapter can answer a command from its own state without anything reaching the process.
/// That answer has to arrive through the ordinary receive path, or the caller waits out its whole
/// timeout for a response that was ready immediately — which is exactly what happened against the
/// real `codex app-server` until this was covered.
final class SessionAdapterDeliveryTests: XCTestCase {
    /// Answers every command locally and writes nothing, so no process is involved at all.
    private final class LocalAdapter: AgentProtocolAdapter {
        let agent: AgentKind = .pi
        var unsupported: Set<String> = []

        func launchArguments(sessionPath: URL?, cwd: URL) -> [String] { ["--version"] }

        func encode(command: String, id: String, payload: [String: PiJSONValue]) -> AdapterOutbound {
            if unsupported.contains(command) { return .unsupported("the \(command) command") }
            return .immediate(.object(["echoed": .string(command)]))
        }

        func encodeUncorrelated(_ value: PiJSONValue) -> [Data] { [] }
        func decode(line: Data) -> [AdapterInbound] { [] }
    }

    private func makeSession(_ adapter: AgentProtocolAdapter) throws -> PiRPCSession {
        // `/bin/cat` never writes on its own, so anything the caller receives can only have come
        // from the adapter rather than from the process.
        try PiRPCSession.start(
            cwd: FileManager.default.temporaryDirectory, sessionPath: nil,
            piExecutable: URL(fileURLWithPath: "/bin/cat"), environment: [:], adapter: adapter
        )
    }

    func testALocallyAnsweredCommandArrivesThroughTheOrdinaryReceivePath() async throws {
        let session = try makeSession(LocalAdapter())
        defer { session.stop() }
        let id = try session.send(type: "get_state")
        let response = try await session.receiveMatching(id: id, timeout: 2)
        XCTAssertEqual(response["data"]?["echoed"]?.stringValue, "get_state")
    }

    /// The same answer must also be visible to a caller that is not the one draining output.
    func testALocallyAnsweredCommandIsAlsoVisibleToANonDrainingCaller() async throws {
        let session = try makeSession(LocalAdapter())
        defer { session.stop() }
        let id = try session.send(type: "get_session_stats")
        let cached = await session.awaitCachedResponse(id: id, timeout: 2)
        XCTAssertEqual(cached?["data"]?["echoed"]?.stringValue, "get_session_stats")
    }

    func testTwoLocalAnswersArriveInOrderAndEachExactlyOnce() async throws {
        let session = try makeSession(LocalAdapter())
        defer { session.stop() }
        let first = try session.send(type: "one")
        let second = try session.send(type: "two")
        let firstResponse = try await session.receiveMatching(id: first, timeout: 2)
        XCTAssertEqual(firstResponse["data"]?["echoed"]?.stringValue, "one")
        let secondResponse = try await session.receiveMatching(id: second, timeout: 2)
        XCTAssertEqual(secondResponse["data"]?["echoed"]?.stringValue, "two")
    }

    /// A command the agent has no equivalent for fails the caller rather than stranding it.
    func testAnUnsupportedCommandThrowsRatherThanTimingOut() throws {
        let adapter = LocalAdapter()
        adapter.unsupported = ["export_html"]
        let session = try makeSession(adapter)
        defer { session.stop() }
        XCTAssertThrowsError(try session.send(type: "export_html")) { error in
            guard case let RunnerError.unsupportedCommand(agent, _) = error else {
                return XCTFail("expected unsupportedCommand, got \(error)")
            }
            XCTAssertEqual(agent, .pi)
        }
    }

    /// The launch arguments come from the adapter, not from a hardcoded `--mode rpc`.
    func testLaunchArgumentsComeFromTheAdapter() {
        XCTAssertEqual(
            PiProtocolAdapter().launchArguments(sessionPath: URL(fileURLWithPath: "/tmp/s.jsonl"), cwd: URL(fileURLWithPath: "/tmp")),
            ["--mode", "rpc", "--session", "/tmp/s.jsonl"]
        )
        XCTAssertEqual(
            CodexProtocolAdapter().launchArguments(sessionPath: nil, cwd: URL(fileURLWithPath: "/tmp")),
            ["app-server", "--stdio"]
        )
    }
}
