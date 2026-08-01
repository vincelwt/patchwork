import Darwin
import Foundation
import PatchworkKit
import PatchworkWeb

enum HTTPParseError: Error { case malformed(String); case connectionClosed }

/// Owns zero, one, or two `POSIXListener`s (the Unix socket is always on; loopback TCP is
/// opt-in) and drives every connection: request parsing, bearer auth, routing, keep-alive, and
/// the one streaming exception, `GET /v1/events`.
///
/// Concurrency: each accepted connection is handled with **blocking** POSIX I/O on a GCD global
/// queue \u2014 deliberately not a `Task`, which must never block a cooperative-pool thread. GCD's
/// concurrent queue exists for exactly this kind of blocking work and grows its worker pool as
/// needed. `awaitBlocking` bridges into the (async) router from that blocking thread.
final class HTTPServer: @unchecked Sendable {
    private let router: DaemonRouter
    private let logger: DaemonLogger
    private let bus: EventBus
    private let tokenProvider: @Sendable () -> String?
    private let maxHeaderBytes = 32 * 1_024
    private let maxBodyBytes: Int
    private let idleTimeout: TimeInterval = 90
    private let connectionQueue = DispatchQueue(label: "app.patchwork.desktop.daemon.http", attributes: .concurrent)
    private let admission: HTTPConnectionAdmission

    private var listeners: [POSIXListener] = []
    private let listenersLock = NSLock()
    private let acceptThreads = ThreadGroup()

    init(
        router: DaemonRouter,
        logger: DaemonLogger,
        bus: EventBus,
        maxBodyBytes: Int = 8 * 1_024 * 1_024,
        maxConnections: Int = 64,
        maxSSEConnections: Int = 16,
        tokenProvider: @escaping @Sendable () -> String?
    ) {
        self.router = router
        self.logger = logger
        self.bus = bus
        self.maxBodyBytes = maxBodyBytes
        admission = HTTPConnectionAdmission(
            maxConnections: maxConnections, maxSSEConnections: maxSSEConnections
        )
        self.tokenProvider = tokenProvider
    }

    func start(unixSocketPath: URL, tcpPort: Int?) throws {
        let unix = try POSIXListener.unixSocket(path: unixSocketPath)
        addListener(unix)
        logger.info("Listening on unix socket \(unixSocketPath.path)")
        runAcceptLoop(unix)

        if let tcpPort {
            do {
                let listener = try POSIXListener.tcpLoopback(port: tcpPort)
                addListener(listener)
                logger.info("Listening on 127.0.0.1:\(tcpPort) (bearer auth required)")
                runAcceptLoop(listener)
            } catch {
                // The Unix socket is the transport every local client depends on; a failed
                // opt-in TCP bind (port already in use, etc.) must not take the daemon down.
                logger.error("Could not start loopback TCP listener on port \(tcpPort): \(error)")
            }
        }
    }

    func stop() {
        listenersLock.lock()
        let current = listeners
        listeners.removeAll()
        listenersLock.unlock()
        for listener in current { listener.close() }
    }

    private func addListener(_ listener: POSIXListener) {
        listenersLock.lock(); listeners.append(listener); listenersLock.unlock()
    }

    private func runAcceptLoop(_ listener: POSIXListener) {
        acceptThreads.run { [weak self] in
            listener.acceptLoop { client in
                guard let self else { Darwin.close(client); return }
                guard self.admission.acquireConnection() else {
                    Darwin.close(client)
                    return
                }
                self.connectionQueue.async {
                    defer { self.admission.releaseConnection() }
                    self.handle(fd: client, origin: listener.origin)
                }
            }
        }
    }

    // MARK: - Connection handling

    private func handle(fd: Int32, origin: RequestOrigin) {
        RawSocket.setTimeouts(fd: fd, timeout: idleTimeout)
        defer { Darwin.close(fd) }
        var buffer = Data()

        while true {
            let request: HTTPRequest?
            do {
                request = try readRequest(fd: fd, origin: origin, buffer: &buffer)
            } catch {
                writeResponse(fd: fd, .error(400, code: "bad_request", message: "Malformed request."), keepAlive: false)
                return
            }
            guard let request else { return } // clean close between requests

            // The remote UI's shell is static and carries no session data, so it is served
            // before the token check — otherwise the browser could never reach the screen that
            // asks for the token. Every `/v1/` call it then makes is authorized normally.
            if let response = Self.webAssetResponse(for: request) {
                writeResponse(fd: fd, response, keepAlive: shouldKeepAlive(request))
                if !shouldKeepAlive(request) { return }
                continue
            }

            if let authFailure = checkAuthorization(request) {
                writeResponse(fd: fd, authFailure.response, keepAlive: false)
                return
            }

            if request.method == "GET", request.path == "/v1/events" {
                guard admission.acquireSSE() else {
                    writeResponse(
                        fd: fd,
                        .error(
                            503, code: "event_streams_busy",
                            message: "Too many event streams are connected."
                        ),
                        keepAlive: false
                    )
                    return
                }
                defer { admission.releaseSSE() }
                writeSSEHead(fd: fd)
                streamEvents(fd: fd)
                return
            }

            let response = awaitBlocking { await self.router.handle(request) }
            let keepAlive = shouldKeepAlive(request)
            writeResponse(fd: fd, response, keepAlive: keepAlive)
            if !keepAlive { return }
        }
    }

    /// Serves the bundled web remote for any non-API path. `PatchworkWeb` owns traversal safety,
    /// MIME typing, and ETags; this only speaks HTTP.
    static func webAssetResponse(for request: HTTPRequest) -> HTTPResponse? {
        guard request.method == "GET" || request.method == "HEAD" else { return nil }
        guard let asset = PatchworkWeb.asset(for: request.path) else { return nil }

        var headers = [
            "Content-Type": asset.contentType,
            "ETag": asset.etag,
            "Cache-Control": "no-cache"
        ]
        if let match = request.header("if-none-match"), match == asset.etag {
            headers["Content-Length"] = "0"
            return HTTPResponse(status: 304, statusText: HTTPResponse.statusText(304), headers: headers, body: Data())
        }
        return HTTPResponse(
            status: 200,
            statusText: HTTPResponse.statusText(200),
            headers: headers,
            body: request.method == "HEAD" ? Data() : asset.data
        )
    }

    private func checkAuthorization(_ request: HTTPRequest) -> DaemonHTTPError? {
        guard request.origin == .tcp else { return nil } // UDS: filesystem permissions are the boundary
        guard let token = tokenProvider() else { return .unauthorized }
        guard let header = request.header("authorization"), header.hasPrefix("Bearer ") else { return .unauthorized }
        let candidate = String(header.dropFirst("Bearer ".count))
        return DaemonToken.matches(candidate, token: token) ? nil : .unauthorized
    }

    private func shouldKeepAlive(_ request: HTTPRequest) -> Bool {
        (request.header("connection")?.lowercased() ?? "keep-alive") != "close"
    }

    /// Reads one full request off `fd`, using `buffer` to retain bytes pipelined past the
    /// previous request on a keep-alive connection. Returns `nil` only on a clean close with no
    /// partial request pending (the normal way a keep-alive loop ends).
    private func readRequest(fd: Int32, origin: RequestOrigin, buffer: inout Data) throws -> HTTPRequest? {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let boundary = buffer.range(of: terminator) {
                let headText = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                let (method, path, query, headers) = try Self.parseHead(headText)

                if headers["transfer-encoding"] != nil {
                    throw HTTPParseError.malformed("chunked transfer-encoding is not supported")
                }
                var bodyLength = 0
                if let declared = headers["content-length"] {
                    guard let length = Int(declared), length >= 0 else {
                        throw HTTPParseError.malformed("invalid Content-Length")
                    }
                    guard length <= maxBodyBytes else {
                        throw HTTPParseError.malformed("request body exceeds the \(maxBodyBytes)-byte limit")
                    }
                    bodyLength = length
                }

                let bodyStart = boundary.upperBound
                while buffer.count < bodyStart + bodyLength {
                    guard let chunk = RawSocket.read(fd: fd, maxBytes: 64 * 1_024) else {
                        throw HTTPParseError.connectionClosed
                    }
                    buffer.append(chunk)
                }
                let body = Data(buffer[bodyStart..<(bodyStart + bodyLength)])
                buffer.removeSubrange(buffer.startIndex..<(bodyStart + bodyLength))
                return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body, origin: origin)
            }

            guard buffer.count <= maxHeaderBytes else {
                throw HTTPParseError.malformed("headers exceed the \(maxHeaderBytes)-byte limit")
            }
            guard let chunk = RawSocket.read(fd: fd, maxBytes: 4_096) else {
                if buffer.isEmpty { return nil }
                throw HTTPParseError.malformed("connection closed mid-request")
            }
            buffer.append(chunk)
        }
    }

    private static func parseHead(_ text: String) throws -> (method: String, path: String, query: [String: String], headers: [String: String]) {
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty, !lines[0].isEmpty else { throw HTTPParseError.malformed("empty request line") }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw HTTPParseError.malformed("malformed request line")
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard target.hasPrefix("/") else { throw HTTPParseError.malformed("request target must be absolute") }
        let (path, query) = splitTarget(target)

        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (method, path, query, headers)
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let questionMark = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<questionMark])
        var query: [String: String] = [:]
        for pair in target[target.index(after: questionMark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let rawKey = kv.first else { continue }
            let key = rawKey.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(rawKey)
            let rawValue = kv.count > 1 ? String(kv[1]) : ""
            let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            query[key] = value
        }
        return (path, query)
    }

    private func writeResponse(fd: Int32, _ response: HTTPResponse, keepAlive: Bool) {
        var headers = response.headers
        headers["X-Patchwork-Api"] = "\(PatchworkAPI.apiVersion)"
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"

        var head = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        try? RawSocket.writeAll(fd: fd, data: data)
    }

    // MARK: - SSE

    private func writeSSEHead(fd: Int32) {
        let headers = [
            "X-Patchwork-Api": "\(PatchworkAPI.apiVersion)",
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive"
        ]
        var head = "HTTP/1.1 200 OK\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        try? RawSocket.writeAll(fd: fd, data: Data(head.utf8))
    }

    private func streamEvents(fd: Int32) {
        // No read timeout: this connection is meant to sit idle between events. Liveness is
        // instead proven by the periodic keep-alive write below failing once the peer is gone.
        RawSocket.setTimeouts(fd: fd, timeout: 0)
        let writeLock = NSLock()
        let stateLock = NSLock()
        let wake = DispatchSemaphore(value: 0)
        var alive = true

        func markDead() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            let wasAlive = alive
            alive = false
            return wasAlive
        }

        func isAlive() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return alive
        }

        func send(_ data: Data) {
            guard isAlive() else { return }
            writeLock.lock()
            defer { writeLock.unlock() }
            guard isAlive() else { return }
            if (try? RawSocket.writeAll(fd: fd, data: data)) == nil {
                _ = markDead()
                wake.signal()
            }
        }

        let subscriptionID = bus.subscribe(
            initialName: "ready",
            initialPayload: Data("{}".utf8),
            onOverflow: {
                if markDead() { Darwin.shutdown(fd, SHUT_RDWR) }
                wake.signal()
            }
        ) { name, payload in
            var frame = Data("event: \(name)\ndata: ".utf8)
            frame.append(payload)
            frame.append(Data("\n\n".utf8))
            send(frame)
        }
        defer { bus.unsubscribe(subscriptionID) }

        while true {
            if wake.wait(timeout: .now() + 20) == .success { return }
            guard isAlive() else { return }
            send(Data(": keep-alive\n\n".utf8))
            if !isAlive() { return }
        }
    }

    /// Bridges a blocking connection-handling thread into the async `Router`. Safe specifically
    /// because the caller is a plain GCD/`Thread` worker, never a Swift cooperative-pool thread.
    private func awaitBlocking(_ operation: @escaping () async -> HTTPResponse) -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .error(500, code: "internal_error", message: "Handler produced no response.")
    }
}

/// A hard admission ceiling keeps idle sockets and long-lived event streams from creating an
/// unbounded blocking-worker pool. The accept loop uses the total limit; authorized SSE routes
/// additionally reserve the smaller streaming budget.
final class HTTPConnectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConnections: Int
    private let maxSSEConnections: Int
    private var connections = 0
    private var sseConnections = 0

    init(maxConnections: Int, maxSSEConnections: Int) {
        self.maxConnections = max(1, maxConnections)
        self.maxSSEConnections = max(0, min(maxSSEConnections, self.maxConnections))
    }

    func acquireConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connections < maxConnections else { return false }
        connections += 1
        return true
    }

    func releaseConnection() {
        lock.lock()
        connections = max(0, connections - 1)
        lock.unlock()
    }

    func acquireSSE() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sseConnections < maxSSEConnections else { return false }
        sseConnections += 1
        return true
    }

    func releaseSSE() {
        lock.lock()
        sseConnections = max(0, sseConnections - 1)
        lock.unlock()
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: HTTPResponse?
}

/// Tracks accept-loop threads so `HTTPServer` does not need Foundation's fire-and-forget
/// `Thread.detachNewThread` sprinkled through `start()`.
private final class ThreadGroup: @unchecked Sendable {
    func run(_ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "app.patchwork.desktop.daemon.accept"
        thread.start()
    }
}
