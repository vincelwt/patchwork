import Foundation

/// Installs and repairs Pi Desktop's Pi extension: activity heartbeats, automatic conversation
/// naming, plus the bridge that sends thread-created automations to the durable background service
/// (`Resources/pi-desktop-activity.ts` is the source of truth). Extensions in
/// `~/.pi/agent/extensions/` are auto-discovered by every Pi session, terminal or RPC, so one
/// install covers the whole system.
enum ActivityExtensionInstaller {
    static let versionMarkerPrefix = "// pi-desktop-activity-version:"
    static let resourceName = "pi-desktop-activity"
    static let resourceExtension = "ts"

    enum Outcome: Equatable {
        case installed
        case upgraded
        case upToDate
        /// The installed file has no recognizable version marker (or a marker Pi Desktop does
        /// not understand) — treated as a user's own file, never overwritten.
        case skippedUserModified
        case disabled
        case sourceUnavailable
        case writeFailed
    }

    static func installedFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/pi-desktop-activity.ts", isDirectory: false)
    }

    /// The packaged app's `Contents/Resources` copy first (see `scripts/package-app.sh`), then
    /// the checked-out `Resources/` directory for `swift run`/`swift test`, located relative to
    /// this source file. No SwiftPM resource bundle is declared, so `Bundle.module` does not
    /// exist; both lookups are plain file reads.
    static func bundledSource(bundle: Bundle = .main) -> String? {
        if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/PiDesktop
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/\(resourceName).\(resourceExtension)")
        return try? String(contentsOf: devURL, encoding: .utf8)
    }

    /// Reads the integer after the version marker comment, scanning only the first few lines
    /// (the marker is always at the top of the file).
    static func version(of source: String) -> Int? {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(5) {
            guard line.hasPrefix(versionMarkerPrefix) else { continue }
            return Int(line.dropFirst(versionMarkerPrefix.count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Pure policy, independent of disk I/O: `installed == nil` means nothing is there yet.
    /// A missing or unparseable marker on either side always means "leave it alone" — this is
    /// the one rule that keeps a user's hand edits safe.
    static func decide(installed: String?, bundled: String) -> Outcome {
        guard let installed else { return .installed }
        guard let installedVersion = version(of: installed), let bundledVersion = version(of: bundled) else {
            return .skippedUserModified
        }
        return installedVersion < bundledVersion ? .upgraded : .upToDate
    }

    /// Installs/repairs on disk. Call off the main actor: this does blocking file I/O.
    /// `destination` defaults to the real install path but is overridable so tests never write
    /// into the user's actual `~/.pi/agent/extensions/`.
    @discardableResult
    static func run(
        isDisabled: Bool,
        destination: URL = ActivityExtensionInstaller.installedFileURL(),
        fileManager: FileManager = .default
    ) -> Outcome {
        guard !isDisabled else { return .disabled }
        guard let bundled = bundledSource() else { return .sourceUnavailable }
        let installed = try? String(contentsOf: destination, encoding: .utf8)
        let outcome = decide(installed: installed, bundled: bundled)
        guard outcome == .installed || outcome == .upgraded else { return outcome }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // `atomically: true` writes to an auxiliary file and renames, so a session reading
            // this path (extensions reload on `/reload`, not mid-write) never sees a partial file.
            try bundled.write(to: destination, atomically: true, encoding: .utf8)
            return outcome
        } catch {
            return .writeFailed
        }
    }
}

/// Whether the user has opted out of Pi Desktop's installed Pi extension entirely. Kept as its
/// own UserDefaults flag rather than a new `PersistedAppState` field, so a fresh install/upgrade of
/// Pi Desktop never depends on the session-summary/archive state schema, and a power user (or a
/// future settings UI) can flip it with a single `defaults write`.
enum ActivityExtensionSettings {
    static let disabledDefaultsKey = "PiDesktopActivityHeartbeatDisabled"

    static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: disabledDefaultsKey)
    }

    static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: disabledDefaultsKey)
    }
}
