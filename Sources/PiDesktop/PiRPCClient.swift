import Darwin
import Foundation

protocol PiRuntimeProtocol: AnyObject {
    var onEvent: ((JSONValue) -> Void)? { get set }
    var onExit: ((String?) -> Void)? { get set }
    var isRunning: Bool { get }

    func start(cwd: URL, sessionPath: URL?) throws
    func stop()
    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?)
    func sendUncorrelated(_ value: JSONValue)
}

enum PiRPCError: LocalizedError {
    case piNotFound
    case notRunning
    case invalidCommand
    /// Pi did not answer a side-effect-free query in time; safe to treat as a failure.
    case timedOut(String, seconds: TimeInterval)
    /// Pi did not confirm a command that may already have been applied. Callers must not
    /// roll back drafts or resubmit on this error.
    case outcomeUnknown(String)
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case .piNotFound:
            "Pi CLI was not found. Set PI_DESKTOP_PI_PATH or install pi in ~/.local/bin."
        case .notRunning:
            "Pi is not running."
        case .invalidCommand:
            "Could not encode an RPC command."
        case let .timedOut(command, seconds):
            "Pi did not respond to \(command) within \(Int(seconds)) seconds."
        case let .outcomeUnknown(command):
            "Pi never confirmed \(command). It may already have been applied, so nothing was undone."
        case let .processExited(message):
            message
        }
    }
}

enum PiLocator {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let manager = FileManager.default
        var candidates: [String] = []
        if let override = environment["PI_DESKTOP_PI_PATH"], !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        let home = manager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "/usr/bin/pi"
        ])
        return candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { manager.isExecutableFile(atPath: $0.path) }
    }

    static func augmentedEnvironment(
        piURL: URL,
        cwd: URL? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            piURL.deletingLastPathComponent().path,
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = Array(NSOrderedSet(array: additions + existing)).compactMap { $0 as? String }.joined(separator: ":")
        // LaunchServices normally gives GUI apps PWD="/". Process.currentDirectoryURL changes
        // the actual cwd but not this environment value, and Pi extensions commonly consult PWD
        // for project discovery. Keep both views of the working directory identical.
        if let cwd { environment["PWD"] = cwd.standardizedFileURL.path }
        return environment
    }
}

final class PiRPCClient: PiRuntimeProtocol {
    private let callbackLock = NSLock()
    private var eventHandler: ((JSONValue) -> Void)?
    private var exitHandler: ((String?) -> Void)?
    var onEvent: ((JSONValue) -> Void)? {
        get { callbackLock.withLock { eventHandler } }
        set { callbackLock.withLock { eventHandler = newValue } }
    }
    var onExit: ((String?) -> Void)? {
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
    /// Test seam: replaces the standard `--mode rpc` argument list entirely.
    private let argumentsOverride: [String]?

    init(
        executableOverride: URL? = nil,
        environmentOverrides: [String: String] = [:],
        additionalArguments: [String] = [],
        argumentsOverride: [String]? = nil
    ) {
        self.executableOverride = executableOverride
        self.environmentOverrides = environmentOverrides
        self.additionalArguments = additionalArguments
        self.argumentsOverride = argumentsOverride
    }

    var isRunning: Bool {
        ioQueue.sync { process?.isRunning == true }
    }

    func start(cwd: URL, sessionPath: URL? = nil) throws {
        let baseEnvironment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, override in override }
        guard let piURL = executableOverride ?? PiLocator.resolve(environment: baseEnvironment) else {
            throw PiRPCError.piNotFound
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

            process.executableURL = piURL
            var arguments = argumentsOverride ?? ["--mode", "rpc"]
            if argumentsOverride == nil, let sessionPath {
                arguments += ["--session", sessionPath.path]
            }
            arguments += additionalArguments
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.environment = PiLocator.augmentedEnvironment(piURL: piURL, cwd: cwd, base: baseEnvironment)
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
                    let message = process.terminationStatus == 0
                        ? nil
                        : "Pi exited with status \(process.terminationStatus).\(detail.isEmpty ? "" : " \(detail)")"
                    currentGeneration.invalidate()
                    self.rejectPending(processExitMessage: message ?? "Pi exited.")
                    self.cleanupHandles()
                    self.process = nil
                    DispatchQueue.main.async { [weak self] in self?.onExit?(message) }
                }
            }

            try process.run()
            startOutputReader(output.fileHandleForReading, generation: currentGeneration)
            startErrorReader(error.fileHandleForReading, generation: currentGeneration)
        }
    }

    func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            generation.invalidate()
            generationSequence += 1
            generation = RuntimeGeneration(sequence: generationSequence)
            rejectPending(processExitMessage: "Pi was stopped.")
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

    func send(
        type: String,
        payload: [String: JSONValue] = [:],
        completion: ((Result<JSONValue, Error>) -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self, let inputHandle, process?.isRunning == true else {
                DispatchQueue.main.async { completion?(.failure(PiRPCError.notRunning)) }
                return
            }

            requestCounter += 1
            let currentGeneration = generation
            let id = "desktop-\(currentGeneration.sequence)-\(requestCounter)"
            var object = payload
            object["type"] = .string(type)
            object["id"] = .string(id)

            if let completion {
                pending.register(id: id, command: type, generation: currentGeneration, callback: completion)
            }
            do {
                try inputHandle.write(contentsOf: try JSONValue.object(object).encodedLine())
            } catch {
                let callback = pending.remove(id: id) ?? completion
                DispatchQueue.main.async { callback?(.failure(error)) }
                return
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

    func sendUncorrelated(_ value: JSONValue) {
        ioQueue.async { [weak self] in
            guard let input = self?.inputHandle, self?.process?.isRunning == true else { return }
            try? input.write(contentsOf: value.encodedLine())
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
        eventHandler: ((JSONValue) -> Void)?
    ) {
        // A retired generation's buffered output is dropped rather than published.
        guard currentGeneration.isValid, generation === currentGeneration else { return }
        for record in framer.append(data) {
            guard let value = try? JSONValue.decode(record) else { continue }
            if value["type"]?.stringValue == "response" {
                // An unmatched or superseded response is dropped, never re-published as an event.
                guard let id = value["id"]?.stringValue,
                      let callback = pending.takeForDelivery(id: id, currentGeneration: currentGeneration)
                else { continue }
                DispatchQueue.main.async {
                    // Re-checked on main: a stop between queueing and execution must not publish.
                    guard currentGeneration.isValid else { return }
                    callback(.success(value))
                }
            } else {
                // The reader captured the owner with this byte chunk. Rebinding during a
                // same-process session transition cannot redirect buffered bytes to the new route.
                DispatchQueue.main.async {
                    guard currentGeneration.isValid else { return }
                    eventHandler?(value)
                }
            }
        }
    }

    /// Terminal rejections are always delivered so every caller completes exactly once, even
    /// when its generation has just been retired. A command that may already have taken effect
    /// is reported as outcome-unknown rather than a definite failure — exactly like its RPC
    /// timeout counterpart (`RPCTimeoutPolicy`) — because the process is gone but Pi may have
    /// durably accepted the command before it died. Only the read-only state queries, which
    /// have no side effect to protect, are reported as a definite failure.
    private func rejectPending(processExitMessage: String) {
        for (command, callback) in pending.drainAll() {
            let error: Error = RPCTimeoutPolicy.stateQueries.contains(command)
                ? PiRPCError.processExited(processExitMessage)
                : PiRPCError.outcomeUnknown(command)
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
