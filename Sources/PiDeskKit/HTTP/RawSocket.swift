import Darwin
import Foundation

/// Minimal blocking POSIX socket helpers behind `PiDeskClient`. `URLSession` cannot open a Unix
/// domain socket, and the doc requires speaking the same protocol over both transports, so the
/// client rolls its own tiny connector for each rather than special-casing one of them.
public enum RawSocketError: Error, LocalizedError {
    case unreachable(String)
    case ioFailure(String)
    case pathTooLong

    public var errorDescription: String? {
        switch self {
        case let .unreachable(detail): detail
        case let .ioFailure(detail): detail
        case .pathTooLong: "Socket path is too long for sockaddr_un."
        }
    }
}

/// `internal` connect helpers plus `public` read/write/timeout primitives: connecting is
/// transport-specific (the client dials out over either UDS or TCP), but once a socket exists,
/// reading, writing, and setting timeouts are identical for a client connection and a server's
/// accepted connection — `PiDeskDaemon`'s `HTTPServer` reuses exactly these for its own sockets
/// rather than duplicating POSIX boilerplate.
public enum RawSocket {
    /// Connects to a Unix domain socket. `ENOENT`/`ECONNREFUSED` (no daemon, or a stale socket
    /// file with nothing listening) is exactly the "daemon unreachable" case callers need to
    /// distinguish from a real protocol error.
    public static func connectUnix(path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawSocketError.ioFailure("socket() failed: \(lastError())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw RawSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (index, byte) in pathBytes.enumerated() { base[index] = byte }
            base[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = lastError()
            Darwin.close(fd)
            throw RawSocketError.unreachable("Could not connect to \(path): \(detail)")
        }
        setTimeouts(fd: fd, timeout: timeout)
        return fd
    }

    /// Loopback TCP only, matching the doc's transport (`127.0.0.1:<port>`); `host` must be a
    /// numeric IPv4 address.
    public static func connectTCP(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawSocketError.ioFailure("socket() failed: \(lastError())") }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw RawSocketError.ioFailure("\(host) is not a numeric IPv4 address")
        }

        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let detail = lastError()
            Darwin.close(fd)
            throw RawSocketError.unreachable("Could not connect to \(host):\(port): \(detail)")
        }
        setTimeouts(fd: fd, timeout: timeout)
        return fd
    }

    public static func setTimeouts(fd: Int32, timeout: TimeInterval) {
        guard timeout > 0 else { return }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func writeAll(fd: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
            }
            if written > 0 {
                remaining.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw RawSocketError.ioFailure("send() failed: \(lastError())")
            }
        }
    }

    /// One read. `nil` covers EOF, a timeout, and a hard error alike — a one-shot request/
    /// response connection treats all three the same way: stop reading and parse what arrived.
    public static func read(fd: Int32, maxBytes: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes { pointer in
            Darwin.recv(fd, pointer.baseAddress, maxBytes, 0)
        }
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    public static func readAllUntilClosed(fd: Int32, maxBytes: Int) throws -> Data {
        var result = Data()
        while let chunk = read(fd: fd, maxBytes: 64 * 1_024) {
            result.append(chunk)
            if result.count > maxBytes { throw RawSocketError.ioFailure("response exceeded \(maxBytes) bytes") }
        }
        return result
    }

    /// Unblocks a thread parked in `recv` on this fd before closing it, so a cancelled SSE
    /// consumer's reader thread does not linger.
    public static func shutdownAndClose(fd: Int32) {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private static func lastError() -> String { String(cString: strerror(errno)) }
}
