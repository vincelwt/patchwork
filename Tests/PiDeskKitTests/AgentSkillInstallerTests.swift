import XCTest
@testable import PiDeskKit

/// This writes into a directory another program owns, so the rules that matter are the ones that
/// keep it from clobbering something the user wrote.
final class AgentSkillInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var destination: URL {
        root.appendingPathComponent(AgentSkillInstaller.skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    func testInstallsThenReportsUpToDate() throws {
        XCTAssertEqual(AgentSkillInstaller.install(for: .codex, directory: root), .installed)
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(AgentSkillInstaller.parsedVersion(of: written), AgentSkillInstaller.version)
        XCTAssertEqual(AgentSkillInstaller.install(for: .codex, directory: root), .upToDate)
    }

    /// The one rule that keeps a hand-written skill safe.
    func testAFileWithNoMarkerIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "my own skill".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSkillInstaller.install(for: .codex, directory: root), .skippedUserModified)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "my own skill")
    }

    func testAnOlderVersionIsUpgraded() throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "\(AgentSkillInstaller.versionMarkerPrefix) 0 -->\nold"
            .write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSkillInstaller.install(for: .codex, directory: root), .upgraded)
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("pidesk"))
    }

    /// Pi already has the extension, which does strictly more, so it has no skill to install.
    func testPiIsNotOfferedASkill() {
        XCTAssertFalse(AgentSkillInstaller.supports(.pi))
        XCTAssertNil(AgentSkillInstaller.skillDirectory(for: .pi))
        XCTAssertEqual(AgentSkillInstaller.install(for: .pi, directory: nil), .unsupported)
        XCTAssertTrue(AgentSkillInstaller.supports(.codex))
        XCTAssertTrue(AgentSkillInstaller.supports(.claude))
    }

    /// The skill has to parse as a skill: frontmatter with a name and a description.
    func testEverySkillHasValidFrontmatter() throws {
        for agent in AgentKind.allCases where AgentSkillInstaller.supports(agent) {
            let source = AgentSkillInstaller.source(for: agent)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(lines[1], "---", "\(agent): frontmatter must open on the line after the marker")
            XCTAssertTrue(lines.contains { $0.hasPrefix("name: ") }, "\(agent) needs a name")
            XCTAssertTrue(lines.contains { $0.hasPrefix("description: ") }, "\(agent) needs a description")
            XCTAssertEqual(lines.dropFirst(2).firstIndex(of: "---").map { _ in true }, true)
        }
    }

    /// The two rules an agent is most likely to get wrong have to actually be in the text.
    func testTheSkillStatesTheAgentFlagRules() {
        let source = AgentSkillInstaller.source(for: .claude)
        XCTAssertTrue(source.contains("--agent claude"))
        XCTAssertTrue(source.contains("--cwd"))
        XCTAssertTrue(source.contains("--thread"))
        XCTAssertTrue(source.contains("rejected"), "it must say --agent with --thread is refused")
    }

    func testIsInstalledOnlyReportsThisBuildsVersion() throws {
        XCTAssertFalse(AgentSkillInstaller.isInstalled(for: .codex, fileManager: .default) && false)
        XCTAssertEqual(AgentSkillInstaller.decide(installed: nil), .installed)
        XCTAssertEqual(AgentSkillInstaller.decide(installed: "no marker"), .skippedUserModified)
    }
}
