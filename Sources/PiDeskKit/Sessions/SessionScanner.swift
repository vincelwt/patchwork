import Foundation

/// Locates session files on disk for every agent Pi Desktop can read. Ported from the app's
/// `FileSessionRepository` (`Sources/PiDesktop/SessionRepository.swift`, not importable from
/// here) and kept deliberately identical to it: each agent is walked to the depth its
/// `AgentDescriptor` declares, with the filename prefix it declares, so a subagent's nested
/// transcript is never promoted into the thread list.
public enum SessionScanner {
    /// One discovered file plus the agent whose root contained it.
    public struct DiscoveredSession: Sendable, Hashable {
        public let agent: AgentKind
        public let url: URL

        public init(agent: AgentKind, url: URL) {
            self.agent = agent
            self.url = url
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
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path) else { return [] }
        let descriptor = AgentCatalog.descriptor(for: agent)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]

        var files: [URL] = []
        var frontier = [rootURL]
        for depth in 0...max(0, descriptor.sessionScanDepth) {
            var next: [URL] = []
            for directory in frontier {
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
        return files.compactMap { file in
            let normalized = file.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return nil }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: normalized.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return normalized
        }
    }

    /// Every agent's sessions in one pass. Roots are visited longest-path first so a nested
    /// override (a test pointing two agents at one tree) attributes a file to the more specific
    /// agent instead of whichever root happened to be listed first.
    public static func discoverSessions(
        roots: [(agent: AgentKind, url: URL)] = SessionScanner.roots()
    ) -> [DiscoveredSession] {
        var seen: Set<String> = []
        var results: [DiscoveredSession] = []
        for root in roots.sorted(by: { $0.url.standardizedFileURL.path.count > $1.url.standardizedFileURL.path.count }) {
            for url in discoverSessionFiles(agent: root.agent, rootURL: root.url) where seen.insert(url.path).inserted {
                results.append(DiscoveredSession(agent: root.agent, url: url))
            }
        }
        return results
    }
}
