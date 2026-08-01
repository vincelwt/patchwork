import Darwin
import Foundation
import PatchworkKit

/// Where to connect: the control socket (default) or the loopback TCP remote (`--url`).
/// `Foundation`/`URLSession` has no client API for Unix domain sockets on Darwin, so both paths
/// go through the same hand-rolled POSIX socket code below — see ControlPlane.swift for the plan
/// to delete all of this once `PatchworkKit.PatchworkClient` exists.
enum TransportTarget {
    case unixSocket(path: String)
    case tcp(host: String, port: UInt16)
}

private enum RawSocketError: Error {
    case connectionRefused
    case notFound
    case connectFailed(String)
    case ioFailed(String)
    case timedOut
}

/// One connected socket, plus blocking send/receive. Every call is made from inside a detached
/// Task by its callers, so blocking the calling thread here is fine — this process makes at most
/// one or two connections at a time.
private final class RawSocket {
    private var fd: Int32 = -1

    func connect(to target: TransportTarget, timeout: TimeInterval) throws {
        switch target {
        case let .unixSocket(path): try connectUnix(path: path, timeout: timeout)
        case let .tcp(host, port): try connectTCP(host: host, port: port, timeout: timeout)
        }
    }

    private func connectUnix(path: String, timeout: TimeInterval) throws {
        let newFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFd >= 0 else { throw RawSocketError.connectFailed(errnoMessage()) }
        do {
            try PatchworkKit.RawSocket.suppressBrokenPipeSignal(fd: newFd)
        } catch {
            Darwin.close(newFd)
            throw RawSocketError.connectFailed(error.localizedDescription)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(newFd)
            throw RawSocketError.connectFailed("socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: capacity) { charPtr in
                for (index, byte) in pathBytes.enumerated() { charPtr[index] = CChar(bitPattern: byte) }
                charPtr[pathBytes.count] = 0
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(newFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(newFd)
            if code == ECONNREFUSED { throw RawSocketError.connectionRefused }
            if code == ENOENT { throw RawSocketError.notFound }
            throw RawSocketError.connectFailed(String(cString: strerror(code)))
        }
        setTimeouts(newFd, timeout)
        fd = newFd
    }

    private func connectTCP(host: String, port: UInt16, timeout: TimeInterval) throws {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var resolved: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resolved)
        guard status == 0, let first = resolved else {
            throw RawSocketError.connectFailed("cannot resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(resolved) }

        var lastErrno: Int32 = ENOENT
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            let newFd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if newFd >= 0 {
                do {
                    try PatchworkKit.RawSocket.suppressBrokenPipeSignal(fd: newFd)
                } catch {
                    Darwin.close(newFd)
                    throw RawSocketError.connectFailed(error.localizedDescription)
                }
                if Darwin.connect(newFd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    setTimeouts(newFd, timeout)
                    fd = newFd
                    return
                }
                lastErrno = errno
                Darwin.close(newFd)
            } else {
                lastErrno = errno
            }
            candidate = info.pointee.ai_next
        }
        if lastErrno == ECONNREFUSED { throw RawSocketError.connectionRefused }
        throw RawSocketError.connectFailed(String(cString: strerror(lastErrno)))
    }

    private func errnoMessage() -> String { String(cString: strerror(errno)) }

    /// Re-applies read/write timeouts; used to raise them for the long-lived SSE connection after
    /// a short connect-phase timeout.
    func setTimeouts(_ seconds: TimeInterval) { setTimeouts(fd, seconds) }

    private func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        guard fd >= 0 else { return }
        let bounded: TimeInterval
        if seconds.isNaN || seconds <= 0 { bounded = 0 }
        else if !seconds.isFinite { bounded = TimeInterval(Int32.max) }
        else { bounded = min(seconds, TimeInterval(Int32.max)) }
        let wholeSeconds = Int(bounded)
        var tv = timeval(
            tv_sec: wholeSeconds,
            tv_usec: Int32((bounded - Double(wholeSeconds)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw RawSocketError.timedOut }
                    throw RawSocketError.ioFailed(errnoMessage())
                }
                if n == 0 { throw RawSocketError.ioFailed("connection closed while writing") }
                offset += n
            }
        }
    }

    /// One read() call; empty `Data` means EOF, never a sentinel for "nothing yet" (this socket
    /// always blocks, up to the configured timeout).
    func receiveChunk(maxLength: Int = 65_536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let n = buffer.withUnsafeMutableBytes { ptr in Darwin.read(fd, ptr.baseAddress, maxLength) }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw RawSocketError.timedOut }
            throw RawSocketError.ioFailed(errnoMessage())
        }
        return n == 0 ? Data() : Data(buffer[0..<n])
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}

struct RawHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

private func mapConnectError(_ error: Error) -> Error {
    switch error {
    case RawSocketError.connectionRefused: return ControlPlaneError.unreachable("connection refused")
    case RawSocketError.notFound: return ControlPlaneError.unreachable("socket not found")
    case let RawSocketError.connectFailed(reason): return ControlPlaneError.unreachable(reason)
    case RawSocketError.timedOut: return ControlPlaneError.unreachable("connect timed out")
    default: return ControlPlaneError.transportFailure("\(error)")
    }
}

private func mapIOError(_ error: Error) -> Error {
    if let error = error as? ControlPlaneError { return error }
    switch error {
    case RawSocketError.timedOut: return ControlPlaneError.timedOut("the daemon stopped responding")
    case let RawSocketError.ioFailed(reason): return ControlPlaneError.transportFailure(reason)
    default: return ControlPlaneError.transportFailure("\(error)")
    }
}

/// Minimal blocking HTTP/1.1 client: request framing, status/header parsing, and
/// Content-Length/chunked/EOF-terminated body reads, all bounded by `maxResponseBytes` so a
/// pathological response can't exhaust memory. Good enough for small JSON request/response
/// bodies and for the `/v1/events` line stream; not a general-purpose HTTP client.
final class RawHTTPClient: @unchecked Sendable {
    private let target: TransportTarget
    private let timeout: TimeInterval
    private let maxResponseBytes: Int

    init(target: TransportTarget, timeout: TimeInterval, maxResponseBytes: Int = 32 * 1024 * 1024) {
        self.target = target
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
    }

    private func hostHeader() -> String {
        switch target {
        case .unixSocket: return "localhost"
        case let .tcp(host, port): return "\(host):\(port)"
        }
    }

    func perform(method: String, path: String, headers: [String: String], body: Data?) async throws -> RawHTTPResponse {
        let target = target
        let timeout = timeout
        let maxResponseBytes = maxResponseBytes
        let hostHeader = hostHeader()
        return try await Task.detached(priority: .userInitiated) {
            let socket = RawSocket()
            do {
                try socket.connect(to: target, timeout: timeout)
            } catch { throw mapConnectError(error) }
            defer { socket.close() }

            var requestHeaders = headers
            requestHeaders["Host"] = hostHeader
            requestHeaders["Connection"] = "close"
            if let body { requestHeaders["Content-Length"] = "\(body.count)" }
            var payload = Data(Self.requestLine(method: method, path: path, headers: requestHeaders).utf8)
            if let body { payload.append(body) }

            do {
                try socket.sendAll(payload)
                let (status, respHeaders, leftover) = try Self.readStatusAndHeaders(socket: socket, maxBytes: 65_536)
                let responseBody = try Self.readBody(socket: socket, headers: respHeaders, leftover: leftover, maxBytes: maxResponseBytes)
                return RawHTTPResponse(status: status, headers: respHeaders, body: responseBody)
            } catch { throw mapIOError(error) }
        }.value
    }

    /// Streams `/v1/events` as raw lines (SSE framing happens one layer up, in SSEParser). Ends
    /// the `AsyncThrowingStream` on EOF, on a read timeout, or when the consumer cancels.
    func streamLines(path: String, headers: [String: String]) -> AsyncThrowingStream<String, Error> {
        let target = target
        let hostHeader = hostHeader()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let socket = RawSocket()
                do {
                    try socket.connect(to: target, timeout: 10)
                } catch {
                    continuation.finish(throwing: mapConnectError(error))
                    return
                }
                defer { socket.close() }
                socket.setTimeouts(45) // survive the doc's 20s keep-alive comments

                var requestHeaders = headers
                requestHeaders["Host"] = hostHeader
                requestHeaders["Accept"] = "text/event-stream"
                var buffer: Data
                do {
                    try socket.sendAll(Data(Self.requestLine(method: "GET", path: path, headers: requestHeaders).utf8))
                    let (status, respHeaders, leftover) = try Self.readStatusAndHeaders(socket: socket, maxBytes: 65_536)
                    guard (200..<300).contains(status) else {
                        let errorBody = try Self.readBody(socket: socket, headers: respHeaders, leftover: leftover, maxBytes: 65_536)
                        throw Self.apiError(status: status, body: errorBody)
                    }
                    buffer = leftover
                } catch {
                    continuation.finish(throwing: error is ControlPlaneError ? error : mapIOError(error))
                    return
                }

                let maxLineBytes = 1_000_000
                while !Task.isCancelled {
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        var line = String(decoding: buffer[..<newlineRange.lowerBound], as: UTF8.self)
                        if line.hasSuffix("\r") { line.removeLast() }
                        buffer.removeSubrange(..<newlineRange.upperBound)
                        switch continuation.yield(line) {
                        case .enqueued:
                            break
                        case .dropped:
                            continuation.finish(throwing: ControlPlaneError.transportFailure(
                                "event consumer fell behind"
                            ))
                            return
                        case .terminated:
                            return
                        @unknown default:
                            return
                        }
                    }
                    if buffer.count >= maxLineBytes {
                        continuation.finish(throwing: ControlPlaneError.transportFailure("event line exceeded \(maxLineBytes) bytes"))
                        return
                    }
                    do {
                        let chunk = try socket.receiveChunk()
                        if chunk.isEmpty {
                            continuation.finish(throwing: ControlPlaneError.transportFailure(
                                "event stream connection closed"
                            ))
                            return
                        }
                        buffer.append(chunk)
                    } catch {
                        continuation.finish(throwing: mapIOError(error))
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func requestLine(method: String, path: String, headers: [String: String]) -> String {
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        return "\(method) \(path) HTTP/1.1\r\n\(headerLines)\r\n\r\n"
    }

    /// Reads until the blank line that ends the header block, then returns the parsed status,
    /// headers (lower-cased keys), and any body bytes already read past the header boundary.
    private static func readStatusAndHeaders(socket: RawSocket, maxBytes: Int) throws -> (Int, [String: String], Data) {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: separator) {
                let headerText = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let leftover = Data(buffer[range.upperBound...])
                let lines = headerText.components(separatedBy: "\r\n")
                guard let statusLine = lines.first else { throw ControlPlaneError.malformedResponse("empty status line") }
                let parts = statusLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2, let status = Int(parts[1]) else {
                    throw ControlPlaneError.malformedResponse("malformed status line: \(statusLine)")
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
                return (status, headers, leftover)
            }
            guard buffer.count < maxBytes else { throw ControlPlaneError.malformedResponse("headers too large") }
            let chunk = try socket.receiveChunk()
            guard !chunk.isEmpty else { throw ControlPlaneError.malformedResponse("connection closed before headers completed") }
            buffer.append(chunk)
        }
    }

    private static func readBody(socket: RawSocket, headers: [String: String], leftover: Data, maxBytes: Int) throws -> Data {
        if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard length <= maxBytes else { throw ControlPlaneError.malformedResponse("body too large (\(length) bytes)") }
            var body = leftover
            while body.count < length {
                let chunk = try socket.receiveChunk()
                guard !chunk.isEmpty else {
                    throw ControlPlaneError.malformedResponse(
                        "connection closed after \(body.count) of \(length) response bytes"
                    )
                }
                body.append(chunk)
            }
            return Data(body.prefix(length))
        }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            return try readChunkedBody(socket: socket, leftover: leftover, maxBytes: maxBytes)
        }
        // No length and not chunked: read until the server closes (we always send Connection: close).
        var body = leftover
        while true {
            let chunk = try socket.receiveChunk()
            if chunk.isEmpty { break }
            body.append(chunk)
            guard body.count <= maxBytes else { throw ControlPlaneError.malformedResponse("body too large") }
        }
        return body
    }

    private static func readChunkedBody(socket: RawSocket, leftover: Data, maxBytes: Int) throws -> Data {
        var buffer = leftover
        var output = Data()
        func ensure(_ count: Int) throws {
            while buffer.count < count {
                let chunk = try socket.receiveChunk()
                guard !chunk.isEmpty else { throw ControlPlaneError.malformedResponse("connection closed mid-chunk") }
                buffer.append(chunk)
            }
        }
        func readLine() throws -> String {
            while true {
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    let line = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<range.upperBound)
                    return line
                }
                let chunk = try socket.receiveChunk()
                guard !chunk.isEmpty else { throw ControlPlaneError.malformedResponse("connection closed mid-chunk") }
                buffer.append(chunk)
            }
        }
        while true {
            let sizeLine = try readLine()
            let sizeHex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(sizeHex, radix: 16) else { throw ControlPlaneError.malformedResponse("bad chunk size: \(sizeLine)") }
            if size == 0 {
                _ = try? readLine()
                break
            }
            try ensure(size + 2)
            output.append(buffer.prefix(size))
            buffer.removeSubrange(..<buffer.index(buffer.startIndex, offsetBy: size + 2))
            guard output.count <= maxBytes else { throw ControlPlaneError.malformedResponse("body too large") }
        }
        return output
    }

    private static func apiError(status: Int, body: Data) -> ControlPlaneError {
        if let envelope = try? JSONDecoder().decode(WireErrorEnvelope.self, from: body) {
            return .apiError(status: status, code: envelope.error.code, message: envelope.error.message)
        }
        let snippet = truncated(String(decoding: body, as: UTF8.self), max: 200)
        return .apiError(status: status, code: "http_\(status)", message: snippet.isEmpty ? "request failed" : snippet)
    }
}

extension RawHTTPClient {
    /// Shared by `perform` callers that need the API-error mapping for a non-2xx JSON response.
    static func mapNon2xx(status: Int, body: Data) -> ControlPlaneError {
        apiError(status: status, body: body)
    }
}
