import Foundation
import PatchworkKit

/// Appends to `~/Library/Logs/Patchwork/daemon.log`, rotating a single backup so a daemon left
/// running for months cannot grow the log without bound. Every write is serialized through a
/// private queue so concurrent requests never interleave partial lines.
final class DaemonLogger: @unchecked Sendable {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.patchwork.desktop.daemon.log")
    /// Rotate once the log passes this size, matching the doc's "bounded/rotated" requirement.
    private let maxBytes: Int
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(fileURL: URL = PatchworkPaths.logFile, maxBytes: Int = 8 * 1_024 * 1_024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        _ = try? PatchworkFile.ensureDirectory(fileURL.deletingLastPathComponent())
    }

    func log(_ level: Level, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        queue.async { [self] in
            rotateIfNeeded()
            append(line)
        }
    }

    func debug(_ message: String) { log(.debug, message) }
    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }

    /// Blocks until every previously queued line is on disk; tests use this to make assertions
    /// deterministic instead of racing the background queue.
    func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes else { return }
        let rotated = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}
