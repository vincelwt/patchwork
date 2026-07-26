import Darwin
import Foundation
import PiDeskKit

/// A minimal, sequential Pi RPC client for the runner: start the process, send one command at a
/// time, wait for its response, and separately drain events until `agent_settled`. Deliberately
/// not a port of the app's `PiRPCClient` (`Sources/PiDesktop/PiRPCClient.swift`): that client
/// supports concurrent in-flight commands and live UI callbacks, neither of which the runner
/// needs \u2014 it drives exactly one prompt per run, strictly in order.
final class PiRPCSession: @unchecked Sendable {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputFD: Int32
    private let errorHandle: FileHandle
    private let ioQueue = DispatchQueue(label: "dev.pi.desktop.daemon.runner.io")
    private var framer = JSONLFramer()
    private let bufferLock = NSLock()
    private var buffer: [PiJSONValue] = []
    private var requestCounter = 0
    private let stderrLock = NSLock()
    private var stderrTail = ""

    var isRunning: Bool { process.isRunning }

    private init(process: Process, inputHandle: FileHandle, outputFD: Int32, errorHandle: FileHandle) {
        self.process = process
        self.inputHandle = inputHandle
        self.outputFD = outputFD
        self.errorHandle = errorHandle
        watchStderr()
    }

    static func start(cwd: URL, sessionPath: URL?, piExecutable: URL, environment: [String: String]) throws -> PiRPCSession {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = piExecutable
        var arguments = ["--mode", "rpc"]
        if let sessionPath { arguments += ["--session", sessionPath.path] }
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return PiRPCSession(process: process, inputHandle: input.fileHandleForWriting, outputFD: output.fileHandleForReading.fileDescriptor, errorHandle: error.fileHandleForReading)
    }

    /// Writes a correlated request and returns its id; the caller awaits the matching response
    /// separately via `receiveMatching`.
    @discardableResult
    func send(type: String, payload: [String: PiJSONValue] = [:]) throws -> String {
        requestCounter += 1
        let id = "daemon-\(process.processIdentifier)-\(requestCounter)"
        var object = payload
        object["type"] = .string(type)
        object["id"] = .string(id)
        do {
            try BlockingPipeIO.writeAll(fd: inputHandle.fileDescriptor, data: try PiJSONValue.object(object).encodedLine())
        } catch let error as RunnerError {
            throw error
        } catch {
            throw RunnerError.ioFailure("Could not write to Pi: \(error)")
        }
        return id
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
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RunnerError.timedOut(afterSeconds: timeout) }
            guard let value = try await receiveNext(timeout: min(remaining, 5)) else { continue }
            if value["type"]?.stringValue == "response", value["id"]?.stringValue == id { return value }
            pushBackBuffered(value)
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

    private func pushBackBuffered(_ value: PiJSONValue) {
        bufferLock.lock(); buffer.append(value); bufferLock.unlock()
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
                let values = records.compactMap { try? PiJSONValue.decode($0) }
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
