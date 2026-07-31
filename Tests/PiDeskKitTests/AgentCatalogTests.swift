import XCTest
@testable import PiDeskKit

final class AgentCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeExecutable(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testEveryAgentHasADescriptorAndDistinctSessionRoot() {
        XCTAssertEqual(AgentCatalog.descriptors.count, AgentKind.allCases.count)
        var roots: Set<String> = []
        for kind in AgentKind.allCases {
            let descriptor = AgentCatalog.descriptor(for: kind)
            XCTAssertEqual(descriptor.kind, kind)
            XCTAssertFalse(descriptor.executableNames.isEmpty)
            XCTAssertTrue(roots.insert(descriptor.sessionRootSuffix).inserted, "roots must not collide")
        }
    }

    func testExecutableOverrideWinsOverSearchPath() throws {
        let binary = try makeExecutable("codex")
        let resolved = AgentCatalog.executable(
            for: .codex,
            environment: ["PI_DESKTOP_CODEX_PATH": binary.path]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, binary.standardizedFileURL)
    }

    func testMissingExecutableResolvesToNil() {
        XCTAssertNil(AgentCatalog.executable(
            for: .claude,
            environment: ["PI_DESKTOP_CLAUDE_PATH": root.appendingPathComponent("absent").path]
        ))
    }

    func testInstalledListsOnlyResolvableAgentsInStableOrder() throws {
        let pi = try makeExecutable("pi")
        let claude = try makeExecutable("claude")
        let installed = AgentCatalog.installed(environment: [
            "PI_DESKTOP_PI_PATH": pi.path,
            "PI_DESKTOP_CLAUDE_PATH": claude.path,
            "PI_DESKTOP_CODEX_PATH": root.appendingPathComponent("absent").path
        ])
        XCTAssertEqual(installed, [.pi, .claude])
    }

    func testSessionRootHonoursOverrideAndDefaultsUnderHome() {
        let override = AgentCatalog.sessionRoot(
            for: .codex,
            environment: ["PI_DESKTOP_CODEX_SESSION_DIR": root.path]
        )
        XCTAssertEqual(override.standardizedFileURL, root.standardizedFileURL)

        let fallback = AgentCatalog.sessionRoot(for: .claude, environment: [:])
        XCTAssertTrue(fallback.path.hasSuffix(".claude/projects"))
    }

    /// Pi's historical override must keep working: it is the seam every existing test and the
    /// packaged app already rely on.
    func testPiSessionRootStillHonoursLegacyOverrideKey() {
        let resolved = AgentCatalog.sessionRoot(
            for: .pi,
            environment: ["PI_CODING_AGENT_SESSION_DIR": root.path]
        )
        XCTAssertEqual(resolved.standardizedFileURL, root.standardizedFileURL)
    }

    func testAgentForSessionPathMatchesTheOwningRoot() {
        let environment = [
            "PI_CODING_AGENT_SESSION_DIR": root.appendingPathComponent("pi").path,
            "PI_DESKTOP_CODEX_SESSION_DIR": root.appendingPathComponent("codex").path,
            "PI_DESKTOP_CLAUDE_SESSION_DIR": root.appendingPathComponent("claude").path
        ]
        XCTAssertEqual(
            AgentCatalog.agent(forSessionPath: root.appendingPathComponent("codex/2026/07/31/r.jsonl").path, environment: environment),
            .codex
        )
        XCTAssertEqual(
            AgentCatalog.agent(forSessionPath: root.appendingPathComponent("claude/proj/a.jsonl").path, environment: environment),
            .claude
        )
        XCTAssertNil(
            AgentCatalog.agent(forSessionPath: root.appendingPathComponent("elsewhere/a.jsonl").path, environment: environment)
        )
    }

    /// A prefix match on the raw string would make `/tmp/x/pi-other/a.jsonl` look like it lives
    /// under `/tmp/x/pi`.
    func testAgentForSessionPathDoesNotMatchASiblingWithASharedPrefix() {
        let environment = ["PI_CODING_AGENT_SESSION_DIR": root.appendingPathComponent("pi").path]
        XCTAssertNil(
            AgentCatalog.agent(forSessionPath: root.appendingPathComponent("pi-other/a.jsonl").path, environment: environment)
        )
    }

    /// Nested overrides happen in tests; the more specific root has to win.
    func testAgentForSessionPathPrefersTheDeepestMatchingRoot() {
        let environment = [
            "PI_CODING_AGENT_SESSION_DIR": root.path,
            "PI_DESKTOP_CODEX_SESSION_DIR": root.appendingPathComponent("codex").path
        ]
        XCTAssertEqual(
            AgentCatalog.agent(forSessionPath: root.appendingPathComponent("codex/a.jsonl").path, environment: environment),
            .codex
        )
        XCTAssertEqual(
            AgentCatalog.agent(forSessionPath: root.appendingPathComponent("a.jsonl").path, environment: environment),
            .pi
        )
    }

    /// A test that pins Pi to a fixture tree must not have the developer's real Codex and Claude
    /// history scanned in behind it: that is neither isolated nor bounded.
    func testPinningPisRootPinsEveryRoot() {
        let roots = SessionScanner.roots(piRootURL: root, environment: [:])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.agent, .pi)
        XCTAssertEqual(roots.first?.url.standardizedFileURL, root.standardizedFileURL)
    }

    func testAmbientRootStillScansEveryInstalledAgent() {
        let roots = SessionScanner.roots(piRootURL: nil, environment: [:])
        XCTAssertEqual(roots.map(\.agent), AgentKind.allCases)
    }

    /// The environment override is the ambient root, so it must keep the full multi-agent scan.
    func testEnvironmentOverriddenPiRootIsStillAmbient() {
        let environment = ["PI_CODING_AGENT_SESSION_DIR": root.path]
        let roots = SessionScanner.roots(
            piRootURL: SessionScanner.defaultRootURL(environment: environment),
            environment: environment
        )
        XCTAssertEqual(roots.map(\.agent), AgentKind.allCases)
    }

    func testAugmentedEnvironmentPutsTheExecutableDirectoryFirstAndSetsPWD() {
        let environment = AgentCatalog.augmentedEnvironment(
            executable: URL(fileURLWithPath: "/opt/tools/bin/codex"),
            cwd: URL(fileURLWithPath: "/tmp/project"),
            base: ["PATH": "/already/here"]
        )
        let path = environment["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix("/opt/tools/bin:"))
        XCTAssertTrue(path.contains("/already/here"))
        XCTAssertEqual(environment["PWD"], "/tmp/project")
    }

    // MARK: - Capabilities

    func testUnknownAgentIdentityDecodesToPiRatherThanFailing() throws {
        struct Wrapper: Codable { let agent: AgentKind }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"agent":"gemini"}"#.utf8))
        XCTAssertEqual(decoded.agent, .pi)
        let known = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"agent":"claude"}"#.utf8))
        XCTAssertEqual(known.agent, .claude)
    }

    func testEveryAgentDeclaresAUsableModeLadder() {
        for kind in AgentKind.allCases {
            let modes = kind.capabilities.modes
            XCTAssertGreaterThan(modes.count, 1, "\(kind) needs a ladder, not a single stop")
            XCTAssertEqual(modes.map(\.rank), Array(0..<modes.count), "\(kind) ranks must be dense and ordered")
            XCTAssertEqual(Set(modes.map(\.id)).count, modes.count, "\(kind) mode ids must be unique")
            XCTAssertFalse(kind.capabilities.modeControlTitle.isEmpty)
        }
    }

    /// The capability table is what every gated affordance reads, so the honest facts about each
    /// agent are pinned here rather than rediscovered by hand.
    func testCapabilitiesMatchWhatEachAgentActuallySupports() {
        XCTAssertEqual(AgentKind.pi.capabilities.thinking, .live)
        XCTAssertTrue(AgentKind.pi.capabilities.canExportHTML)
        XCTAssertTrue(AgentKind.pi.capabilities.supportsActivityExtension)

        XCTAssertEqual(AgentKind.codex.capabilities.modelSelection, .queried)
        XCTAssertTrue(AgentKind.codex.capabilities.canSteerMidTurn)
        XCTAssertFalse(AgentKind.codex.capabilities.canExportHTML)
        XCTAssertFalse(AgentKind.codex.capabilities.supportsActivityExtension)

        XCTAssertEqual(AgentKind.claude.capabilities.modelSelection, .aliases)
        XCTAssertEqual(AgentKind.claude.capabilities.thinking, .relaunch)
        XCTAssertFalse(AgentKind.claude.capabilities.canFork)
        // Claude Code takes a message sent mid-turn into the running turn; its own release build
        // advertises "send messages to Claude while it works to steer Claude in real-time" and
        // logs "processed message(s) that were delivered mid-turn".
        XCTAssertTrue(AgentKind.claude.capabilities.canSteerMidTurn)
    }

    func testAgentGlyphsAndNamesAreDistinct() {
        XCTAssertEqual(Set(AgentKind.allCases.map(\.symbolName)).count, AgentKind.allCases.count)
        XCTAssertEqual(Set(AgentKind.allCases.map(\.displayName)).count, AgentKind.allCases.count)
        XCTAssertEqual(Set(AgentKind.allCases.map(\.accentHue)).count, AgentKind.allCases.count)
    }
}
