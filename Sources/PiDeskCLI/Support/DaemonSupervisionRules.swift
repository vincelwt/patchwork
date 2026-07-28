import Darwin
import Foundation
import PiDeskKit

/// Pure classification behind `pidesk daemon status`: the default owner is the Pi Desktop
/// process itself, while the optional LaunchAgent and manually started host remain external.
enum DaemonRunMode: String, Equatable, Sendable {
    case appManaged
    case launchAgent
    case external
    case notRunning
}

enum DaemonModeClassifier {
    /// `launchAgentLoaded` wins unconditionally — "defer to it rather than fighting it" — even if
    /// it is between restarts and momentarily unreachable, because it is still the thing
    /// responsible for this daemon's lifecycle. Only once that's ruled out does reachability (and
    /// then ownership) decide the rest.
    static func classify(launchAgentLoaded: Bool, healthReachable: Bool, ownedByApp: Bool) -> DaemonRunMode {
        if launchAgentLoaded { return .launchAgent }
        if !healthReachable { return .notRunning }
        return ownedByApp ? .appManaged : .external
    }
}

/// Written by Pi Desktop.app while it hosts the service in-process, so `pidesk daemon status`
/// can distinguish that socket from the optional standalone host. Not part of the HTTP contract.
struct DaemonOwnerRecord: Codable, Equatable, Sendable {
    var pid: Int32
    var startedAt: Date
}

enum DaemonOwnership {
    static func fileURL(supportDirectory: URL = PiDeskPaths.supportDirectory) -> URL {
        supportDirectory.appendingPathComponent("daemon-owner.json")
    }

    static func read(from url: URL) -> DaemonOwnerRecord? {
        PiDeskFile.readIfPresent(DaemonOwnerRecord.self, from: url)
    }

    /// "Only stop what we started": a record is trustworthy only while its pid is still alive —
    /// a dead or (in the rare reuse case) reused pid must never read as "ours". The safe default
    /// on any doubt is always "not ours".
    static func isLive(_ record: DaemonOwnerRecord?, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        guard let record else { return false }
        return isAlive(record.pid)
    }
}
