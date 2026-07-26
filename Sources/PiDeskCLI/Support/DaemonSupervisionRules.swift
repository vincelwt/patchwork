import Darwin
import Foundation
import PiDeskKit

/// Pure rules behind "who owns this `pi-deskd`, and should we touch it" — used for real by
/// `pidesk daemon status` (this target) and mirrored, deliberately literally, by Pi Desktop.app's
/// own supervisor (`Sources/PiDesktop/DaemonSupervisor.swift`). SwiftPM does not let one
/// executable target import another here, so the app cannot depend on this file directly; this
/// is the same trade-off already made for `PiDeskKit.PiLocator` ("a faithful port of the app's
/// own PiLocator... not importable from here") and for `ScheduleValidation`/`CronExpressionCheck`
/// between the app's local schedule model and the daemon's. Keep the two copies in sync by hand.
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

/// Written by Pi Desktop.app next to the other control-plane files whenever *it* spawns
/// `pi-deskd`, so a later process (another `pidesk daemon status`, or the app itself after a
/// relaunch following a crash) can tell "the app started this" from "this showed up some other
/// way" without guessing. Not part of the HTTP contract in `docs/daemon-api.md`: a local
/// coordination file between the app and the CLI on the same machine, see its "Storage" table.
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

/// Exponential backoff with a hard cap on both the delay and the attempt count, so a daemon that
/// cannot stay up gets one clearly-surfaced "gave up" state instead of an invisible restart loop
/// burning CPU forever. Mirrored by the app's watchdog; no CLI command restarts anything itself,
/// but `daemon status`'s "which mode" question and this policy are two views of one lifecycle
/// story, so they live together in one tested file.
enum RestartPolicy {
    static let baseDelaySeconds: TimeInterval = 2
    static let maxDelaySeconds: TimeInterval = 60
    /// Restarts are attempted after failures 1...maxAttempts; the next failure past that gives up.
    static let maxAttempts = 5

    static func hasExhausted(failureCount: Int) -> Bool { failureCount > maxAttempts }

    static func delay(forFailureCount failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        return min(maxDelaySeconds, baseDelaySeconds * pow(2, Double(failureCount - 1)))
    }
}
