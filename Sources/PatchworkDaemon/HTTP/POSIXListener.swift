import Darwin
import Foundation
import PatchworkKit

enum ListenerError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case let .failed(message) = self { message } else { nil } }
}

/// Binds and accepts on either a Unix domain socket or loopback TCP. Both are plain POSIX
/// sockets underneath; only address setup and permissions differ.
final class POSIXListener {
    let fd: Int32
    let origin: RequestOrigin

    private init(fd: Int32, origin: RequestOrigin) {
        self.fd = fd
        self.origin = origin
    }

    /// Binds the control socket at `path`. If a previous daemon crashed and left the socket file
    /// behind, a fresh attempt to connect to it fails (nothing is listening), which is exactly
    /// the signal to unlink and rebind; if something *is* listening, this refuses to steal the
    /// socket out from under a live daemon.
    static func unixSocket(path: URL) throws -> POSIXListener {
        try PatchworkFile.ensureDirectory(path.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: path.path) {
            if let probe = try? RawSocket.connectUnix(path: path.path, timeout: 0.5) {
                Darwin.close(probe)
                throw ListenerError.failed("Another daemon is already listening on \(path.path).")
            }
            try? FileManager.default.removeItem(at: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.failed("socket() failed: \(lastError())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw ListenerError.failed("Socket path too long: \(path.path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (index, byte) in pathBytes.enumerated() { base[index] = byte }
            base[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = lastError()
            Darwin.close(fd)
            throw ListenerError.failed("bind(\(path.path)) failed: \(detail)")
        }
        // The doc's whole authorization model for this transport: 0700 dir (ensured above), 0600
        // socket, so only this user's processes can even open a connection.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        guard listen(fd, 64) == 0 else {
            let detail = lastError()
            Darwin.close(fd)
            throw ListenerError.failed("listen() failed: \(detail)")
        }
        return POSIXListener(fd: fd, origin: .unixSocket)
    }

    static func tcpLoopback(port: Int) throws -> POSIXListener {
        guard (0...65_535).contains(port) else {
            throw ListenerError.failed("TCP port must be between 0 and 65535.")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.failed("socket() failed: \(lastError())") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        // Never a public listener: bound to loopback only, matching the doc's "the daemon never
        // opens a public listener itself" rule.
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = lastError()
            Darwin.close(fd)
            throw ListenerError.failed("bind(127.0.0.1:\(port)) failed: \(detail)")
        }
        guard listen(fd, 64) == 0 else {
            let detail = lastError()
            Darwin.close(fd)
            throw ListenerError.failed("listen() failed: \(detail)")
        }
        return POSIXListener(fd: fd, origin: .tcp)
    }

    /// Blocking accept loop; call on a dedicated thread. Returns when the listener is closed.
    func acceptLoop(_ onAccept: @escaping (Int32) -> Void) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // listener closed (EBADF) or unrecoverable; stop this loop quietly
            }
            do {
                try RawSocket.suppressBrokenPipeSignal(fd: client)
            } catch {
                Darwin.close(client)
                continue
            }
            onAccept(client)
        }
    }

    func close() { Darwin.close(fd) }

    private static func lastError() -> String { String(cString: strerror(errno)) }
}
