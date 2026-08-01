import Darwin
import Foundation
import PiDeskKit

/// A minimal, sequential agent session for the runner: start the process, send one command at a
/// time, wait for its response, and separately drain events until `agent_settled`.
///
/// Deliberately not a port of the app's `AgentRuntimeClient`: that client supports concurrent
/// in-flight commands and live UI callbacks, neither of which the runner needs — it drives
/// exactly one prompt per run, strictly in order. What the two *do* share is the protocol
/// translation: both drive an `AgentProtocolAdapter`, so this session speaks Pi, Codex, and
/// Claude Code without the runner above it knowing which.
final class PiRPCSession: @unchecked Sendable {
    private let adapter: AgentProtocolAdapter
    /// Adapters are documented as "called serially", and this session has two serialization
    /// domains that can touch one: writes hold `writeLock` from any task, while decoding runs on
    /// `ioQueue`. This lock is what actually makes the adapter's mutable state safe here.
    private let adapterLock = NSLock()
    private let process: Process
    private let inputHandle: FileHandle
    private let outputFD: Int32
    private let errorHandle: FileHandle
    private let ioQueue = DispatchQueue(label: "dev.pi.desktop.daemon.runner.io")
    private var framer = JSONLFramer()
    private let bufferLock = NSLock()
    private var buffer: [PiJSONValue] = []
    private var bufferedBytes = 0
    private static let bufferedValueLimit = 512
    private static let bufferedByteLimit = 16 * 1_024 * 1_024
    private var requestCounter = 0
    /// Serializes every write to Pi's stdin. Prompts come from the run's own task, while steer/
    /// follow-up deliveries and `extension_ui_response` answers arrive from HTTP handlers on
    /// other tasks entirely — two interleaved partial JSONL lines would corrupt the stream.
    private let writeLock = NSLock()
    /// Set when a write timed out or failed part-way through a record. The stream then holds a
    /// partial line that no later write can repair, so every subsequent write fails fast rather
    /// than appending onto a torn command.
    private var writeBroken: String?
    private let stderrLock = NSLock()
    private var stderrTail = ""
    /// Responses seen by whoever is draining output, kept so a caller that is *not* the drainer
    /// (a steer delivered from an HTTP handler) can still collect its acknowledgement. Bounded;
    /// oldest entries are evicted, never accumulated.
    private var responseCache: [(id: String, value: PiJSONValue, bytes: Int)] = []
    private var responseCacheBytes = 0
    static let responseCacheLimit = 64
    static let responseCacheByteLimit = 16 * 1_024 * 1_024

    var isRunning: Bool { process.isRunning }

    /// How long one write may wait for a wedged child to drain its stdin. A parameter only so a
    /// test can prove the bound in a fraction of a second instead of the production default.
    private let writeTimeout: TimeInterval

    var agent: AgentKind { adapter.agent }

    private init(
        adapter: AgentProtocolAdapter, process: Process, inputHandle: FileHandle,
        outputFD: Int32, errorHandle: FileHandle, writeTimeout: TimeInterval
    ) {
        self.adapter = adapter
        self.process = process
        self.inputHandle = inputHandle
        self.outputFD = outputFD
        self.errorHandle = errorHandle
        self.writeTimeout = writeTimeout
        watchStderr()
    }

    static func start(
        cwd: URL, sessionPath: URL?, piExecutable: URL, environment: [String: String],
        writeTimeout: TimeInterval = BlockingPipeIO.defaultWriteTimeout,
        initialSessionID: String? = nil,
        initialSessionName: String? = nil,
        adapter: AgentProtocolAdapter = PiProtocolAdapter()
    ) throws -> PiRPCSession {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = piExecutable
        process.arguments = adapter.launchArguments(
            sessionPath: sessionPath, cwd: cwd,
            initialSessionID: initialSessionID, initialSessionName: initialSessionName
        )
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        // Pipe descriptors are blocking by default, which would make a full stdin buffer park the
        // writing task indefinitely — the exact hang `BlockingPipeIO.writeAll`'s timeout exists to
        // bound. Non-blocking turns that into `EAGAIN`, which it can poll on with a deadline.
        let inputFD = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(inputFD, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(inputFD, F_SETFL, flags | O_NONBLOCK) }
        let session = PiRPCSession(
            adapter: adapter, process: process, inputHandle: input.fileHandleForWriting,
            outputFD: output.fileHandleForReading.fileDescriptor, errorHandle: error.fileHandleForReading,
            writeTimeout: writeTimeout
        )
        // A handshake has to be on the wire before any command, and only the adapter knows
        // whether this agent needs one.
        session.writeLock.lock()
        defer { session.writeLock.unlock() }
        for line in adapter.startupLines(sessionPath: sessionPath, cwd: cwd) {
            try session.writeRawLocked(line)
        }
        return session
    }

    /// Writes a correlated request and returns its id; the caller awaits the matching response
    /// separately via `receiveMatching`.
    @discardableResult
    func send(type: String, payload: [String: PiJSONValue] = [:]) throws -> String {
        writeLock.lock()
        defer { writeLock.unlock() }
        requestCounter += 1
        let id = "daemon-\(process.processIdentifier)-\(requestCounter)"

        switch adapterLock.withLock({ adapter.encode(command: type, id: id, payload: payload) }) {
        case let .write(lines):
            for line in lines { try writeRawLocked(line) }
        case .deferred:
            // The adapter is holding this until its handshake lands and will write it itself.
            // The caller still waits on `id`, and still times out if that never happens.
            break
        case let .immediate(value):
            // Answered from the adapter's own state; nothing reaches the process. It has to be
            // published into the *buffer*, which is what `receiveNext`/`receiveMatching` drain —
            // the response cache alone is only read by `awaitCachedResponse`, so a caller that
            // waits the ordinary way would have waited out its whole timeout.
            let response = AdapterEncoding.response(id: id, data: value)
            try appendBuffered([response])
            cacheResponses([response])
        case let .immediateWithEvents(value, events):
            let response = AdapterEncoding.response(id: id, data: value)
            try appendBuffered([response] + events)
            cacheResponses([response])
        case let .unsupported(what):
            throw RunnerError.unsupportedCommand(agent: adapter.agent, what: what)
        }
        return id
    }

    /// Writes a message whose correlation the caller owns — a dialog answer must echo the id the
    /// agent chose for its request, so it can never use `send`'s generated one.
    func sendRaw(_ object: [String: PiJSONValue]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let encoded = adapterLock.withLock {
            adapter.encodeUncorrelatedWithDisposition(.object(object))
        }
        guard encoded.wasAccepted else {
            throw RunnerError.ioFailure(
                "\(adapter.agent.displayName) could not match the dialog response to a pending request."
            )
        }
        for line in encoded.lines {
            try writeRawLocked(line)
        }
    }

    /// Must only be called with `writeLock` held.
    private func writeRawLocked(_ line: Data) throws {
        if let writeBroken { throw RunnerError.ioFailure(writeBroken) }
        guard !line.isEmpty else { return }
        do {
            try BlockingPipeIO.writeAll(
                fd: inputHandle.fileDescriptor,
                data: line,
                timeoutSeconds: writeTimeout
            )
        } catch let error as RunnerError {
            writeBroken = error.localizedDescription
            throw error
        } catch {
            let message = "Could not write to \(adapter.agent.displayName): \(error)"
            writeBroken = message
            throw RunnerError.ioFailure(message)
        }
    }

    /// Waits for the response to `id` *without* reading the pipe: the run's own consume loop is
    /// the reader, and this only inspects what that loop already cached. Returns `nil` when the
    /// wait elapses (or the run settled and stopped reading), which callers must treat as
    /// "outcome unknown" — never as "not delivered", or a resend would double-prompt Pi.
    func awaitCachedResponse(id: String, timeout: TimeInterval) async -> PiJSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cached = takeCachedResponse(id: id) { return cached }
            guard process.isRunning else { return takeCachedResponse(id: id) }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return takeCachedResponse(id: id)
    }

    private func takeCachedResponse(id: String) -> PiJSONValue? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard let index = responseCache.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = responseCache.remove(at: index)
        responseCacheBytes = max(0, responseCacheBytes - removed.bytes)
        return removed.value
    }

    private func cacheResponses(_ values: [PiJSONValue]) {
        let responses = values.compactMap { value -> (id: String, value: PiJSONValue, bytes: Int)? in
            guard value["type"]?.stringValue == "response", let id = value["id"]?.stringValue else { return nil }
            return (id, value, Self.retainedBytes(of: value))
        }
        guard !responses.isEmpty else { return }
        bufferLock.lock()
        for response in responses {
            if let existing = responseCache.firstIndex(where: { $0.id == response.id }) {
                responseCacheBytes = max(0, responseCacheBytes - responseCache.remove(at: existing).bytes)
            }
            guard response.bytes <= Self.responseCacheByteLimit else { continue }
            responseCache.append(response)
            responseCacheBytes += response.bytes
            while responseCache.count > Self.responseCacheLimit
                    || responseCacheBytes > Self.responseCacheByteLimit {
                responseCacheBytes = max(0, responseCacheBytes - responseCache.removeFirst().bytes)
            }
        }
        bufferLock.unlock()
    }

    var responseCacheUsageForTesting: (count: Int, bytes: Int) {
        bufferLock.withLock { (responseCache.count, responseCacheBytes) }
    }

    /// Waits for the next decoded line \u2014 response or event \u2014 up to `timeout`. `nil` means the
    /// timeout elapsed with nothing to deliver; the process is still running.
    func receiveNext(timeout: TimeInterval) async throws -> PiJSONValue? {
        if let buffered = popBuffered() { return buffered }
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    continuation.resume(returning: try blockingReadOneLine(timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Waits specifically for the response to `id`, buffering (not discarding) every event seen
    /// while waiting so a caller that later drains events for `agent_settled` still sees them.
    func receiveMatching(id: String, timeout: TimeInterval) async throws -> PiJSONValue {
        var deferred: [PiJSONValue] = []
        var deferredBytes = 0
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw RunnerError.timedOut(afterSeconds: timeout) }
                guard let value = try await receiveNext(timeout: min(remaining, 5)) else { continue }
                if value["type"]?.stringValue == "response", value["id"]?.stringValue == id {
                    _ = takeCachedResponse(id: id)
                    try restoreBuffered(deferred)
                    return value
                }
                let bytes = Self.retainedBytes(of: value)
                guard deferred.count < Self.bufferedValueLimit,
                      bytes <= Self.bufferedByteLimit,
                      deferredBytes <= Self.bufferedByteLimit - bytes else {
                    throw RunnerError.ioFailure("Agent emitted too many events before its response.")
                }
                deferred.append(value)
                deferredBytes += bytes
            }
        } catch {
            try? restoreBuffered(deferred)
            throw error
        }
    }

    /// Graceful SIGTERM with a short deadline before SIGKILL, matching the app's own
    /// `PiProcessReaper` \u2014 the runner must never leave a `pi` process behind.
    @discardableResult
    func stop() -> Bool {
        let stopped = PiProcessReaper.terminateAndWait(process)
        try? inputHandle.close()
        return stopped
    }

    private func popBuffered() -> PiJSONValue? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let value = buffer.removeFirst()
        bufferedBytes = max(0, bufferedBytes - Self.retainedBytes(of: value))
        return value
    }

    private func restoreBuffered(_ values: [PiJSONValue]) throws {
        guard !values.isEmpty else { return }
        try appendBuffered(values, atFront: true)
    }

    private func appendBuffered(_ values: [PiJSONValue], atFront: Bool = false) throws {
        guard !values.isEmpty else { return }
        let bytes = values.reduce(into: 0) { total, value in
            let size = Self.retainedBytes(of: value)
            let (next, overflow) = total.addingReportingOverflow(size)
            total = overflow ? Int.max : next
        }
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard values.count <= Self.bufferedValueLimit - buffer.count,
              bytes <= Self.bufferedByteLimit,
              bufferedBytes <= Self.bufferedByteLimit - bytes else {
            throw RunnerError.ioFailure("Agent event buffer exceeded its memory budget.")
        }
        if atFront { buffer.insert(contentsOf: values, at: 0) }
        else { buffer.append(contentsOf: values) }
        bufferedBytes += bytes
    }

    private static func retainedBytes(of value: PiJSONValue) -> Int {
        (try? PiDeskJSON.encoder.encode(value).count) ?? bufferedByteLimit
    }

    /// Must only run on `ioQueue`. One `read()` can surface multiple JSONL records; the rest are
    /// buffered so a later call still sees them instead of them being dropped.
    private func blockingReadOneLine(timeout: TimeInterval) throws -> PiJSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try throwIfWriteBroken()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            switch BlockingPipeIO.read(fd: outputFD, maxBytes: 64 * 1_024, timeoutSeconds: remaining) {
            case let .data(chunk):
                let records = framer.append(chunk)
                if framer.takeOverflowedRecordCount() > 0 {
                    throw RunnerError.ioFailure(
                        "\(adapter.agent.displayName) emitted an oversized protocol record."
                    )
                }
                guard !records.isEmpty else { continue }
                // Translation happens here, so everything above this line — the run loop, the
                // settlement bookkeeping, steering, dialogs — only ever sees the one vocabulary.
                // Hold the outbound write lock across decode, writeback drain, and writeback. A
                // concurrent HTTP delivery cannot overtake a handshake acknowledgement or a
                // command that this inbound record just unblocked.
                writeLock.lock()
                let transaction: (values: [PiJSONValue], writes: [Data]) = adapterLock.withLock {
                    let values = records.flatMap { record in
                        adapter.decode(line: record).map { message in
                            switch message {
                            case let .response(_, value): value
                            case let .event(value): value
                            }
                        }
                    }
                    let writes = (adapter as? AdapterWriteback)?.drainPendingWrites() ?? []
                    return (values, writes)
                }
                do {
                    for line in transaction.writes { try writeRawLocked(line) }
                    writeLock.unlock()
                } catch {
                    writeLock.unlock()
                    throw error
                }
                let values = transaction.values
                cacheResponses(values)
                guard let first = values.first else { continue }
                if values.count > 1 {
                    try appendBuffered(Array(values.dropFirst()))
                }
                return first
            case .timeout:
                if !process.isRunning { throw RunnerError.processExited(drainStderrTail()) }
                return nil
            case .eof:
                throw RunnerError.processExited(drainStderrTail())
            }
        }
    }

    private func throwIfWriteBroken() throws {
        let failure = writeLock.withLock { writeBroken }
        if let failure { throw RunnerError.ioFailure(failure) }
    }

    private func watchStderr() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                switch BlockingPipeIO.read(fd: errorHandle.fileDescriptor, maxBytes: 16 * 1_024, timeoutSeconds: 3_600) {
                case let .data(chunk):
                    stderrLock.lock()
                    stderrTail.append(String(decoding: chunk, as: UTF8.self))
                    if stderrTail.count > 8_192 { stderrTail.removeFirst(stderrTail.count - 8_192) }
                    stderrLock.unlock()
                case .timeout:
                    if !process.isRunning { return }
                    continue
                case .eof:
                    return
                }
            }
        }
    }

    private func drainStderrTail() -> String {
        stderrLock.lock(); defer { stderrLock.unlock() }
        return stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
