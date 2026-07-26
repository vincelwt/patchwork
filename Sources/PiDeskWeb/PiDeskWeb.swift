import Foundation

/// The remote web UI, served by the daemon from bundled resources. Kept as a separate module so
/// the daemon's HTTP layer stays free of asset handling and the site can be tested on its own.
public enum PiDeskWeb {
    /// A file the daemon should return for a request path, already resolved and bounded.
    public struct Asset: Sendable, Equatable {
        public let data: Data
        public let contentType: String
        public init(data: Data, contentType: String) {
            self.data = data
            self.contentType = contentType
        }
    }

    /// Resolves a request path to a bundled asset. Filled in by the web implementation.
    public static func asset(for path: String) -> Asset? {
        _ = path
        return nil
    }
}
