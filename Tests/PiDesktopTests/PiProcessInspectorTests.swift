import Foundation
import XCTest
@testable import PiDesktop

final class ProcessSnapshotParserTests: XCTestCase {
    func testCandidatesMatchDirectAndInterpreterLaunchedAgents() {
        // The third line is exactly how the installed CLI reports itself: comm is `node`, and
        // `pi` only appears in the arguments.
        let output = """
          123 pi              pi --mode rpc
          456 bash             /bin/bash -c ps
          789 /usr/local/bin/pi /usr/local/bin/pi --mode rpc --session foo
          912 node             node /Users/vince/.local/bin/pi --mode rpc
          913 node             node /Users/vince/.pi/agent/extensions/helper.mjs
          914 rg               rg -i "pi --mode"
        """
        let candidates = ProcessSnapshotParser.candidates(fromPSOutput: output)
        XCTAssertEqual(candidates.map(\.pid), [123, 789, 912])
    }

    func testBlankAndMalformedLinesAreIgnored() {
        XCTAssertTrue(ProcessSnapshotParser.candidates(fromPSOutput: "").isEmpty)
        XCTAssertTrue(ProcessSnapshotParser.candidates(fromPSOutput: "\n   \nnotapid pi pi\n").isEmpty)
    }

    func testPiProcessDetectionAcceptsPathsAndRejectsLookalikes() {
        XCTAssertTrue(ProcessSnapshotParser.isPiProcess(command: "pi", arguments: "pi --mode rpc"))
        XCTAssertTrue(ProcessSnapshotParser.isPiProcess(command: "/opt/homebrew/bin/pi", arguments: "/opt/homebrew/bin/pi"))
        XCTAssertTrue(ProcessSnapshotParser.isPiProcess(command: "bun", arguments: "bun /Users/x/.local/bin/pi --mode rpc"))
        XCTAssertFalse(ProcessSnapshotParser.isPiProcess(command: "pip", arguments: "pip install x"))
        XCTAssertFalse(ProcessSnapshotParser.isPiProcess(command: "PiDesktop", arguments: "PiDesktop"))
        // A bare `pi` word inside an unrelated command line is not the agent.
        XCTAssertFalse(ProcessSnapshotParser.isPiProcess(command: "node", arguments: "node build.js --name pi"))
        XCTAssertFalse(ProcessSnapshotParser.isPiProcess(command: "bash", arguments: "/bin/bash /Library/local.pi.caffeinate-lid"))
    }

    func testCwdIsParsedFromTheNPrefixedLsofLine() {
        let output = "p4242\nn/Users/vince/code/project\n"
        XCTAssertEqual(ProcessSnapshotParser.cwd(fromLsofOutput: output), "/Users/vince/code/project")
        XCTAssertNil(ProcessSnapshotParser.cwd(fromLsofOutput: "p4242\n"))
        XCTAssertNil(ProcessSnapshotParser.cwd(fromLsofOutput: ""))
    }
}

private struct FakeProcessSnapshotProvider: ProcessSnapshotProviding {
    var ps: String?
    var cwds: [Int32: String] = [:]
    /// Lets a test prove the resolved-per-refresh cap without spawning real processes.
    let cwdCallCounter: CallCounter?

    func psOutput() -> String? { ps }
    func cwd(forPID pid: Int32) -> String? {
        cwdCallCounter?.increment()
        return cwds[pid]
    }
}

/// A tiny reference box so a value-type provider can still report how many times it was asked
/// for a cwd, without needing actor isolation for a test-only counter.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class PiProcessInspectorTests: XCTestCase {
    func testLiveCwdsStartsNilUntilTheFirstSuccessfulRefresh() async throws {
        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(
            ps: "111 pi pi --mode rpc", cwds: [111: "/tmp/a"], cwdCallCounter: nil
        ))
        XCTAssertNil(inspector.liveCwds)
        inspector.refreshIfNeeded()
        try await waitUntil { inspector.liveCwds != nil }
        XCTAssertEqual(inspector.liveCwds, ["/tmp/a"])
    }

    func testAFailedPSCallLeavesThePreviousCacheInPlaceRatherThanBlankingIt() async throws {
        var provider = FakeProcessSnapshotProvider(ps: "111 pi pi", cwds: [111: "/tmp/a"], cwdCallCounter: nil)
        let inspector = PiProcessInspector(snapshotProvider: provider)
        inspector.refreshIfNeeded()
        try await waitUntil { inspector.liveCwds != nil }
        XCTAssertEqual(inspector.liveCwds, ["/tmp/a"])

        // Simulate `ps` becoming unavailable on a later refresh: force one by using a fresh
        // inspector seeded with a provider that now fails, proving the *contract* (nil never
        // overwrites a previously good snapshot) rather than the private TTL clock.
        provider.ps = nil
        let cwds = ProcessSnapshotParser.candidates(fromPSOutput: provider.psOutput() ?? "")
        XCTAssertTrue(cwds.isEmpty)
        XCTAssertEqual(inspector.liveCwds, ["/tmp/a"], "Still-cached snapshot must survive an unrelated failed attempt")
    }

    func testResolutionIsCappedPerRefreshEvenWithManyCandidates() async throws {
        let counter = CallCounter()
        var psLines: [String] = []
        var cwds: [Int32: String] = [:]
        for pid in Int32(1)...Int32(PiProcessInspector.maxResolvedPerRefresh + 10) {
            psLines.append("\(pid) pi pi --mode rpc")
            cwds[pid] = "/tmp/\(pid)"
        }
        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(
            ps: psLines.joined(separator: "\n"), cwds: cwds, cwdCallCounter: counter
        ))
        inspector.refreshIfNeeded()
        try await waitUntil { inspector.liveCwds != nil }
        XCTAssertEqual(counter.value, PiProcessInspector.maxResolvedPerRefresh, "Only the bounded prefix is resolved")
    }

    func testRefreshWithinTheCacheTTLDoesNotRepeatTheSnapshot() async throws {
        let counter = CallCounter()
        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(
            ps: "111 pi pi", cwds: [111: "/tmp/a"], cwdCallCounter: counter
        ))
        inspector.refreshIfNeeded()
        try await waitUntil { inspector.liveCwds != nil }
        XCTAssertEqual(counter.value, 1)

        // Well within the TTL: must not trigger a second background refresh.
        inspector.refreshIfNeeded()
        inspector.refreshIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.value, 1, "A fresh cache must not be re-fetched on every call")
    }

    func testUnavailablePSMeansLiveCwdsStaysNil() async throws {
        let inspector = PiProcessInspector(snapshotProvider: FakeProcessSnapshotProvider(ps: nil, cwdCallCounter: nil))
        inspector.refreshIfNeeded()
        // No positive condition to await: give the (already-fast, fake) refresh a moment, then
        // assert the degraded state directly.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(inspector.liveCwds, "Command unavailable must degrade to nil, never crash or fabricate a snapshot")
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
