import Foundation

/// Teaches an agent that Patchwork's control CLI exists.
///
/// `patchwork` is already on every agent's PATH, so any of them could list threads, send messages,
/// and create automations — they simply have no way to know that. Pi learns it through the
/// extension Patchwork installs; Codex and Claude Code both read skills from a directory, so
/// the same fact can be delivered there as one small skill file.
///
/// The safety rules mirror `ActivityExtensionInstaller`, because this writes into a directory
/// another program owns: a file with no recognisable version marker is treated as the user's own
/// and is never overwritten, and nothing is ever deleted.
public enum AgentSkillInstaller {
    public static let skillName = "patchwork"
    public static let versionMarkerPrefix = "<!-- patchwork-skill-version:"
    public static let legacySkillName = "pi-desktop"
    public static let legacyVersionMarkerPrefix = "<!-- pi-desktop-skill-version:"
    public static let version = 1

    public enum Outcome: Equatable, Sendable {
        case installed
        case upgraded
        case upToDate
        /// The file on disk carries no marker this build understands, so it is someone's own
        /// edit and is left exactly as it is.
        case skippedUserModified
        /// This agent has no skill directory Patchwork can write to.
        case unsupported
        case writeFailed(String)

        public var isSuccess: Bool {
            switch self {
            case .installed, .upgraded, .upToDate: true
            default: false
            }
        }

        public var summary: String {
            switch self {
            case .installed: "Skill installed"
            case .upgraded: "Skill updated"
            case .upToDate: "Skill already up to date"
            case .skippedUserModified: "Left your own edited skill untouched"
            case .unsupported: "This agent has no skill directory"
            case let .writeFailed(detail): "Could not write the skill: \(detail)"
            }
        }
    }

    /// Where an agent reads user skills from, or nil when it has no such directory.
    ///
    /// Pi is deliberately absent: it already gets `patchwork-activity.ts`, which does strictly
    /// more (activity heartbeats and conversation naming as well), so a skill would duplicate it.
    public static func skillDirectory(
        for agent: AgentKind,
        fileManager: FileManager = .default
    ) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        switch agent {
        case .pi: return nil
        case .codex: return home.appendingPathComponent(".codex/skills", isDirectory: true)
        case .claude: return home.appendingPathComponent(".claude/skills", isDirectory: true)
        }
    }

    public static func supports(_ agent: AgentKind) -> Bool { skillDirectory(for: agent) != nil }

    public static func installedFileURL(for agent: AgentKind, fileManager: FileManager = .default) -> URL? {
        skillDirectory(for: agent, fileManager: fileManager)?
            .appendingPathComponent(skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }

    /// True when this build's skill is already in place, so a settings row can say so rather
    /// than offering an install that would do nothing.
    public static func isInstalled(for agent: AgentKind, fileManager: FileManager = .default) -> Bool {
        guard let url = installedFileURL(for: agent, fileManager: fileManager),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return (parsedVersion(of: contents) ?? -1) >= version
    }

    /// Reads the integer after the marker comment, scanning only the first few lines.
    public static func parsedVersion(of source: String) -> Int? {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(8) {
            guard let range = line.range(of: versionMarkerPrefix) else { continue }
            let rest = line[range.upperBound...].replacingOccurrences(of: "-->", with: "")
            return Int(rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Pure policy, independent of disk I/O. A missing or unparseable marker on the installed
    /// side always means "leave it alone".
    public static func decide(installed: String?) -> Outcome {
        guard let installed else { return .installed }
        guard let installedVersion = parsedVersion(of: installed) else { return .skippedUserModified }
        return installedVersion < version ? .upgraded : .upToDate
    }

    /// Writes the skill. Call off the main actor: this is blocking file I/O. `directory` is
    /// overridable so tests never write into the user's real `~/.codex` or `~/.claude`.
    @discardableResult
    public static func install(
        for agent: AgentKind,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard let base = directory ?? skillDirectory(for: agent, fileManager: fileManager) else {
            return .unsupported
        }
        let folder = base.appendingPathComponent(skillName, isDirectory: true)
        let destination = folder.appendingPathComponent("SKILL.md", isDirectory: false)
        let existing = try? String(contentsOf: destination, encoding: .utf8)
        let outcome = decide(installed: existing)
        guard outcome == .installed || outcome == .upgraded else {
            if outcome == .upToDate { retireLegacyInstall(in: base, fileManager: fileManager) }
            return outcome
        }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            // Atomic write: an agent scanning its skills directory never sees a partial file.
            try source(for: agent).write(to: destination, atomically: true, encoding: .utf8)
            retireLegacyInstall(in: base, fileManager: fileManager)
            return outcome
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }

    /// Reinstalls only when the previous, app-owned skill exists, preserving the user's earlier
    /// opt-in while leaving unrelated or hand-edited skill folders untouched.
    @discardableResult
    public static func migrateLegacyInstall(
        for agent: AgentKind,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Outcome? {
        guard let base = directory ?? skillDirectory(for: agent, fileManager: fileManager) else { return nil }
        let legacy = base.appendingPathComponent(legacySkillName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        guard isRecognizedLegacySkill(at: legacy) else { return nil }
        return install(for: agent, directory: base, fileManager: fileManager)
    }

    private static func retireLegacyInstall(in base: URL, fileManager: FileManager) {
        let folder = base.appendingPathComponent(legacySkillName, isDirectory: true)
        let legacy = folder.appendingPathComponent("SKILL.md")
        guard isRecognizedLegacySkill(at: legacy) else { return }
        try? fileManager.removeItem(at: legacy)
        if (try? fileManager.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
            try? fileManager.removeItem(at: folder)
        }
    }

    private static func isRecognizedLegacySkill(at url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).contains {
            $0.contains(legacyVersionMarkerPrefix)
        }
    }

    /// The skill itself. Deliberately short and factual: it describes a CLI the agent can
    /// already run, and says plainly what it must not do with it.
    public static func source(for agent: AgentKind) -> String {
        """
        \(versionMarkerPrefix) \(version) -->
        ---
        name: \(skillName)
        description: Inspect and control Patchwork's conversations and automations through the `patchwork` CLI. Use when asked to list, read, or message Patchwork threads, or to create, inspect, pause, or remove scheduled automations for yourself or another agent.
        ---

        # Patchwork control

        `patchwork` talks to Patchwork's background service over a local socket. It is already on
        your PATH. Everything below is read-only unless it says otherwise.

        Run `patchwork --help`, or `patchwork <group> --help`, for the authoritative flag list; this
        file only covers what is easy to get wrong.

        ## Conversations

        ```
        patchwork threads list --agent \(agent.rawValue) --limit 20
        patchwork threads show <id> --messages 20
        patchwork threads send <id> "text"
        ```

        `--json` on any command gives machine-readable output.

        ## Automations

        ```
        patchwork schedule list
        patchwork schedule add --name "Nightly triage" --cwd /path/to/project \\
            --prompt "…" --every 1h --agent \(agent.rawValue)
        patchwork schedule pause <id>
        patchwork schedule remove <id>
        ```

        Two rules that are easy to get wrong:

        - `--agent` only applies with `--cwd`, which starts a fresh conversation each run. Pass
          `\(agent.rawValue)` there or the automation will run as Pi.
        - `--thread <id>` runs against an existing conversation and takes that conversation's own
          agent automatically. Passing `--agent` with it is rejected.

        ## Boundaries

        - Do not create, pause, or remove an automation the user did not ask for.
        - Do not message another conversation on your own initiative.
        - Creating an automation commits future work: say what you scheduled and when it fires.
        """
    }
}
