import Foundation

/// `daemon.json`: the handful of settings `patchwork remote enable/disable` and the daemon itself
/// need to agree on. Small enough that the whole file is rewritten on every change rather than
/// patched in place.
public struct DaemonSettings: Codable, Hashable, Sendable {
    public static let defaultPort = 7717
    public static let defaultConcurrency = 2

    public var remoteEnabled: Bool
    public var port: Int
    public var concurrency: Int

    public init(remoteEnabled: Bool = false, port: Int = DaemonSettings.defaultPort, concurrency: Int = DaemonSettings.defaultConcurrency) {
        self.remoteEnabled = remoteEnabled
        self.port = port
        self.concurrency = concurrency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteEnabled) ?? false
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        concurrency = try container.decodeIfPresent(Int.self, forKey: .concurrency) ?? Self.defaultConcurrency
    }

    public static func load(from url: URL = PatchworkPaths.daemonSettings) -> DaemonSettings {
        PatchworkFile.readIfPresent(DaemonSettings.self, from: url) ?? DaemonSettings()
    }

    public func save(to url: URL = PatchworkPaths.daemonSettings) throws {
        try PatchworkFile.writeAtomic(self, to: url)
    }
}

/// The bearer token gating the loopback TCP listener. Filesystem permissions are the only
/// protection for the Unix socket, so this file is the entire security boundary for the TCP
/// side — 32 random bytes, `0600`, created once and reused.
public enum DaemonToken {
    private static let byteCount = 32

    /// Reads the existing token, or generates and persists a new one. Callers on the daemon side
    /// use this to get a token to enforce; callers on the client side (`patchwork remote token`)
    /// use it to display the token an operator pastes into a bearer header.
    public static func loadOrCreate(at url: URL = PatchworkPaths.tokenFile) throws -> String {
        if let data = FileManager.default.contents(atPath: url.path),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        let token = generate()
        try PatchworkFile.writeAtomic(Data(token.utf8), to: url)
        return token
    }

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if result != errSecSuccess {
            // SecRandomCopyBytes failing at all is exceptional; arc4random_buf never fails and
            // is still a CSPRNG, so this keeps token generation total instead of throwing.
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// Constant-time-ish comparison so a timing attack cannot narrow down the token character by
    /// character. Not perfectly constant time (Swift string/byte handling makes that hard to
    /// guarantee), but it never short-circuits on the first mismatching byte.
    public static func matches(_ candidate: String, token: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
