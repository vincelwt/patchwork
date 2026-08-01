import Foundation
import PatchworkKit

/// Reads/writes `daemon.json` (port, concurrency, remote-enabled — docs/daemon-api.md,
/// "Storage"). The doc defines no HTTP endpoint for changing these, so `remote enable/disable`
/// edits this file directly and asks the caller to restart the daemon to pick it up; see
/// docs/cli.md's "remote" section for the full rationale. Reads/writes go through a loose
/// `[String: Any]` dictionary rather than a strict Codable struct so an unknown key a future
/// daemon adds is preserved instead of being silently dropped on the next write.
struct DaemonSettingsStore {
    let path: URL
    let fileManager: FileManager

    init(path: URL = PatchworkPaths.daemonSettings, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    func write(_ object: [String: Any]) throws {
        try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard fileManager.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CLIFailure(exitCode: .requestFailed, message: "could not write \(path.path)")
        }
    }

    struct RemoteSettings {
        var enabled: Bool
        var port: Int
    }

    func readRemoteSettings() -> RemoteSettings {
        let object = read()
        return RemoteSettings(enabled: (object["remoteEnabled"] as? Bool) ?? false, port: (object["port"] as? Int) ?? 7717)
    }

    func writeRemoteSettings(_ settings: RemoteSettings) throws {
        var object = read()
        object["remoteEnabled"] = settings.enabled
        object["port"] = settings.port
        if object["concurrency"] == nil { object["concurrency"] = 2 }
        try write(object)
    }
}
