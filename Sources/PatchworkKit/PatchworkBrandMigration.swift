import Darwin
import Foundation

/// One-release migration from the previous product name. The old directories are kept as a
/// backup, while only bounded, app-owned files are copied into Patchwork's new locations.
public enum PatchworkBrandMigration {
    public struct Report: Equatable, Sendable {
        public var copiedSupportFiles: [String]
        public var copiedCacheDirectory: Bool
        public var retiredLaunchAgent: Bool

        public init(
            copiedSupportFiles: [String] = [],
            copiedCacheDirectory: Bool = false,
            retiredLaunchAgent: Bool = false
        ) {
            self.copiedSupportFiles = copiedSupportFiles
            self.copiedCacheDirectory = copiedCacheDirectory
            self.retiredLaunchAgent = retiredLaunchAgent
        }
    }

    public typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> Int32

    private static let supportFileNames = [
        "state.json",
        "daemon-token",
        "daemon.json",
        "relay-identity.json",
        "schedules.json",
        "runs.jsonl",
        "daemon-thread-overlay.json",
        "daemon-owner.json"
    ]

    @discardableResult
    public static func run(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        commandRunner: CommandRunner = runCommand
    ) -> Report {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let legacySupport = home.appendingPathComponent(
            "Library/Application Support/Pi Desktop", isDirectory: true
        )
        let support = home.appendingPathComponent(
            "Library/Application Support/Patchwork", isDirectory: true
        )

        var report = Report()
        for name in supportFileNames {
            let source = legacySupport.appendingPathComponent(name)
            let destination = support.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                report.copiedSupportFiles.append(name)
            } catch {
                // Migration is best effort. The new app can still launch with fresh metadata.
            }
        }

        let legacyCache = home.appendingPathComponent("Library/Caches/Pi Desktop", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/Patchwork", isDirectory: true)
        if fileManager.fileExists(atPath: legacyCache.path),
           !fileManager.fileExists(atPath: cache.path) {
            do {
                try fileManager.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: legacyCache, to: cache)
                report.copiedCacheDirectory = true
            } catch {
                // A cache miss only causes recomputation.
            }
        }

        report.retiredLaunchAgent = retireLegacyLaunchAgent(
            fileManager: fileManager,
            home: home,
            commandRunner: commandRunner
        )
        return report
    }

    private static func retireLegacyLaunchAgent(
        fileManager: FileManager,
        home: URL,
        commandRunner: CommandRunner
    ) -> Bool {
        let legacyLabel = "dev.pi.desktop.daemon"
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
        guard let data = fileManager.contents(atPath: plist.path),
              let contents = String(data: data, encoding: .utf8),
              contents.contains("<string>\(legacyLabel)</string>") else { return false }

        _ = commandRunner("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyLabel)"])
        do {
            try fileManager.removeItem(at: plist)
            return true
        } catch {
            return false
        }
    }

    public static func runCommand(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
