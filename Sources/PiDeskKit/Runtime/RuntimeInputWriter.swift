import Darwin
import Foundation

enum RuntimeInputWriterError: LocalizedError {
    case couldNotDuplicate(String)
    case backpressured

    var errorDescription: String? {
        switch self {
        case let .couldNotDuplicate(detail): "Could not open the agent input pipe: \(detail)"
        case .backpressured: "The agent input queue is full. Wait for the current requests to finish."
        }
    }
}

/// One serial writer per process generation. POSIX nonblocking writes keep backpressure off the
/// transport's state queue, while the generation check lets Stop retire a full pipe promptly.
final class RuntimeInputWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let descriptor: Int32
    private let generation: RuntimeGeneration
    private let timeout: TimeInterval
    private let admissionLock = NSLock()
    private let maximumQueuedJobs: Int
    private let maximumQueuedBytes: Int
    private var queuedJobs = 0
    private var queuedBytes = 0

    init(
        handle: FileHandle,
        generation: RuntimeGeneration,
        timeout: TimeInterval = 15,
        maximumQueuedJobs: Int = 256,
        maximumQueuedBytes: Int = 128 * 1_024 * 1_024
    ) throws {
        let descriptor = Darwin.dup(handle.fileDescriptor)
        guard descriptor >= 0 else {
            throw RuntimeInputWriterError.couldNotDuplicate(String(cString: strerror(errno)))
        }
        self.descriptor = descriptor
        self.generation = generation
        self.timeout = timeout
        self.maximumQueuedJobs = max(1, maximumQueuedJobs)
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        queue = DispatchQueue(
            label: "dev.pi.desktop.rpc.stdin.\(generation.sequence)",
            qos: .userInitiated
        )

        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }

    @discardableResult
    func enqueue(
        _ lines: [Data],
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool {
        let currentGeneration = generation
        let byteCount = lines.reduce(into: 0) { total, line in
            let (next, overflow) = total.addingReportingOverflow(line.count)
            total = overflow ? Int.max : next
        }
        let admitted = admissionLock.withLock { () -> Bool in
            guard currentGeneration.isValid,
                  queuedJobs < maximumQueuedJobs,
                  byteCount <= maximumQueuedBytes,
                  queuedBytes <= maximumQueuedBytes - byteCount else { return false }
            queuedJobs += 1
            queuedBytes += byteCount
            return true
        }
        guard admitted else { return false }

        queue.async { [weak self] in
            defer { self?.releaseAdmission(bytes: byteCount) }
            guard let self, currentGeneration.isValid else {
                completion(.failure(BlockingPipeIOError.cancelled))
                return
            }
            do {
                for line in lines where !line.isEmpty {
                    try writeAll(line)
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        return true
    }

    private func releaseAdmission(bytes: Int) {
        admissionLock.withLock {
            queuedJobs = max(0, queuedJobs - 1)
            queuedBytes = max(0, queuedBytes - bytes)
        }
    }

    private func writeAll(_ data: Data) throws {
        try BlockingPipeIO.writeAll(
            fd: descriptor,
            data: data,
            timeoutSeconds: timeout,
            isCancelled: { [generation] in !generation.isValid }
        )
    }

    deinit {
        Darwin.close(descriptor)
    }
}
