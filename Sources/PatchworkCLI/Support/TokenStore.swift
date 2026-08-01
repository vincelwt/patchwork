import Darwin
import Foundation

/// Reads or lazily creates the loopback remote's bearer token. Matches docs/daemon-api.md exactly:
/// 32 random bytes, base64url, `0600`, alongside the control socket.
enum TokenStore {
    @discardableResult
    static func ensureToken(at url: URL, fileManager: FileManager = .default) throws -> String {
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fileManager.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CLIFailure(exitCode: .requestFailed, message: "could not write token file at \(url.path)")
        }
        return token
    }

    static func readToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }
}
