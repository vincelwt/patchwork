import Foundation

/// Locates Pi session files on disk. Ported from the app's `FileSessionRepository` (`Sources/
/// PiDesktop/SessionRepository.swift`, not importable from here): same root, same override, same
/// "one project directory deep" rule so a subagent's nested `session.jsonl` is never promoted
/// into the thread list.
public enum SessionScanner {
    public static func defaultRootURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PI_CODING_AGENT_SESSION_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    /// Every session JSONL directly under `rootURL`, plus every JSONL one project directory
    /// below it. Missing root returns an empty list rather than throwing, so a machine that has
    /// never run Pi degrades gracefully instead of failing every thread-listing request.
    public static func discoverSessionFiles(rootURL: URL = SessionScanner.defaultRootURL()) -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: rootURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let rootItems = try? manager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return []
        }

        var files = rootItems.filter { $0.pathExtension.lowercased() == "jsonl" }
        for folder in rootItems where (try? folder.resourceValues(forKeys: keys).isDirectory) == true {
            files += (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "jsonl" }) ?? []
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
}
