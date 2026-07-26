import Darwin
import Foundation

/// `Process`'s stdio pipes are plain POSIX pipes, not sockets \u2014 `RawSocket`'s `recv`/
/// `SO_RCVTIMEO` (used for the client's UDS/TCP connections) do not apply to them. This is the
/// pipe equivalent: `poll()` for a bounded wait, then a plain `read`/`write`.
enum PipeReadResult { case data(Data); case timeout; case eof }

enum BlockingPipeIO {
    static func read(fd: Int32, maxBytes: Int, timeoutSeconds: TimeInterval) -> PipeReadResult {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMillis: Int32 = timeoutSeconds > 0 ? Int32(min(timeoutSeconds, 3600) * 1_000) : 0
        let ready = poll(&pfd, 1, timeoutMillis)
        guard ready > 0 else { return .timeout }
        guard Int32(pfd.revents) & (Int32(POLLIN) | Int32(POLLHUP)) != 0 else { return .timeout }

        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let count = bytes.withUnsafeMutableBytes { pointer in Darwin.read(fd, pointer.baseAddress, maxBytes) }
        if count > 0 { return .data(Data(bytes.prefix(count))) }
        return .eof
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { pointer in Darwin.write(fd, pointer.baseAddress, pointer.count) }
            if written > 0 {
                remaining.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw RunnerError.ioFailure("write() failed: \(String(cString: strerror(errno)))")
            }
        }
    }
}
