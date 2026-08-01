import Foundation

/// Links the bundled `patchwork` into the user's `~/.local/bin`, which is where the Pi CLI itself
/// lives and is already on `PATH`.
///
/// The CLI ships inside `Patchwork.app/Contents/Helpers/`, so without this it can only be run
/// by typing the whole bundle path — which defeats the point of having a CLI another agent can
/// drive. A symlink (rather than a copy) means an app update is picked up automatically.
enum CommandLineToolInstaller {
    enum State: Equatable {
        case installed(path: String)
        /// A link or binary is there, but it is not ours.
        case conflicting(path: String)
        case notInstalled
        /// The app is running from a build directory, so there is nothing stable to link to.
        case unavailable
    }

    static var destinationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var destination: URL { destinationDirectory.appendingPathComponent("patchwork") }

    static var legacyDestination: URL { destinationDirectory.appendingPathComponent("pidesk") }

    /// The bundled CLI, or `nil` when running outside a packaged app.
    static var bundledTool: URL? {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/patchwork")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    static func state(fileManager: FileManager = .default) -> State {
        guard let bundledTool else { return .unavailable }
        let path = destination.path
        guard fileManager.fileExists(atPath: path) else { return .notInstalled }
        // A symlink we own points back into some Patchwork bundle; anything else is the user's.
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: destinationDirectory).standardizedFileURL.path
            return resolved == bundledTool.standardizedFileURL.path || resolved.contains("Patchwork.app/Contents/Helpers/")
                ? .installed(path: path)
                : .conflicting(path: path)
        }
        return .conflicting(path: path)
    }

    /// Creates (or repoints) the symlink. Never overwrites something that is not ours.
    @discardableResult
    static func install(fileManager: FileManager = .default) throws -> String {
        guard let bundledTool else { throw InstallError.notPackaged }
        if case .conflicting(let path) = state(fileManager: fileManager) {
            throw InstallError.occupied(path: path)
        }
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: bundledTool)
        return destination.path
    }

    /// Carries forward an explicitly installed symlink from the previous app name. A plain file,
    /// a link to any other tool, or an occupied Patchwork destination is never changed.
    @discardableResult
    static func migrateLegacyInstallation(
        fileManager: FileManager = .default,
        legacy: URL = legacyDestination,
        destination: URL = destination,
        bundledTool: URL? = bundledTool
    ) -> Bool {
        guard let bundledTool,
              !fileManager.fileExists(atPath: destination.path),
              let target = try? fileManager.destinationOfSymbolicLink(atPath: legacy.path) else { return false }
        let resolved = URL(fileURLWithPath: target, relativeTo: legacy.deletingLastPathComponent())
            .standardizedFileURL.path
        guard resolved.contains("Pi Desktop.app/Contents/Helpers/pidesk") else { return false }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: bundledTool)
            try fileManager.removeItem(at: legacy)
            return true
        } catch {
            try? fileManager.removeItem(at: destination)
            return false
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case notPackaged
        case occupied(path: String)

        var errorDescription: String? {
            switch self {
            case .notPackaged:
                "The command line tool is only available from the packaged app."
            case let .occupied(path):
                "Something else already exists at \(path). Remove it first."
            }
        }
    }
}
