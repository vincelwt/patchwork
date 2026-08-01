import Foundation

/// One deterministic projection for legacy archive sets read by the app, daemon, and client.
/// New writes are path keyed, while legacy ids remain decode-only migration input.
public enum ArchiveStateBounds {
    public static let itemLimit = 10_000
    /// Shared read/write ceiling for the native app's state file. The daemon must accept every
    /// state payload the app can legitimately persist or archive, read, and custom-root ownership
    /// can disappear from CLI projections after a restart.
    public static let appStateByteLimit = 32 * 1_024 * 1_024

    public static func legacyIDs(_ values: Set<String>) -> Set<String> {
        Set(values.sorted().suffix(itemLimit))
    }

    public static func standardizedPaths(_ values: Set<String>) -> Set<String> {
        Set(Set(values.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }).sorted().suffix(itemLimit))
    }
}
