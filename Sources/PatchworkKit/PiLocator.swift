import Foundation

/// Resolves the `pi` executable and the environment to run it in. A faithful port of the app's
/// own `PiLocator` (`Sources/Patchwork/PiRPCClient.swift`, not importable from here since
/// `Patchwork` is an app target, not a library) — same override, same search order, same PATH/
/// PWD handling, so the daemon attaches to exactly the `pi` the app would have.
public enum PiLocator {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let manager = FileManager.default
        var candidates: [String] = []
        if let override = environment["PATCHWORK_PI_PATH"], !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        let home = manager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "/usr/bin/pi"
        ])
        return candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { manager.isExecutableFile(atPath: $0.path) }
    }

    public static func augmentedEnvironment(
        piURL: URL,
        cwd: URL? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            piURL.deletingLastPathComponent().path,
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = Array(NSOrderedSet(array: additions + existing)).compactMap { $0 as? String }.joined(separator: ":")
        // LaunchAgents (and GUI apps) normally get PWD="/"; Pi extensions commonly consult PWD
        // for project discovery, so keep it identical to the process's real cwd.
        if let cwd { environment["PWD"] = cwd.standardizedFileURL.path }
        return environment
    }
}
