import Foundation

/// Shared control-plane surface for the daemon, the CLI, the web remote, and the app.
/// The wire contract lives in `docs/daemon-api.md`; everything here must match it exactly.
///
/// Deliberately not named `PiDeskKit`: a type with the same name as its module shadows the
/// module, so clients could not qualify any other symbol as `PiDeskKit.Something`.
public enum PiDeskAPI {
    /// Bumped only for breaking wire changes; additive fields never bump it.
    public static let apiVersion = 1
}

/// Every file the control plane owns. Session data is never among them: Pi owns that.
public enum PiDeskPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pi Desktop", isDirectory: true)
    }

    public static var controlSocket: URL { supportDirectory.appendingPathComponent("daemon.sock") }
    public static var tokenFile: URL { supportDirectory.appendingPathComponent("daemon-token") }
    public static var daemonSettings: URL { supportDirectory.appendingPathComponent("daemon.json") }
    public static var relayIdentity: URL { supportDirectory.appendingPathComponent("relay-identity.json") }
    public static var schedules: URL { supportDirectory.appendingPathComponent("schedules.json") }
    public static var runHistory: URL { supportDirectory.appendingPathComponent("runs.jsonl") }
    public static var submissionReplays: URL {
        supportDirectory.appendingPathComponent("submission-replays.json")
    }

    /// Heartbeats written by the bundled Pi extension; the one shared truth about run state.
    public static var activityDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/desktop-activity", isDirectory: true)
    }

    public static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pi Desktop/daemon.log")
    }
}
