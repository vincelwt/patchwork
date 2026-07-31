import Darwin
import Foundation

public protocol AgentRuntimeProtocol: AnyObject {
    var onEvent: ((PiJSONValue) -> Void)? { get set }
    var onExit: ((String?) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Which agent this runtime drives. The store gates affordances on its capabilities.
    var agent: AgentKind { get }

    func start(cwd: URL, sessionPath: URL?) throws
    func stop()
    func send(type: String, payload: [String: PiJSONValue], completion: ((Result<PiJSONValue, Error>) -> Void)?)
    func sendUncorrelated(_ value: PiJSONValue)
}

public extension AgentRuntimeProtocol {
    var agent: AgentKind { .pi }
}

public enum AgentRuntimeError: LocalizedError {
    case notInstalled(AgentKind)
    case notRunning
    case invalidCommand
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
public final class AgentRuntimeClient: AgentRuntimeProtocol {
    private let callbackLock = NSLock()
    private var eventHandler: ((PiJSONValue) -> Void)?
    private var exitHandler: ((String?) -> Void)?
    public var onEvent: ((PiJSONValue) -> Void)? {
        get { callbackLock.withLock { eventHandler } }
        set { callbackLock.withLock { eventHandler = newValue } }
    }
    public var onExit: ((String?) -> Void)? {
        get { callbackLock.withLock { exitHandler } }
        set { callbackLock.withLock { exitHandler = newValue } }
    }

    private let ioQueue = DispatchQueue(label: "dev.pi.desktop.rpc", qos: .userInitiated)
    /// Blocking pipe reads live off the command/state queue. Unlike FileHandle readability
    /// handlers, these do not depend on a GUI app run loop and consume no CPU while idle.
    private let outputQueue = DispatchQueue(label: "dev.pi.desktop.rpc.stdout", qos: .userInitiated, attributes: .concurrent)
    private let errorQueue = DispatchQueue(label: "dev.pi.desktop.rpc.stderr", qos: .utility, attributes: .concurrent)
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var framer = JSONLFramer()
    private let pending = RPCPendingRegistry()
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
        ioQueue.sync { process?.isRunning == true }
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

            process.terminationHandler = { [weak self] process in
                self?.ioQueue.async {
                    guard let self, self.generation === currentGeneration, currentGeneration.isValid else { return }
                    let detail = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = self.adapter.agent.displayName
                    let message = process.terminationStatus == 0
                        ? nil
                        : "\(name) exited with status \(process.terminationStatus).\(detail.isEmpty ? "" : " \(detail)")"
                    currentGeneration.invalidate()
                    self.rejectPending(processExitMessage: message ?? "\(name) exited.")
                    self.cleanupHandles()
                    self.process = nil
                    DispatchQueue.main.async { [weak self] in self?.onExit?(message) }
                }
            }

            try process.run()
            startOutputReader(output.fileHandleForReading, generation: currentGeneration)
            startErrorReader(error.fileHandleForReading, generation: currentGeneration)

            // The handshake has to be on the wire before any user command, and the adapter is
            // the only thing that knows whether this agent needs one.
            for line in adapter.startupLines(sessionPath: sessionPath, cwd: cwd) {
                try? inputHandle?.write(contentsOf: line)
            }
        }
    }

    public func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            generation.invalidate()
            generationSequence += 1
            generation = RuntimeGeneration(sequence: generationSequence)
            rejectPending(processExitMessage: "\(adapter.agent.displayName) was stopped.")
            adapter.reset()
            // Keep retired read descriptors alive until their process closes them. Closing and
            // immediately spawning can reuse the same descriptor, letting the old blocking read
            // consume the replacement runtime's first response.
            try? inputHandle?.close()
            inputHandle = nil
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
            guard let self, let inputHandle, process?.isRunning == true else {
                DispatchQueue.main.async { completion?(.failure(AgentRuntimeError.notRunning)) }
                return
            }

            requestCounter += 1
            let currentGeneration = generation
            let id = "desktop-\(currentGeneration.sequence)-\(requestCounter)"

            switch adapter.encode(command: type, id: id, payload: payload) {
            case let .immediate(value):
                // Answered from the adapter's own state; nothing reaches the process.
                DispatchQueue.main.async {
                    guard currentGeneration.isValid else { return }
                    completion?(.success(AdapterEncoding.response(id: id, data: value)))
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
                if let completion {
                    pending.register(id: id, command: type, generation: currentGeneration, callback: completion)
                }
                do {
                    for line in lines { try inputHandle.write(contentsOf: line) }
                } catch {
                    let callback = pending.remove(id: id) ?? completion
                    DispatchQueue.main.async { callback?(.failure(error)) }
                    return
                }
            }

            guard completion != nil else { return }
            let timeoutError = RPCTimeoutPolicy.error(for: type)
            ioQueue.asyncAfter(deadline: .now() + RPCTimeoutPolicy.delay(for: type)) { [weak self] in
                guard let self,
                      let callback = pending.takeForTimeout(id: id, generation: currentGeneration) else { return }
                DispatchQueue.main.async {
                    guard currentGeneration.isValid else { return }
                    callback(.failure(timeoutError))
                }
            }
        }
    }

    public func sendUncorrelated(_ value: PiJSONValue) {
        ioQueue.async { [weak self] in
            guard let self, let input = inputHandle, process?.isRunning == true else { return }
            for line in adapter.encodeUncorrelated(value) {
                try? input.write(contentsOf: line)
            }
        }
    }

    private func startOutputReader(_ handle: FileHandle, generation currentGeneration: RuntimeGeneration) {
        outputQueue.async { [weak self] in
            defer { try? handle.close() }
            while currentGeneration.isValid {
                guard let data = Self.blockingRead(from: handle.fileDescriptor, maximumBytes: 64 * 1024) else { return }
                let eventHandler = self?.onEvent
                self?.ioQueue.async { [weak self] in
                    self?.consume(data, generation: currentGeneration, eventHandler: eventHandler)
                }
            }
        }
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
        eventHandler: ((PiJSONValue) -> Void)?
    ) {
        // A retired generation's buffered output is dropped rather than published.
        guard currentGeneration.isValid, generation === currentGeneration else { return }
        for record in framer.append(data) {
            // An adapter may need to write back while decoding (protocol acknowledgements,
            // deferred commands unblocked by a handshake completing).
            for message in adapter.decode(line: record) {
                switch message {
                case let .response(id, value):
                    // An unmatched or superseded response is dropped, never re-published as an event.
                    guard let callback = pending.takeForDelivery(id: id, currentGeneration: currentGeneration)
                    else { continue }
                    DispatchQueue.main.async {
                        // Re-checked on main: a stop between queueing and execution must not publish.
                        guard currentGeneration.isValid else { return }
                        callback(.success(value))
                    }
                case let .event(value):
                    // The reader captured the owner with this byte chunk. Rebinding during a
                    // same-process session transition cannot redirect buffered bytes to the new route.
                    DispatchQueue.main.async {
                        guard currentGeneration.isValid else { return }
                        eventHandler?(value)
                    }
                }
            }
            if let outbound = (adapter as? AdapterWriteback)?.drainPendingWrites(), !outbound.isEmpty {
                for line in outbound { try? inputHandle?.write(contentsOf: line) }
            }
        }
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
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
    }

    deinit {
        generation.invalidate()
        if let process, process.isRunning { PiProcessReaper.reap(process) }
    }
}

/// An adapter that sometimes has to answer the agent (protocol acknowledgements, permission
/// replies) as a consequence of decoding, rather than because the app asked for something.
public protocol AdapterWriteback: AnyObject {
    /// Lines the adapter accumulated while decoding. Called on the IO queue after each record.
    func drainPendingWrites() -> [Data]
}
