import Darwin
import Foundation
import PatchworkKit

protocol DaemonHealthProbing {
    func probe() async -> Bool
}

protocol LaunchAgentProbing {
    func isLoaded() -> Bool
}

struct SocketHealthProbe: DaemonHealthProbing {
    func probe() async -> Bool {
        do {
            _ = try await PatchworkClient.unixSocket(requestTimeout: 2).health()
            return true
        } catch {
            return false
        }
    }
}

struct SystemLaunchAgentProbe: LaunchAgentProbing {
    static let label = "app.patchwork.desktop.daemon"

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

/// Shared with `patchwork daemon status`. In app-hosted mode the PID is Patchwork itself; older
/// releases wrote the child daemon PID, which `DaemonSupervisor` retires once during migration.
struct DaemonOwnerRecord: Codable, Equatable {
    var pid: Int32
    var startedAt: Date
    /// Absent in legacy records whose PID was the previous product's child daemon process.
    var host: String? = nil
}

enum LegacyDaemonProcess {
    /// A legacy owner record alone is not authority to signal a reused PID. Match the executable,
    /// process-group layout, and kernel start time that the old app-managed spawner created.
    static func matches(_ record: DaemonOwnerRecord, startTolerance: TimeInterval = 10) -> Bool {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(record.pid, PROC_PIDTBSDINFO, 0, $0, infoSize)
        }
        guard read == infoSize,
              info.pbi_pid == UInt32(record.pid),
              info.pbi_pgid == UInt32(record.pid) else { return false }

        var path = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(record.pid, &path, UInt32(path.count)) > 0,
              URL(fileURLWithPath: String(cString: path)).lastPathComponent == "pi-deskd" else { return false }

        let startedAt = Date(timeIntervalSince1970:
            TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
        return abs(startedAt.timeIntervalSince(record.startedAt)) <= startTolerance
    }
}

enum DaemonOwnerFile {
    static func read(from url: URL) -> DaemonOwnerRecord? {
        PatchworkFile.readIfPresent(DaemonOwnerRecord.self, from: url)
    }

    static func write(_ record: DaemonOwnerRecord, to url: URL) throws {
        try PatchworkFile.writeAtomic(record, to: url)
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
