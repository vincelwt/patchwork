import Foundation

/// Locates session files on disk for every agent Pi Desktop can read. Ported from the app's
/// `FileSessionRepository` (`Sources/PiDesktop/SessionRepository.swift`, not importable from
/// here) and kept deliberately identical to it: each agent is walked to the depth its
/// `AgentDescriptor` declares, with the filename prefix it declares, so a subagent's nested
/// transcript is never promoted into the thread list.
public enum SessionScanner {
    /// Both the app and daemon keep their own bounded ownership sets. Their union must remain
    /// representable, or one side reaching its cap could make a still-owned thread disappear.
    public static let supplementalPathLimit = ArchiveStateBounds.itemLimit * 2

    /// One discovered file plus the agent whose root contained it.
    public struct DiscoveredSession: Sendable, Hashable {
        public let agent: AgentKind
        public let url: URL

        public init(agent: AgentKind, url: URL) {
            self.agent = agent
            self.url = url
        }
    }

    public struct DiscoveredCatalog: Sendable {
        public let sessions: [DiscoveredSession]
        public let directories: [URL]

        public init(sessions: [DiscoveredSession], directories: [URL]) {
            self.sessions = sessions
            self.directories = directories
        }
    }

    public static func defaultRootURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        AgentCatalog.sessionRoot(for: .pi, environment: environment)
    }

    /// Every agent's session root, Pi first.
    ///
    /// Pinning Pi's root to something other than the ambient one means the caller is pointing at
    /// a fixture tree (a test, a sandboxed daemon), and pinning one root has to pin all of them:
    /// otherwise a test that carefully builds a Pi fixture would still sweep in the developer's
    /// real `~/.codex/sessions` and `~/.claude/projects`, which is neither isolated nor bounded.
    public static func roots(
        piRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [(agent: AgentKind, url: URL)] {
        let ambientPi = defaultRootURL(environment: environment)
        let pi = piRootURL ?? ambientPi
        guard pi.standardizedFileURL == ambientPi.standardizedFileURL else {
            return [(AgentKind.pi, pi)]
        }
        return [(AgentKind.pi, pi)]
            + AgentKind.allCases
                .filter { $0 != .pi }
                .map { ($0, AgentCatalog.sessionRoot(for: $0, environment: environment)) }
    }

    /// Pi's own sessions. Unchanged entry point: same root, same override, same one-project-folder
    /// depth as before multi-agent support existed.
    public static func discoverSessionFiles(rootURL: URL = SessionScanner.defaultRootURL()) -> [URL] {
        discoverSessionFiles(agent: .pi, rootURL: rootURL)
    }

    /// One agent's session files. A missing root returns an empty list rather than throwing, so a
    /// machine that has never run that agent degrades gracefully instead of failing every
    /// thread-listing request.
    public static func discoverSessionFiles(agent: AgentKind, rootURL: URL) -> [URL] {
        discoverSessionTree(agent: agent, rootURL: rootURL).files
    }

    private static func discoverSessionTree(
        agent: AgentKind, rootURL: URL
    ) -> (files: [URL], directories: [URL]) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path) else { return ([], [rootURL.standardizedFileURL]) }
        let descriptor = AgentCatalog.descriptor(for: agent)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]

        var files: [URL] = []
        var directories: [URL] = []
        var frontier = [rootURL]
        for depth in 0...max(0, descriptor.sessionScanDepth) {
            var next: [URL] = []
            for directory in frontier {
                directories.append(directory.standardizedFileURL)
                let items = (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
                )) ?? []
                for item in items {
                    if (try? item.resourceValues(forKeys: keys).isDirectory) == true {
                        if depth < descriptor.sessionScanDepth { next.append(item) }
                    } else if item.pathExtension.lowercased() == "jsonl" {
                        guard let prefix = descriptor.sessionFilePrefix else {
                            files.append(item)
                            continue
                        }
                        if item.lastPathComponent.hasPrefix(prefix) { files.append(item) }
                    }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        var seen: Set<String> = []
        let normalizedFiles = files.compactMap { file -> URL? in
            let normalized = file.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: normalized.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return normalized
        }
        var seenDirectories: Set<String> = []
        let normalizedDirectories = directories.compactMap { directory -> URL? in
            let normalized = directory.standardizedFileURL
            return seenDirectories.insert(normalized.path).inserted ? normalized : nil
        }
        return (normalizedFiles, normalizedDirectories)
    }

    /// Every agent's sessions in one pass. Roots are visited longest-path first so a nested
    /// override (a test pointing two agents at one tree) attributes a file to the more specific
    /// agent instead of whichever root happened to be listed first.
    public static func discoverSessions(
        roots: [(agent: AgentKind, url: URL)] = SessionScanner.roots()
    ) -> [DiscoveredSession] {
        discoverCatalog(roots: roots).sessions
    }

    public static func discoverCatalog(
        roots: [(agent: AgentKind, url: URL)] = SessionScanner.roots(),
        supplementalPaths: Set<String> = []
    ) -> DiscoveredCatalog {
        var seen: Set<String> = []
        var seenDirectories: Set<String> = []
        var results: [DiscoveredSession] = []
        var directories: [URL] = []
        let orderedRoots = roots.sorted {
            $0.url.standardizedFileURL.path.count > $1.url.standardizedFileURL.path.count
        }
        for root in orderedRoots {
            let tree = discoverSessionTree(agent: root.agent, rootURL: root.url)
            for directory in tree.directories where seenDirectories.insert(directory.path).inserted {
                directories.append(directory)
            }
            for url in tree.files where seen.insert(url.path).inserted {
                results.append(DiscoveredSession(agent: root.agent, url: url))
            }
        }

        // Pi can choose a cwd-specific sessionDir which is intentionally impossible to model as
        // one static root. App- and daemon-owned exact paths are bounded discovery seeds. They do
        // not broaden the scan: only that regular JSONL is considered, and its parent is watched
        // so deletion invalidates a warm daemon projection.
        for rawPath in supplementalPaths.sorted().suffix(supplementalPathLimit) {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if seenDirectories.insert(parent.path).inserted { directories.append(parent) }
            guard seen.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let agent = orderedRoots.first { root in
                let rootPath = root.url.standardizedFileURL.path
                return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
            }?.agent ?? .pi
            results.append(DiscoveredSession(agent: agent, url: url))
        }
        return DiscoveredCatalog(sessions: results, directories: directories)
    }
}
