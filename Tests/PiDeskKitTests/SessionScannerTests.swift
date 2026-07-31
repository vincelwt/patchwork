import XCTest
@testable import PiDeskKit

final class SessionScannerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pideskkit-scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    @discardableResult
    private func touch(_ relativePath: String) -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}\n".utf8).write(to: url)
        return url.standardizedFileURL
    }

    private func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

    // MARK: - Per-agent depth and prefix

    func testPiScanStopsOneProjectFolderDeep() {
        let root = tempDirectory.appendingPathComponent("pi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        touch("pi/loose.jsonl")
        touch("pi/project/session.jsonl")
        touch("pi/project/subagents/nested.jsonl")

        let found = SessionScanner.discoverSessionFiles(agent: .pi, rootURL: root)
        XCTAssertEqual(names(found), ["loose.jsonl", "session.jsonl"])
    }

    func testCodexScanReachesDateFoldersAndRequiresRolloutPrefix() {
        let root = tempDirectory.appendingPathComponent("codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        touch("codex/2026/07/31/rollout-2026-07-31T09-00-00-abc.jsonl")
        // Same folder, but not a rollout: Codex writes other JSONL artifacts beside them.
        touch("codex/2026/07/31/history.jsonl")
        // One level deeper than Codex declares — a subagent/process artifact, not a thread.
        touch("codex/2026/07/31/extra/rollout-nested.jsonl")

        let found = SessionScanner.discoverSessionFiles(agent: .codex, rootURL: root)
        XCTAssertEqual(names(found), ["rollout-2026-07-31T09-00-00-abc.jsonl"])
    }

    func testClaudeScanStopsOneProjectFolderDeep() {
        let root = tempDirectory.appendingPathComponent("claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        touch("claude/-Users-x-code/aaa.jsonl")
        touch("claude/-Users-x-code/deeper/bbb.jsonl")

        let found = SessionScanner.discoverSessionFiles(agent: .claude, rootURL: root)
        XCTAssertEqual(names(found), ["aaa.jsonl"])
    }

    func testMissingRootIsEmptyRatherThanAFailure() {
        let missing = tempDirectory.appendingPathComponent("never-run", isDirectory: true)
        XCTAssertTrue(SessionScanner.discoverSessionFiles(agent: .codex, rootURL: missing).isEmpty)
        XCTAssertTrue(SessionScanner.discoverSessions(roots: [(.codex, missing)]).isEmpty)
    }

    // MARK: - Multi-agent discovery

    func testDiscoverSessionsTagsEachFileWithItsAgent() {
        let piRoot = tempDirectory.appendingPathComponent("pi", isDirectory: true)
        let codexRoot = tempDirectory.appendingPathComponent("codex", isDirectory: true)
        let claudeRoot = tempDirectory.appendingPathComponent("claude", isDirectory: true)
        touch("pi/project/pi-session.jsonl")
        touch("codex/2026/07/31/rollout-x.jsonl")
        touch("claude/-Users-x-code/claude-session.jsonl")

        let found = SessionScanner.discoverSessions(roots: [
            (.pi, piRoot), (.codex, codexRoot), (.claude, claudeRoot)
        ])
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.agent) })
        XCTAssertEqual(byName["pi-session.jsonl"], .pi)
        XCTAssertEqual(byName["rollout-x.jsonl"], .codex)
        XCTAssertEqual(byName["claude-session.jsonl"], .claude)
        XCTAssertEqual(found.count, 3)
    }

    /// Two agents pointed at overlapping trees (only possible via the test/override env vars)
    /// must not produce the same file twice, and the more specific root wins.
    func testNestedRootsAttributeAFileOnceToTheMoreSpecificAgent() {
        let outer = tempDirectory.appendingPathComponent("shared", isDirectory: true)
        let inner = outer.appendingPathComponent("project", isDirectory: true)
        touch("shared/project/session.jsonl")

        let found = SessionScanner.discoverSessions(roots: [(.pi, outer), (.claude, inner)])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.agent, .claude)
    }

    // MARK: - Pi's original entry point

    func testDefaultRootHonoursTheLegacyPiOverrideVariable() {
        let root = SessionScanner.defaultRootURL(environment: ["PI_CODING_AGENT_SESSION_DIR": tempDirectory.path])
        XCTAssertEqual(root.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
    }

    /// Pinning Pi to a fixture tree pins every root. Scanning the developer's real Codex and
    /// Claude history behind a carefully built Pi fixture is neither isolated nor bounded.
    func testPinningPisRootPinsEveryRoot() {
        let roots = SessionScanner.roots(piRootURL: tempDirectory, environment: [:])
        XCTAssertEqual(roots.map(\.agent), [.pi])
        XCTAssertEqual(roots[0].url.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
    }

    func testAmbientRootPutsPiFirstAndKeepsEveryOtherAgent() {
        let roots = SessionScanner.roots(piRootURL: nil, environment: [:])
        XCTAssertEqual(roots.map(\.agent), AgentKind.allCases)
    }

    func testPiOnlyEntryPointStillReturnsPlainURLs() {
        let root = tempDirectory.appendingPathComponent("pi", isDirectory: true)
        let file = touch("pi/project/session.jsonl")
        XCTAssertEqual(SessionScanner.discoverSessionFiles(rootURL: root), [file])
    }
}
