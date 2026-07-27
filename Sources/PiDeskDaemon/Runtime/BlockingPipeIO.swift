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

    /// Writes every byte, or throws — but never blocks past `timeoutSeconds`.
    ///
    /// A pipe write blocks once the kernel buffer fills, which happens whenever the child stops
    /// reading its stdin. That is exactly what a wedged `pi` looks like, and an unbounded write
    /// there pins whichever task issued it: a steer arriving over HTTP would hold both an HTTP
    /// handler and the session's write lock until the process was killed. `poll()` for writability
    /// between attempts bounds that to a timeout the caller chose.
    ///
    /// Throwing means "this command did not run". A timeout mid-line leaves a partial record in
    /// the child's stdin, which is not a complete JSONL command and so cannot have been executed;
    /// callers may safely fall back to sending it another way. The stream itself is no longer
    /// trustworthy afterwards, which `PiRPCSession` handles by refusing every later write.
    static func writeAll(fd: Int32, data: Data, timeoutSeconds: TimeInterval = defaultWriteTimeout) throws {
        var remaining = data
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { pointer in Darwin.write(fd, pointer.baseAddress, pointer.count) }
            if written > 0 {
                remaining.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw RunnerError.ioFailure("write() failed: \(String(cString: strerror(errno)))")
            }
            // Non-blocking descriptor with a full buffer: wait for room, bounded.
            guard try waitWritable(fd: fd, deadline: deadline, wroteAnything: remaining.count != data.count) else {
                throw RunnerError.ioFailure("Pi did not accept input within \(Int(timeoutSeconds))s.")
            }
        }
    }

    /// Generous on purpose: a healthy `pi` drains its stdin immediately, so reaching this means the
    /// child is genuinely wedged rather than merely busy.
    static let defaultWriteTimeout: TimeInterval = 15

    /// `true` once the descriptor is writable again, `false` if the deadline passed first.
    private static func waitWritable(fd: Int32, deadline: Date, wroteAnything: Bool) throws -> Bool {
        while true {
            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remainingSeconds, 3_600) * 1_000))
            if ready < 0, errno == EINTR { continue }
            if ready < 0 { throw RunnerError.ioFailure("poll() failed: \(String(cString: strerror(errno)))") }
            if ready == 0 { return false }
            // The reader closed: writing again would raise SIGPIPE/EPIPE, so fail now instead.
            if Int32(pfd.revents) & (Int32(POLLERR) | Int32(POLLHUP) | Int32(POLLNVAL)) != 0 {
                throw RunnerError.ioFailure(wroteAnything ? "Pi closed its input mid-command." : "Pi closed its input.")
            }
            if Int32(pfd.revents) & Int32(POLLOUT) != 0 { return true }
        }
    }
}
