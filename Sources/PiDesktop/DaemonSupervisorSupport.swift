import Darwin
import Foundation
import PiDeskKit

protocol DaemonHealthProbing {
    func probe() async -> Bool
}

protocol LaunchAgentProbing {
    func isLoaded() -> Bool
}

struct SocketHealthProbe: DaemonHealthProbing {
    func probe() async -> Bool {
        do {
            _ = try await PiDeskClient.unixSocket(requestTimeout: 2).health()
            return true
        } catch {
            return false
        }
    }
}

struct SystemLaunchAgentProbe: LaunchAgentProbing {
    static let label = "dev.pi.desktop.daemon"

    func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(Self.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Shared with `pidesk daemon status`. In app-hosted mode the PID is Pi Desktop itself; older
/// releases wrote the child daemon PID, which `DaemonSupervisor` retires once during migration.
struct DaemonOwnerRecord: Codable, Equatable {
    var pid: Int32
    var startedAt: Date
}

enum DaemonOwnerFile {
    static func read(from url: URL) -> DaemonOwnerRecord? {
        PiDeskFile.readIfPresent(DaemonOwnerRecord.self, from: url)
    }

    static func write(_ record: DaemonOwnerRecord, to url: URL) throws {
        try PiDeskFile.writeAtomic(record, to: url)
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
