import Foundation

/// Everything Pi Desktop needs to find, launch, and read one agent.
public struct AgentDescriptor: Sendable {
    public let kind: AgentKind
    /// Executable basenames to look for, in preference order.
    public let executableNames: [String]
    /// Environment variable that pins the executable path (test/override seam).
    public let executableOverrideKey: String
    /// Environment variable that relocates the session root (test/override seam).
    public let sessionRootOverrideKey: String
    /// Default session root under the user's home.
    public let sessionRootSuffix: String
    /// How many directory levels below the root hold session files. Pi keeps one project folder
    /// deep, Claude one project folder deep, Codex nests `YYYY/MM/DD`.
    public let sessionScanDepth: Int
    /// Filename prefix a session file must carry, when the root also holds unrelated JSONL.
    public let sessionFilePrefix: String?

    public var capabilities: AgentCapabilities { kind.capabilities }
}

/// Resolves which agents are installed and where their sessions live. This is the single place
/// that knows about executables and directory layout; nothing else in the app hardcodes either.
public enum AgentCatalog {
    public static let descriptors: [AgentDescriptor] = [
        AgentDescriptor(
            kind: .pi,
            executableNames: ["pi"],
            executableOverrideKey: "PI_DESKTOP_PI_PATH",
            sessionRootOverrideKey: "PI_CODING_AGENT_SESSION_DIR",
            sessionRootSuffix: ".pi/agent/sessions",
            sessionScanDepth: 1,
            sessionFilePrefix: nil
        ),
        AgentDescriptor(
            kind: .codex,
            executableNames: ["codex"],
            executableOverrideKey: "PI_DESKTOP_CODEX_PATH",
            sessionRootOverrideKey: "PI_DESKTOP_CODEX_SESSION_DIR",
            sessionRootSuffix: ".codex/sessions",
            sessionScanDepth: 3,
            sessionFilePrefix: "rollout-"
        ),
        AgentDescriptor(
            kind: .claude,
            executableNames: ["claude"],
            executableOverrideKey: "PI_DESKTOP_CLAUDE_PATH",
            sessionRootOverrideKey: "PI_DESKTOP_CLAUDE_SESSION_DIR",
            sessionRootSuffix: ".claude/projects",
            sessionScanDepth: 1,
            sessionFilePrefix: nil
        )
    ]

    public static func descriptor(for kind: AgentKind) -> AgentDescriptor {
        descriptors.first { $0.kind == kind } ?? descriptors[0]
    }

    /// Directories searched for every agent executable, in order. Mirrors the historical
    /// `PiLocator` search path so an existing install keeps resolving identically.
    public static func searchDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
    }

    public static func executable(
        for kind: AgentKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let descriptor = descriptor(for: kind)
        // An explicit override is a pin, not a hint: if it does not resolve, this agent is not
        // available. Falling through to the search path would silently run a different binary
        // than the one that was named, and would let a test that pinned a fixture path reach the
        // developer's real install instead.
        if let override = environment[descriptor.executableOverrideKey], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        return searchDirectories(home: home)
            .flatMap { directory in descriptor.executableNames.map { "\(directory)/\($0)" } }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public static func sessionRoot(
        for kind: AgentKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let descriptor = descriptor(for: kind)
        if let override = environment[descriptor.sessionRootOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(descriptor.sessionRootSuffix, isDirectory: true)
    }

    /// Agents whose executable resolves right now. Order follows `AgentKind.allCases` so the
    /// picker is stable regardless of install order.
    public static func installed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [AgentKind] {
        AgentKind.allCases.filter { executable(for: $0, environment: environment, fileManager: fileManager) != nil }
    }

    /// Agents that have a readable session root, whether or not their binary is still installed.
    /// History stays visible after an uninstall instead of silently vanishing from the sidebar.
    public static func readable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [AgentKind] {
        AgentKind.allCases.filter {
            var isDirectory: ObjCBool = false
            let root = sessionRoot(for: $0, environment: environment, fileManager: fileManager)
            return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Which agent owns a session file, decided purely by which root contains it. Returns nil
    /// for a path under no known root so callers can fall back rather than guess.
    public static func agent(
        forSessionPath path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AgentKind? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        // Longest root first: a nested override (a test pointing two agents at one tree) resolves
        // to the more specific one instead of whichever happens to be declared first.
        return AgentKind.allCases
            .map { ($0, sessionRoot(for: $0, environment: environment, fileManager: fileManager).standardizedFileURL.path) }
            .sorted { $0.1.count > $1.1.count }
            .first { normalized == $0.1 || normalized.hasPrefix($0.1 + "/") }?.0
    }

    /// PATH/PWD augmentation shared by every agent process, so an agent's own subprocesses and
    /// extensions see the same environment a terminal launch would.
    public static func augmentedEnvironment(
        executable: URL,
        cwd: URL? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = base
        let home = fileManager.homeDirectoryForCurrentUser.path
        let additions = [executable.deletingLastPathComponent().path]
            + searchDirectories(home: home)
            + ["/bin", "/usr/sbin", "/sbin"]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = Array(NSOrderedSet(array: additions + existing))
            .compactMap { $0 as? String }
            .joined(separator: ":")
        // LaunchAgents (and GUI apps) normally get PWD="/"; agent extensions and hooks commonly
        // consult PWD for project discovery, so keep it identical to the process's real cwd.
        if let cwd { environment["PWD"] = cwd.standardizedFileURL.path }
        return environment
    }
}

public extension AgentKind {
    /// The agent's own name for a conversation, when it keeps one outside the transcript.
    /// Codex does; Pi and Claude Code both write their name into the session file, where the
    /// ordinary parse already finds it.
    func externalName(forSessionPath path: String) -> String? {
        guard self == .codex, let threadID = CodexThreadTitles.threadID(fromRolloutPath: path) else { return nil }
        return CodexThreadTitles.shared.title(forThreadID: threadID)
    }
}
