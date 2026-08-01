import Darwin
import Foundation

/// Result of one bounded read from a process pipe.
public enum PipeReadResult {
    case data(Data)
    case timeout
    case eof
}

public enum BlockingPipeIOError: LocalizedError {
    case cancelled
    case timedOut
    case operationFailed(String)
    case closed(midWrite: Bool)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The process input was retired."
        case .timedOut: "The process did not accept input in time."
        case let .operationFailed(detail): detail
        case let .closed(midWrite): midWrite
            ? "The process closed its input mid-command."
            : "The process closed its input."
        }
    }
}

/// Bounded POSIX I/O for process pipes. Socket timeouts do not apply to stdin/stdout pipes.
public enum BlockingPipeIO {
    public static let defaultWriteTimeout: TimeInterval = 15

    public static func read(fd: Int32, maxBytes: Int, timeoutSeconds: TimeInterval) -> PipeReadResult {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMillis: Int32 = timeoutSeconds > 0 ? Int32(min(timeoutSeconds, 3_600) * 1_000) : 0
        let ready = poll(&descriptor, 1, timeoutMillis)
        guard ready > 0 else { return .timeout }
        guard Int32(descriptor.revents) & (Int32(POLLIN) | Int32(POLLHUP)) != 0 else { return .timeout }

        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let count = bytes.withUnsafeMutableBytes { pointer in
            Darwin.read(fd, pointer.baseAddress, maxBytes)
        }
        if count > 0 { return .data(Data(bytes.prefix(count))) }
        return .eof
    }

    /// Writes every byte or throws, checking cancellation at most every 100 ms under backpressure.
    public static func writeAll(
        fd: Int32,
        data: Data,
        timeoutSeconds: TimeInterval = defaultWriteTimeout,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                if isCancelled() { throw BlockingPipeIOError.cancelled }
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw BlockingPipeIOError.operationFailed(
                        "write() failed: \(String(cString: strerror(errno)))"
                    )
                }
                try waitWritable(
                    fd: fd,
                    deadline: deadline,
                    wroteAnything: offset > 0,
                    isCancelled: isCancelled
                )
            }
        }
    }

    private static func waitWritable(
        fd: Int32,
        deadline: Date,
        wroteAnything: Bool,
        isCancelled: @Sendable () -> Bool
    ) throws {
        while true {
            if isCancelled() { throw BlockingPipeIOError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw BlockingPipeIOError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let waitMillis = Int32(max(1, min(remaining, 0.1) * 1_000))
            let ready = poll(&descriptor, 1, waitMillis)
            if ready < 0, errno == EINTR { continue }
            if ready < 0 {
                throw BlockingPipeIOError.operationFailed(
                    "poll() failed: \(String(cString: strerror(errno)))"
                )
            }
            if ready == 0 { continue }
            if Int32(descriptor.revents) & (Int32(POLLERR) | Int32(POLLHUP) | Int32(POLLNVAL)) != 0 {
                throw BlockingPipeIOError.closed(midWrite: wroteAnything)
            }
            if Int32(descriptor.revents) & Int32(POLLOUT) != 0 { return }
        }
    }
}
