import Foundation

/// Where to reach the daemon. The Unix socket needs no credential (filesystem permissions are
/// the boundary); loopback TCP always carries a bearer token.
public enum PiDeskTransport: Sendable, Equatable {
    case unixSocket(path: String)
    case tcp(host: String, port: Int, token: String)
}

/// Every error `PiDeskClient` throws. `.daemonUnreachable` is deliberately its own case — every
/// client (CLI, app, web remote) needs to tell "nothing is listening" apart from "the daemon
/// answered with an error", since only the former means "fall back to local/read-only mode".
public enum PiDeskClientError: Error, LocalizedError, Sendable {
    case daemonUnreachable(String)
    case unauthorized
    case notFound(String)
    case badRequest(code: String, message: String)
    case server(status: Int, code: String, message: String)
    case invalidResponse(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .daemonUnreachable(detail): "Pi Desktop's daemon is not reachable: \(detail)"
        case .unauthorized: "The daemon rejected this request's bearer token."
        case let .notFound(what): "\(what) was not found."
        case let .badRequest(code, message): "\(message) (\(code))"
        case let .server(status, code, message): "Daemon error \(status) \(code): \(message)"
        case let .invalidResponse(detail): "The daemon's response could not be parsed: \(detail)"
        case let .decodingFailed(detail): "The daemon's response did not match the expected shape: \(detail)"
        }
    }
}

/// Async client for the control-plane HTTP API in `docs/daemon-api.md`, over either transport.
/// One method per endpoint, all typed. No connection pooling: each call is a short-lived
/// `Connection: close` request on its own thread (blocking POSIX I/O has no async-native
/// equivalent without Network.framework, and this keeps the client dependency-free and simple);
/// `events()` is the one long-lived exception.
public final class PiDeskClient: Sendable {
    public let transport: PiDeskTransport
    private let requestTimeout: TimeInterval
    /// Bounds a response body the same way the server bounds a request body — a misbehaving or
    /// malicious peer on the loopback port must not exhaust client memory either.
    private let maxResponseBytes: Int

    public init(transport: PiDeskTransport, requestTimeout: TimeInterval = 10, maxResponseBytes: Int = 16 * 1_024 * 1_024) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
    }

    public static func unixSocket(at path: URL = PiDeskPaths.controlSocket, requestTimeout: TimeInterval = 10) -> PiDeskClient {
        PiDeskClient(transport: .unixSocket(path: path.path), requestTimeout: requestTimeout)
    }

    // MARK: - Health

    public func health() async throws -> HealthStatus { try await get("/v1/health") }

    // MARK: - Threads

    public func listThreads(
        query: String? = nil, limit: Int? = nil, cursor: String? = nil,
        archived: Bool? = nil, running: Bool? = nil, automated: Bool? = nil,
        agent: AgentKind? = nil, sidebar: Bool? = nil
    ) async throws -> ThreadListResponse {
        try await get("/v1/threads", query: [
            "query": query,
            "limit": limit.map(String.init),
            "cursor": cursor,
            "archived": archived.map(String.init),
            "running": running.map(String.init),
            "automated": automated.map(String.init),
            "agent": agent?.rawValue,
            "sidebar": sidebar.map(String.init)
        ])
    }

    public func getThread(
        id: String, messages: Int = 20, offset: Int = 0, includeTools: Bool = true
    ) async throws -> ThreadDetailResponse {
        try await get("/v1/threads/\(pathComponent: id)", query: [
            "messages": String(messages), "offset": String(offset), "all": String(includeTools)
        ])
    }

    public func createThread(_ request: CreateThreadRequest) async throws -> CreateThreadResponse {
        try await post("/v1/threads", body: request)
    }

    public func threadRuntime(id: String) async throws -> ThreadRuntimeResponse {
        try await get("/v1/threads/\(pathComponent: id)/runtime")
    }

    public func setThreadModel(id: String, _ request: SetThreadModelRequest) async throws -> ThreadRuntimeResponse {
        try await post("/v1/threads/\(pathComponent: id)/runtime/model", body: request)
    }

    public func setThreadThinking(id: String, _ request: SetThreadThinkingRequest) async throws -> ThreadRuntimeResponse {
        try await post("/v1/threads/\(pathComponent: id)/runtime/thinking", body: request)
    }

    public func sendMessage(threadId: String, _ request: SendMessageRequest) async throws -> SendMessageResponse {
        try await post("/v1/threads/\(pathComponent: threadId)/messages", body: request)
    }

    public func abortThread(id: String) async throws -> AbortResponse {
        try await post("/v1/threads/\(pathComponent: id)/abort", body: Optional<Empty>.none)
    }

    public func archiveThread(id: String, archived: Bool) async throws -> ThreadResponse {
        try await post("/v1/threads/\(pathComponent: id)/archive", body: ArchiveRequest(archived: archived))
    }

    public func renameThread(id: String, name: String) async throws -> ThreadResponse {
        try await post("/v1/threads/\(pathComponent: id)/name", body: NameRequest(name: name))
    }

    public func markThreadRead(id: String, unread: Bool) async throws -> ThreadResponse {
        try await post("/v1/threads/\(pathComponent: id)/read", body: ReadRequest(unread: unread))
    }

    public func leaseThread(id: String, _ request: LeaseRequest) async throws -> LeaseResponse {
        try await post("/v1/threads/\(pathComponent: id)/lease", body: request)
    }

    // MARK: - Activity

    public func activity() async throws -> ActivitySnapshot { try await get("/v1/activity") }

    // MARK: - Schedules

    public func listSchedules() async throws -> ScheduleListResponse { try await get("/v1/schedules") }

    public func createSchedule(_ request: ScheduleCreateRequest) async throws -> ScheduleResponse {
        try await post("/v1/schedules", body: request)
    }

    public func getSchedule(id: String) async throws -> ScheduleDetailResponse {
        try await get("/v1/schedules/\(pathComponent: id)")
    }

    public func updateSchedule(id: String, _ request: ScheduleUpdateRequest) async throws -> ScheduleResponse {
        try await send("PATCH", "/v1/schedules/\(pathComponent: id)", body: request)
    }

    public func deleteSchedule(id: String) async throws -> DeletedResponse {
        try await send("DELETE", "/v1/schedules/\(pathComponent: id)", body: Optional<Empty>.none)
    }

    public func runSchedule(id: String) async throws -> ScheduleRunResponse {
        try await post("/v1/schedules/\(pathComponent: id)/run", body: Optional<Empty>.none)
    }

    public func pauseSchedule(id: String, paused: Bool) async throws -> ScheduleResponse {
        try await post("/v1/schedules/\(pathComponent: id)/pause", body: SchedulePauseRequest(paused: paused))
    }

    // MARK: - Runs

    public func listRuns(scheduleId: String? = nil, threadId: String? = nil, limit: Int? = nil) async throws -> RunListResponse {
        try await get("/v1/runs", query: ["scheduleId": scheduleId, "threadId": threadId, "limit": limit.map(String.init)])
    }

    public func getRun(id: String) async throws -> RunResponse {
        try await get("/v1/runs/\(pathComponent: id)")
    }

    // MARK: - Limits

    public func limits() async throws -> LimitsSnapshot { try await get("/v1/limits") }

    // MARK: - Hosted remote

    public func remoteAccessStatus() async throws -> RemoteAccessStatus {
        try await get("/v1/remote")
    }

    public func createRemotePairing() async throws -> RemotePairingOffer {
        try await post("/v1/remote/pairings", body: Optional<Empty>.none)
    }

    public func decideRemotePairing(id: String, approved: Bool) async throws -> RemoteAccessStatus {
        try await post(
            "/v1/remote/pairings/\(pathComponent: id)",
            body: RemotePairingDecisionRequest(approved: approved)
        )
    }

    public func revokeRemoteDevice(id: String) async throws -> RemoteDeletedResponse {
        try await send("DELETE", "/v1/remote/devices/\(pathComponent: id)", body: Optional<Empty>.none)
    }

    // MARK: - Events (SSE)

    /// Consumes `GET /v1/events` for as long as the caller keeps iterating. Ends the stream
    /// (rather than throwing) on a clean server close; throws `.daemonUnreachable` if the
    /// connection cannot even be opened. Cancelling iteration (e.g. `break`, or the calling
    /// `Task` being cancelled) closes the socket via `onTermination`.
    public func events() -> AsyncThrowingStream<PiDeskEvent, Error> {
        let transport = transport
        let timeout = requestTimeout
        let box = FileDescriptorBox()

        return AsyncThrowingStream { continuation in
            Thread.detachNewThread {
                do {
                    let fd = try Self.openConnection(transport: transport, connectTimeout: timeout)
                    box.fd = fd
                    // No read timeout on the long-lived stream itself: the server's own 20s
                    // keep-alive comment is what proves the connection is still alive.
                    RawSocket.setTimeouts(fd: fd, timeout: 0)
                    let headers = Self.baseHeaders(transport: transport)
                    try RawSocket.writeAll(fd: fd, data: HTTPWireFormat.buildRequest(method: "GET", path: "/v1/events", headers: headers, body: nil))

                    var head: RawHTTPResponse?
                    var pending = Data()
                    var parser = SSEParser()
                    while !box.cancelled {
                        guard let chunk = RawSocket.read(fd: fd, maxBytes: 64 * 1_024) else { break }
                        if head == nil {
                            pending.append(chunk)
                            guard let split = HTTPWireFormat.splitHeadFromStream(pending) else { continue }
                            head = split.head
                            guard split.head.status == 200 else {
                                throw PiDeskClientError.server(status: split.head.status, code: "events_failed", message: "GET /v1/events returned \(split.head.status)")
                            }
                            for frame in parser.append(split.leftover) { continuation.yield(frame.decodedEvent()) }
                            continue
                        }
                        for frame in parser.append(chunk) { continuation.yield(frame.decodedEvent()) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is PiDeskClientError ? error : PiDeskClientError.daemonUnreachable(String(describing: error)))
                }
                box.closeOnce()
            }
            continuation.onTermination = { _ in
                box.cancelled = true
                box.closeOnce()
            }
        }
    }

    // MARK: - Request plumbing

    private struct Empty: Encodable {}

    private func get<Response: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> Response {
        try await send("GET", path, query: query, body: Optional<Empty>.none)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body?) async throws -> Response {
        try await send("POST", path, body: body)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: Body?) async throws -> Response {
        let data = try await sendRaw(method, path, query: query, body: body)
        do {
            return try PiDeskJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw PiDeskClientError.decodingFailed("\(method) \(path): \(error)")
        }
    }

    private func sendRaw<Body: Encodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: Body?) async throws -> Data {
        let transport = transport
        let timeout = requestTimeout
        let maxBytes = maxResponseBytes
        let fullPath = Self.buildPath(path, query: query)
        let bodyData: Data? = try body.flatMap { try PiDeskJSON.encoder.encode($0) }

        return try await Self.performBlocking {
            let fd = try Self.openConnection(transport: transport, connectTimeout: timeout)
            defer { RawSocket.shutdownAndClose(fd: fd) }
            let headers = Self.baseHeaders(transport: transport)
            try RawSocket.writeAll(fd: fd, data: HTTPWireFormat.buildRequest(method: method, path: fullPath, headers: headers, body: bodyData))
            let raw = try RawSocket.readAllUntilClosed(fd: fd, maxBytes: maxBytes)
            let response = try HTTPWireFormat.parseResponse(raw)
            return try Self.mapStatus(response)
        }
    }

    private static func openConnection(transport: PiDeskTransport, connectTimeout: TimeInterval) throws -> Int32 {
        do {
            switch transport {
            case let .unixSocket(path):
                return try RawSocket.connectUnix(path: path, timeout: connectTimeout)
            case let .tcp(host, port, _):
                return try RawSocket.connectTCP(host: host, port: port, timeout: connectTimeout)
            }
        } catch let error as RawSocketError {
            throw PiDeskClientError.daemonUnreachable(error.localizedDescription)
        }
    }

    private static func baseHeaders(transport: PiDeskTransport) -> [String: String] {
        var headers = ["X-Pi-Desktop-Api": "\(PiDeskAPI.apiVersion)"]
        if case let .tcp(_, _, token) = transport { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    private static func mapStatus(_ response: RawHTTPResponse) throws -> Data {
        switch response.status {
        case 200...299:
            return response.body
        case 401:
            throw PiDeskClientError.unauthorized
        case 404:
            let message = (try? PiDeskJSON.decoder.decode(APIErrorEnvelope.self, from: response.body))?.error.message ?? "Not found"
            throw PiDeskClientError.notFound(message)
        case 400...499:
            let envelope = try? PiDeskJSON.decoder.decode(APIErrorEnvelope.self, from: response.body)
            throw PiDeskClientError.badRequest(code: envelope?.error.code ?? "bad_request", message: envelope?.error.message ?? "Request rejected (\(response.status))")
        default:
            let envelope = try? PiDeskJSON.decoder.decode(APIErrorEnvelope.self, from: response.body)
            throw PiDeskClientError.server(status: response.status, code: envelope?.error.code ?? "server_error", message: envelope?.error.message ?? "Daemon error \(response.status)")
        }
    }

    /// Bridges a blocking POSIX call onto a dedicated OS thread rather than a `Task`, so it never
    /// occupies one of Swift's cooperative-pool threads (which must never block).
    private static func performBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func buildPath(_ path: String, query: [String: String?]) -> String {
        let pairs = query.compactMapValues { $0 }.sorted { $0.key < $1.key }
        guard !pairs.isEmpty else { return path }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=")
        let encoded = pairs.map { key, value -> String in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        return "\(path)?\(encoded.joined(separator: "&"))"
    }
}

/// Boxes a connection's file descriptor and cancellation flag so `events()`'s reader thread and
/// `onTermination` (which can run on any thread) can coordinate a clean, close-exactly-once
/// shutdown even if both fire around the same time.
private final class FileDescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _fd: Int32?
    private var _cancelled = false
    private var closed = false

    var fd: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return _fd }
        set { lock.lock(); _fd = newValue; lock.unlock() }
    }

    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    func closeOnce() {
        lock.lock()
        let descriptor = closed ? nil : _fd
        closed = true
        lock.unlock()
        if let descriptor { RawSocket.shutdownAndClose(fd: descriptor) }
    }
}

private extension String.StringInterpolation {
    /// `"\(pathComponent: id)"` percent-encodes a single path segment, so a thread id or
    /// schedule id with an unusual character cannot corrupt the request line.
    mutating func appendInterpolation(pathComponent value: String) {
        appendLiteral(value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value)
    }
}
