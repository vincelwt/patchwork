import Darwin
import Foundation
import PatchworkKit

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
    private let ioQueue = DispatchQueue(label: "app.patchwork.desktop.daemon.runner.io")
    private var framer = JSONLFramer()
    private let bufferLock = NSLock()
    private var buffer: [PiJSONValue] = []
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
    private var responseCache: [(id: String, value: PiJSONValue)] = []
    private static let responseCacheLimit = 64

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
        adapter: AgentProtocolAdapter = PiProtocolAdapter()
    ) throws -> PiRPCSession {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = piExecutable
        process.arguments = adapter.launchArguments(sessionPath: sessionPath, cwd: cwd)
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
            bufferLock.lock()
            buffer.append(response)
            bufferLock.unlock()
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
        for line in adapterLock.withLock({ adapter.encodeUncorrelated(.object(object)) }) {
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
        return responseCache.remove(at: index).value
    }

    private func cacheResponses(_ values: [PiJSONValue]) {
        let responses = values.compactMap { value -> (id: String, value: PiJSONValue)? in
            guard value["type"]?.stringValue == "response", let id = value["id"]?.stringValue else { return nil }
            return (id, value)
        }
        guard !responses.isEmpty else { return }
        bufferLock.lock()
        responseCache.append(contentsOf: responses)
        if responseCache.count > Self.responseCacheLimit {
            responseCache.removeFirst(responseCache.count - Self.responseCacheLimit)
        }
        bufferLock.unlock()
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
        defer { restoreBuffered(deferred) }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RunnerError.timedOut(afterSeconds: timeout) }
            guard let value = try await receiveNext(timeout: min(remaining, 5)) else { continue }
            if value["type"]?.stringValue == "response", value["id"]?.stringValue == id { return value }
            deferred.append(value)
        }
    }

    /// Graceful SIGTERM with a short deadline before SIGKILL, matching the app's own
    /// `PiProcessReaper` \u2014 the runner must never leave a `pi` process behind.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(40_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? inputHandle.close()
    }

    private func popBuffered() -> PiJSONValue? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return buffer.isEmpty ? nil : buffer.removeFirst()
    }

    private func restoreBuffered(_ values: [PiJSONValue]) {
        guard !values.isEmpty else { return }
        bufferLock.lock(); buffer.insert(contentsOf: values, at: 0); bufferLock.unlock()
    }

    /// Must only run on `ioQueue`. One `read()` can surface multiple JSONL records; the rest are
    /// buffered so a later call still sees them instead of them being dropped.
    private func blockingReadOneLine(timeout: TimeInterval) throws -> PiJSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            switch BlockingPipeIO.read(fd: outputFD, maxBytes: 64 * 1_024, timeoutSeconds: remaining) {
            case let .data(chunk):
                let records = framer.append(chunk)
                guard !records.isEmpty else { continue }
                // Translation happens here, so everything above this line — the run loop, the
                // settlement bookkeeping, steering, dialogs — only ever sees the one vocabulary.
                let values: [PiJSONValue] = adapterLock.withLock {
                    records.flatMap { record in
                        adapter.decode(line: record).map { message in
                            switch message {
                            case let .response(_, value): value
                            case let .event(value): value
                            }
                        }
                    }
                }
                // An adapter may owe the agent a reply as a consequence of decoding (a protocol
                // acknowledgement, a queued command unblocked by a completed handshake).
                if let writeback = adapter as? AdapterWriteback {
                    let pending = adapterLock.withLock { writeback.drainPendingWrites() }
                    if !pending.isEmpty {
                        writeLock.lock()
                        for line in pending { try? writeRawLocked(line) }
                        writeLock.unlock()
                    }
                }
                cacheResponses(values)
                guard let first = values.first else { continue }
                if values.count > 1 {
                    bufferLock.lock(); buffer.append(contentsOf: values.dropFirst()); bufferLock.unlock()
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
