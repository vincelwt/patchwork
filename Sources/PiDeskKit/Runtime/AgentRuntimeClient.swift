import Darwin
import Foundation

public protocol AgentRuntimeProtocol: AnyObject {
    var onEvent: ((PiJSONValue) -> Void)? { get set }
    var onExit: ((String?) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Which agent this runtime drives. The store gates affordances on its capabilities.
    var agent: AgentKind { get }

    func configureLaunch(modelID: String?, thinkingLevel: String?)
    func configureFastMode(_ enabled: Bool)
    func start(cwd: URL, sessionPath: URL?) throws
    func stop()
    func send(type: String, payload: [String: PiJSONValue], completion: ((Result<PiJSONValue, Error>) -> Void)?)
    func sendUncorrelated(_ value: PiJSONValue)
}

public extension AgentRuntimeProtocol {
    var agent: AgentKind { .pi }
    func configureLaunch(modelID: String?, thinkingLevel: String?) {}
    func configureFastMode(_ enabled: Bool) {}
}

public enum AgentRuntimeError: LocalizedError {
    case notInstalled(AgentKind)
    case notRunning
    case invalidCommand
    /// Local admission failed before any bytes were offered to the agent.
    case overloaded(String)
    /// The agent cannot do this at all, and said so without a round trip.
    case unsupported(AgentKind, String)
    /// The agent did not answer a side-effect-free query in time; safe to treat as a failure.
    case timedOut(String, seconds: TimeInterval)
    /// The agent did not confirm a command that may already have been applied. Callers must not
    /// roll back drafts or resubmit on this error.
    case outcomeUnknown(String)
    case processExited(String)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(agent):
            switch agent {
            case .pi: "Pi CLI was not found. Set PI_DESKTOP_PI_PATH or install pi in ~/.local/bin."
            case .codex: "Codex CLI was not found. Set PI_DESKTOP_CODEX_PATH or install codex."
            case .claude: "Claude Code was not found. Set PI_DESKTOP_CLAUDE_PATH or install claude."
            }
        case .notRunning:
            "The agent is not running."
        case .invalidCommand:
            "Could not encode a runtime command."
        case let .overloaded(message):
            message
        case let .unsupported(agent, what):
            "\(agent.displayName) does not support \(what)."
        case let .timedOut(command, seconds):
            "The agent did not respond to \(command) within \(Int(seconds)) seconds."
        case let .outcomeUnknown(command):
            "The agent never confirmed \(command). It may already have been applied, so nothing was undone."
        case let .processExited(message):
            message
        }
    }
}

/// One agent subprocess speaking LF-delimited JSON over stdio.
///
/// The transport is agent-agnostic: spawning, pipe reads, request correlation, timeouts,
/// generation fencing, and reaping are identical for Pi, Codex, and Claude Code. Everything
/// that differs lives behind `AgentProtocolAdapter`.
public final class AgentRuntimeClient: AgentRuntimeProtocol, @unchecked Sendable {
    private struct RuntimeExitTarget {
        let handler: ((String?) -> Void)?
    }

    private let callbackLock = NSLock()
    private var eventHandler: ((PiJSONValue) -> Void)?
    private var exitHandler: ((String?) -> Void)?
    private var eventHandlerRevision = 0
    private var terminationObservationHook: (() -> Void)?
    public var onEvent: ((PiJSONValue) -> Void)? {
        get { callbackLock.withLock { eventHandler } }
        set {
            callbackLock.withLock {
                eventHandlerRevision &+= 1
                eventHandler = newValue
            }
        }
    }
    public var onExit: ((String?) -> Void)? {
        get { callbackLock.withLock { exitHandler } }
        set { callbackLock.withLock { exitHandler = newValue } }
    }

    /// A deterministic test seam for the instant an exit has captured its owner but has not yet
    /// entered the serialized state queue. Production never assigns this closure.
    var terminationObservationHookForTesting: (() -> Void)? {
        get { callbackLock.withLock { terminationObservationHook } }
        set { callbackLock.withLock { terminationObservationHook = newValue } }
    }

    private let ioQueue = DispatchQueue(label: "dev.pi.desktop.rpc", qos: .userInitiated)
    /// Blocking pipe reads live off the command/state queue. Unlike FileHandle readability
    /// handlers, these do not depend on a GUI app run loop and consume no CPU while idle.
    private let outputQueue = DispatchQueue(label: "dev.pi.desktop.rpc.stdout", qos: .userInitiated, attributes: .concurrent)
    private let errorQueue = DispatchQueue(label: "dev.pi.desktop.rpc.stderr", qos: .utility, attributes: .concurrent)
    private let runningLock = NSLock()
    private var runningGeneration: RuntimeGeneration?
    private var process: Process?
    private var inputHandle: FileHandle?
    private var inputWriter: RuntimeInputWriter?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var framer = JSONLFramer()
    private let pending = RPCPendingRegistry()
    private let eventMailbox = RuntimeEventMailbox()
    private var requestCounter = 0
    private var stderr = ""
    private var generationSequence = 0
    private var generation = RuntimeGeneration(sequence: 0)
    private let executableOverride: URL?
    private let environmentOverrides: [String: String]
    private let additionalArguments: [String]
    /// Test seam: replaces the adapter's argument list entirely.
    private let argumentsOverride: [String]?
    private let adapter: AgentProtocolAdapter

    public var agent: AgentKind { adapter.agent }

    public init(
        adapter: AgentProtocolAdapter = PiProtocolAdapter(),
        executableOverride: URL? = nil,
        environmentOverrides: [String: String] = [:],
        additionalArguments: [String] = [],
        argumentsOverride: [String]? = nil
    ) {
        self.adapter = adapter
        self.executableOverride = executableOverride
        self.environmentOverrides = environmentOverrides
        self.additionalArguments = additionalArguments
        self.argumentsOverride = argumentsOverride
    }

    /// Builds the runtime for one agent, with that agent's native protocol adapter.
    public static func make(for agent: AgentKind, additionalArguments: [String] = []) -> AgentRuntimeClient {
        AgentRuntimeClient(adapter: AgentAdapterFactory.make(agent), additionalArguments: additionalArguments)
    }

    public var isRunning: Bool {
        runningLock.withLock { runningGeneration?.isValid == true }
    }

    var pendingRequestCount: Int { ioQueue.sync { pending.count } }

    private func setRunningGeneration(_ generation: RuntimeGeneration?) {
        runningLock.withLock { runningGeneration = generation }
    }

    private func clearRunningGeneration(_ retired: RuntimeGeneration) {
        runningLock.withLock {
            if runningGeneration === retired { runningGeneration = nil }
        }
    }

    public func configureLaunch(modelID: String?, thinkingLevel: String?) {
        ioQueue.sync { adapter.configureLaunch(modelID: modelID, thinkingLevel: thinkingLevel) }
    }

    public func configureFastMode(_ enabled: Bool) {
        ioQueue.sync { adapter.configureFastMode(enabled) }
    }

    public func start(cwd: URL, sessionPath: URL? = nil) throws {
        let baseEnvironment = ProcessInfo.processInfo.environment
            .merging(adapter.environmentOverrides) { _, override in override }
            .merging(environmentOverrides) { _, override in override }
        guard let executableURL = executableOverride
            ?? AgentCatalog.executable(for: adapter.agent, environment: baseEnvironment) else {
            throw AgentRuntimeError.notInstalled(adapter.agent)
        }

        try ioQueue.sync {
            if process?.isRunning == true { return }

            // A very short-lived process can be dead before its termination callback reaches
            // this serial queue. Retire that generation before replacing its handles, so every
            // callback completes now instead of waiting for its normal timeout.
            if process != nil {
                let retiredGeneration = generation
                retiredGeneration.invalidate()
                clearRunningGeneration(retiredGeneration)
                rejectPending(processExitMessage: "\(adapter.agent.displayName) exited before it was restarted.")
                adapter.reset()
                cleanupHandles()
                self.process = nil
            }

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            generation.invalidate()
            generationSequence += 1
            let currentGeneration = RuntimeGeneration(sequence: generationSequence)
            generation = currentGeneration
            requestCounter = 0
            stderr = ""
            framer = JSONLFramer()
            eventMailbox.reset()
            adapter.reset()

            process.executableURL = executableURL
            var arguments = argumentsOverride ?? adapter.launchArguments(sessionPath: sessionPath, cwd: cwd)
            arguments += additionalArguments
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.environment = AgentCatalog.augmentedEnvironment(
                executable: executableURL, cwd: cwd, base: baseEnvironment
            )
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            inputHandle = input.fileHandleForWriting
            outputHandle = output.fileHandleForReading
            errorHandle = error.fileHandleForReading
            self.process = process
            let writer = try RuntimeInputWriter(handle: input.fileHandleForWriting, generation: currentGeneration)
            inputWriter = writer

            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                let exitTarget = self.currentExitTarget()
                self.currentTerminationObservationHook()?()
                self.ioQueue.async { [weak self] in
                    guard let self, self.generation === currentGeneration, currentGeneration.isValid else { return }
                    let detail = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = self.adapter.agent.displayName
                    let message = process.terminationStatus == 0
                        ? nil
                        : "\(name) exited with status \(process.terminationStatus).\(detail.isEmpty ? "" : " \(detail)")"
                    currentGeneration.invalidate()
                    self.clearRunningGeneration(currentGeneration)
                    self.rejectPending(processExitMessage: message ?? "\(name) exited.")
                    self.eventMailbox.reset()
                    self.cleanupHandles()
                    self.process = nil
                    DispatchQueue.main.async { exitTarget.handler?(message) }
                }
            }

            do {
                try process.run()
            } catch {
                currentGeneration.invalidate()
                clearRunningGeneration(currentGeneration)
                inputWriter = nil
                cleanupHandles()
                self.process = nil
                throw error
            }
            setRunningGeneration(currentGeneration)
            startOutputReader(output.fileHandleForReading, generation: currentGeneration)
            startErrorReader(error.fileHandleForReading, generation: currentGeneration)

            // The handshake has to be on the wire before any user command, and the adapter is
            // the only thing that knows whether this agent needs one.
            enqueueInput(
                adapter.startupLines(sessionPath: sessionPath, cwd: cwd),
                writer: writer,
                generation: currentGeneration
            )
        }
    }

    public func stop() {
        setRunningGeneration(nil)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let retiredGeneration = generation
            generation.invalidate()
            generationSequence += 1
            generation = RuntimeGeneration(sequence: generationSequence)
            clearRunningGeneration(retiredGeneration)
            rejectPending(processExitMessage: "\(adapter.agent.displayName) was stopped.")
            eventMailbox.reset()
            adapter.reset()
            // Keep retired read descriptors alive until their process closes them. Closing and
            // immediately spawning can reuse the same descriptor, letting the old blocking read
            // consume the replacement runtime's first response.
            try? inputHandle?.close()
            inputHandle = nil
            inputWriter = nil
            let retiredOutput = outputHandle
            let retiredError = errorHandle
            outputHandle = nil
            errorHandle = nil
            let dying = process
            process = nil
            // SIGTERM is delivered here (off main, before any replacement is spawned);
            // waiting and SIGKILL escalation continue on the reaper queue. Retired descriptors
            // close after reaping, so inherited child-process pipes cannot strand reader threads.
            if let dying {
                PiProcessReaper.reap(dying) {
                    try? retiredOutput?.close()
                    try? retiredError?.close()
                }
            } else {
                try? retiredOutput?.close()
                try? retiredError?.close()
            }
        }
    }

    public func send(
        type: String,
        payload: [String: PiJSONValue] = [:],
        completion: ((Result<PiJSONValue, Error>) -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self, let writer = inputWriter, process?.isRunning == true else {
                DispatchQueue.main.async { completion?(.failure(AgentRuntimeError.notRunning)) }
                return
            }

            if completion != nil, !pending.hasCapacity {
                let error = AgentRuntimeError.overloaded(
                    "Too many agent requests are already waiting. Wait for them to finish and try again."
                )
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }

            requestCounter += 1
            let currentGeneration = generation
            let id = "desktop-\(currentGeneration.sequence)-\(requestCounter)"

            switch adapter.encode(command: type, id: id, payload: payload) {
            case let .immediate(value):
                // Answered from the adapter's own state; nothing reaches the process.
                if let completion {
                    RuntimeCompletionDelivery.enqueue(
                        .success(AdapterEncoding.response(id: id, data: value)),
                        command: type, generation: currentGeneration, agent: adapter.agent,
                        callback: completion
                    )
                }
                return
            case let .immediateWithEvents(value, events):
                if let completion {
                    RuntimeCompletionDelivery.enqueue(
                        .success(AdapterEncoding.response(id: id, data: value)),
                        command: type, generation: currentGeneration, agent: adapter.agent,
                        events: events, eventHandler: onEvent, callback: completion
                    )
                } else {
                    let eventHandler = onEvent
                    DispatchQueue.main.async {
                        guard currentGeneration.isValid else { return }
                        for event in events { eventHandler?(event) }
                    }
                }
                return
            case let .unsupported(what):
                let error = AgentRuntimeError.unsupported(adapter.agent, what)
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            case .deferred:
                // The adapter is holding this until a handshake completes and will write it
                // itself; only the completion is registered here.
                if let completion {
                    pending.register(id: id, command: type, generation: currentGeneration, callback: completion)
                }
            case let .write(lines):
                guard !lines.isEmpty else {
                    DispatchQueue.main.async { completion?(.failure(AgentRuntimeError.invalidCommand)) }
                    return
                }
                guard enqueueInput(lines, writer: writer, generation: currentGeneration) else {
                    adapter.rollbackRejectedEncoding(command: type, id: id, payload: payload)
                    let error = AgentRuntimeError.overloaded(
                        "The agent input queue is full. Wait for the current requests to finish and try again."
                    )
                    if let completion { DispatchQueue.main.async { completion(.failure(error)) } }
                    else { handleInputFailure(error, generation: currentGeneration) }
                    return
                }
                if let completion {
                    pending.register(id: id, command: type, generation: currentGeneration, callback: completion)
                }
            }

            guard completion != nil else { return }
            let timeoutError = RPCTimeoutPolicy.error(for: type)
            ioQueue.asyncAfter(deadline: .now() + RPCTimeoutPolicy.delay(for: type)) { [weak self] in
                guard let self,
                      let callback = pending.takeForTimeout(id: id, generation: currentGeneration) else { return }
                RuntimeCompletionDelivery.enqueue(
                    .failure(timeoutError), command: type, generation: currentGeneration,
                    agent: adapter.agent, callback: callback
                )
            }
        }
    }

    public func sendUncorrelated(_ value: PiJSONValue) {
        ioQueue.async { [weak self] in
            guard let self, let writer = inputWriter, process?.isRunning == true else { return }
            let currentGeneration = generation
            let lines = adapter.encodeUncorrelated(value)
            // An adapter may intentionally collect several dialog answers before it can emit
            // one native response. A stale answer is likewise safe to ignore.
            guard !lines.isEmpty else { return }
            guard enqueueInput(lines, writer: writer, generation: currentGeneration) else {
                handleInputFailure(RuntimeInputWriterError.backpressured, generation: currentGeneration)
                return
            }
        }
    }

    private func startOutputReader(_ handle: FileHandle, generation currentGeneration: RuntimeGeneration) {
        let pendingChunkSlots = DispatchSemaphore(value: 8)
        outputQueue.async { [weak self] in
            defer { try? handle.close() }
            while currentGeneration.isValid {
                guard let data = Self.blockingRead(from: handle.fileDescriptor, maximumBytes: 64 * 1024) else { return }
                while currentGeneration.isValid,
                      pendingChunkSlots.wait(timeout: .now() + 0.1) == .timedOut {}
                guard currentGeneration.isValid else { return }
                let eventTarget = self?.currentEventTarget()
                self?.ioQueue.async { [weak self] in
                    defer { pendingChunkSlots.signal() }
                    self?.consume(data, generation: currentGeneration, eventTarget: eventTarget)
                }
            }
        }
    }

    private func currentEventTarget() -> RuntimeEventTarget {
        callbackLock.withLock {
            RuntimeEventTarget(revision: eventHandlerRevision, handler: eventHandler)
        }
    }

    private func currentExitTarget() -> RuntimeExitTarget {
        callbackLock.withLock { RuntimeExitTarget(handler: exitHandler) }
    }

    private func currentTerminationObservationHook() -> (() -> Void)? {
        callbackLock.withLock { terminationObservationHook }
    }

    private func startErrorReader(_ handle: FileHandle, generation currentGeneration: RuntimeGeneration) {
        errorQueue.async { [weak self] in
            defer { try? handle.close() }
            while currentGeneration.isValid {
                guard let data = Self.blockingRead(from: handle.fileDescriptor, maximumBytes: 16 * 1024) else { return }
                self?.ioQueue.async { [weak self] in
                    guard let self, currentGeneration.isValid, generation === currentGeneration else { return }
                    stderr.append(String(decoding: data, as: UTF8.self))
                    if stderr.count > 65_536 {
                        stderr.removeFirst(stderr.count - 65_536)
                    }
                }
            }
        }
    }

    /// `FileHandle.read(upToCount:)` may return immediately with no bytes for a pipe. POSIX read
    /// has the semantics this transport needs: block the dedicated reader thread until data,
    /// EOF, or handle closure, retrying only an interrupted system call.
    private static func blockingRead(from descriptor: Int32, maximumBytes: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, maximumBytes)
            }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    private func consume(
        _ data: Data,
        generation currentGeneration: RuntimeGeneration,
        eventTarget: RuntimeEventTarget?
    ) {
        // A retired generation's buffered output is dropped rather than published.
        guard currentGeneration.isValid, generation === currentGeneration else { return }
        let records = framer.append(data)
        if framer.takeOverflowedRecordCount() > 0 {
            retireRuntime(
                message: "\(adapter.agent.displayName) output contained an oversized protocol record.",
                generation: currentGeneration
            )
            return
        }
        for record in records {
            // An adapter may need to write back while decoding (protocol acknowledgements,
            // deferred commands unblocked by a handshake completing).
            let messages = adapter.decode(line: record)
            let eventCount = messages.reduce(into: 0) { count, message in
                if case .event = message { count += 1 }
            }
            let sourceBytesPerEvent = eventCount > 0 ? record.count / eventCount : 0
            var remainingSourceBytes = eventCount > 0 ? record.count % eventCount : 0
            for message in messages {
                switch message {
                case let .response(id, value):
                    // An unmatched or superseded response is dropped, never re-published as an event.
                    guard let delivery = pending.takeForDelivery(id: id, currentGeneration: currentGeneration)
                    else { continue }
                    RuntimeCompletionDelivery.enqueue(
                        .success(value), command: delivery.command,
                        generation: currentGeneration, agent: adapter.agent, callback: delivery.callback
                    )
                case let .event(value):
                    // One protocol record can expand into many semantic events. Attribute the
                    // record bytes across those events once, rather than charging its full size
                    // to each event and falsely tripping mailbox backpressure.
                    let sourceBytes = sourceBytesPerEvent + (remainingSourceBytes > 0 ? 1 : 0)
                    remainingSourceBytes = max(0, remainingSourceBytes - 1)
                    // The reader captured the owner with this byte chunk. Rebinding during a
                    // same-process session transition cannot redirect buffered bytes to the new route.
                    if let eventTarget,
                       !eventMailbox.enqueue(
                           value,
                           sourceBytes: sourceBytes,
                           generation: currentGeneration,
                           target: eventTarget
                       ) {
                        retireRuntime(
                            message: "\(adapter.agent.displayName) produced events faster than the app could present them.",
                            generation: currentGeneration
                        )
                        return
                    }
                }
            }
            if let outbound = (adapter as? AdapterWriteback)?.drainPendingWrites(), !outbound.isEmpty {
                guard let writer = inputWriter else { continue }
                guard enqueueInput(outbound, writer: writer, generation: currentGeneration) else {
                    handleInputFailure(RuntimeInputWriterError.backpressured, generation: currentGeneration)
                    return
                }
            }
        }
    }

    @discardableResult
    private func enqueueInput(
        _ lines: [Data],
        writer: RuntimeInputWriter,
        generation currentGeneration: RuntimeGeneration
    ) -> Bool {
        guard !lines.isEmpty else { return true }
        return writer.enqueue(lines) { [weak self] result in
            guard case let .failure(error) = result else { return }
            guard let self else { return }
            let exitTarget = self.currentExitTarget()
            self.ioQueue.async { [weak self] in
                self?.handleInputFailure(
                    error, generation: currentGeneration, exitTarget: exitTarget
                )
            }
        }
    }

    private func handleInputFailure(
        _ error: Error,
        generation currentGeneration: RuntimeGeneration,
        exitTarget: RuntimeExitTarget? = nil
    ) {
        guard generation === currentGeneration, currentGeneration.isValid else { return }
        let name = adapter.agent.displayName
        retireRuntime(
            message: "\(name) input failed. \(error.localizedDescription)",
            generation: currentGeneration,
            exitTarget: exitTarget
        )
    }

    private func retireRuntime(
        message: String,
        generation currentGeneration: RuntimeGeneration,
        exitTarget capturedExitTarget: RuntimeExitTarget? = nil
    ) {
        guard generation === currentGeneration, currentGeneration.isValid else { return }
        let exitTarget = capturedExitTarget ?? currentExitTarget()
        currentGeneration.invalidate()
        clearRunningGeneration(currentGeneration)
        rejectPending(processExitMessage: message)
        eventMailbox.reset()
        adapter.reset()
        try? inputHandle?.close()
        inputHandle = nil
        inputWriter = nil
        let retiredOutput = outputHandle
        let retiredError = errorHandle
        outputHandle = nil
        errorHandle = nil
        let dying = process
        process = nil
        if let dying {
            PiProcessReaper.reap(dying) {
                try? retiredOutput?.close()
                try? retiredError?.close()
            }
        } else {
            try? retiredOutput?.close()
            try? retiredError?.close()
        }
        DispatchQueue.main.async { exitTarget.handler?(message) }
    }

    /// Terminal rejections are always delivered so every caller completes exactly once, even
    /// when its generation has just been retired. A command that may already have taken effect
    /// is reported as outcome-unknown rather than a definite failure — exactly like its RPC
    /// timeout counterpart (`RPCTimeoutPolicy`) — because the process is gone but the agent may
    /// have durably accepted the command before it died. Only the read-only state queries, which
    /// have no side effect to protect, are reported as a definite failure.
    private func rejectPending(processExitMessage: String) {
        for (command, callback) in pending.drainAll() {
            let error: Error = RPCTimeoutPolicy.stateQueries.contains(command)
                ? AgentRuntimeError.processExited(processExitMessage)
                : AgentRuntimeError.outcomeUnknown(command)
            DispatchQueue.main.async { callback(.failure(error)) }
        }
    }

    private func cleanupHandles() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputWriter = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
    }

    deinit {
        generation.invalidate()
        rejectPending(processExitMessage: "\(adapter.agent.displayName) runtime was released.")
        try? inputHandle?.close()
        inputWriter = nil
        let retiredOutput = outputHandle
        let retiredError = errorHandle
        if let process, process.isRunning {
            PiProcessReaper.reap(process) {
                try? retiredOutput?.close()
                try? retiredError?.close()
            }
        } else {
            try? retiredOutput?.close()
            try? retiredError?.close()
        }
    }
}

/// An adapter that sometimes has to answer the agent (protocol acknowledgements, permission
/// replies) as a consequence of decoding, rather than because the app asked for something.
public protocol AdapterWriteback: AnyObject {
    /// Lines the adapter accumulated while decoding. Called on the IO queue after each record.
    func drainPendingWrites() -> [Data]
}
