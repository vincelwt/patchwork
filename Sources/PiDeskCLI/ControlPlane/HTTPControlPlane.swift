import Foundation

/// Default `ControlPlane`: builds JSON requests, sends them over `RawHTTPClient`, and decodes
/// responses into the `Wire*` models. This whole file is the standalone stand-in described in
/// ControlPlane.swift — every method here is a thin, mechanical translation of one
/// docs/daemon-api.md endpoint and should map almost 1:1 onto `PiDeskKit.PiDeskClient` methods
/// once that lands.
final class HTTPControlPlane: ControlPlane {
    private let client: RawHTTPClient
    private let authHeader: [String: String]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(target: TransportTarget, token: String?, timeout: TimeInterval) {
        client = RawHTTPClient(target: target, timeout: timeout)
        if case .tcp = target, let token {
            authHeader = ["Authorization": "Bearer \(token)"]
        } else {
            authHeader = [:]
        }
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ method: String,
        _ path: String,
        body: Body?
    ) async throws -> Response {
        var headers = authHeader
        headers["Accept"] = "application/json"
        var bodyData: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            bodyData = try encoder.encode(body)
        }
        let response = try await client.perform(method: method, path: path, headers: headers, body: bodyData)
        guard (200..<300).contains(response.status) else {
            throw RawHTTPClient.mapNon2xx(status: response.status, body: response.body)
        }
        do {
            return try decoder.decode(Response.self, from: response.body)
        } catch {
            throw ControlPlaneError.malformedResponse("could not decode \(Response.self): \(error)")
        }
    }

    private func requestNoBody<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await request(method, path, body: Optional<String>.none)
    }

    func health() async throws -> WireHealth {
        try await requestNoBody("GET", "/v1/health")
    }

    func listThreads(
        query: String?, limit: Int, cursor: String?, archived: Bool?, running: Bool?, automated: Bool?, agent: String?
    ) async throws -> WireThreadListResponse {
        var items = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let archived { items.append(URLQueryItem(name: "archived", value: archived ? "true" : "false")) }
        if let running { items.append(URLQueryItem(name: "running", value: running ? "true" : "false")) }
        if let automated { items.append(URLQueryItem(name: "automated", value: automated ? "true" : "false")) }
        if let agent, !agent.isEmpty { items.append(URLQueryItem(name: "agent", value: agent)) }
        return try await requestNoBody("GET", "/v1/threads" + queryString(items))
    }

    func showThread(id: String, messages: Int, offset: Int, includeTools: Bool) async throws -> WireThreadDetailResponse {
        try await requestNoBody("GET", "/v1/threads/\(encodePathComponent(id))" + queryString([
            URLQueryItem(name: "messages", value: "\(messages)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "all", value: includeTools ? "true" : "false")
        ]))
    }

    func createThread(_ request: WireCreateThreadRequest) async throws -> WireCreateThreadResponse {
        guard request.clientId != nil else {
            return try await self.request("POST", "/v1/threads", body: request)
        }
        return try await retryingProtectedMutation(
            capability: \.threadCreationIdempotency,
            isRetryable: Self.isRetryableCreationError
        ) {
            try await self.request("POST", "/v1/threads", body: request)
        }
    }

    func sendMessage(threadId: String, request: WireSendMessageRequest) async throws -> WireSendMessageResponse {
        let path = "/v1/threads/\(encodePathComponent(threadId))/messages"
        guard request.clientId != nil else {
            return try await self.request("POST", path, body: request)
        }
        return try await retryingProtectedMutation(
            capability: \.messageSubmissionIdempotency,
            isRetryable: Self.isRetryableSubmissionError
        ) {
            try await self.request("POST", path, body: request)
        }
    }

    func abortThread(id: String) async throws -> WireAbortResponse {
        try await request("POST", "/v1/threads/\(encodePathComponent(id))/abort", body: EmptyBody())
    }

    func setArchived(id: String, archived: Bool) async throws -> WireThreadResponse {
        try await request("POST", "/v1/threads/\(encodePathComponent(id))/archive", body: ["archived": archived])
    }

    func renameThread(id: String, name: String) async throws -> WireThreadResponse {
        try await request("POST", "/v1/threads/\(encodePathComponent(id))/name", body: ["name": name])
    }

    func listSchedules() async throws -> WireScheduleListResponse {
        try await requestNoBody("GET", "/v1/schedules")
    }

    func createSchedule(_ request: WireScheduleCreateRequest) async throws -> WireScheduleResponse {
        guard request.idempotencyKey != nil else {
            return try await self.request("POST", "/v1/schedules", body: request)
        }
        return try await retryingProtectedMutation(
            capability: \.scheduleIdempotency,
            isRetryable: Self.isRetryableProtectedMutationError
        ) {
            try await self.request("POST", "/v1/schedules", body: request)
        }
    }

    func showSchedule(id: String) async throws -> WireScheduleDetailResponse {
        try await requestNoBody("GET", "/v1/schedules/\(encodePathComponent(id))")
    }

    func setSchedulePaused(id: String, paused: Bool) async throws -> WireScheduleResponse {
        try await request("POST", "/v1/schedules/\(encodePathComponent(id))/pause", body: ["paused": paused])
    }

    func deleteSchedule(id: String) async throws -> WireScheduleDeleteResponse {
        try await request("DELETE", "/v1/schedules/\(encodePathComponent(id))", body: EmptyBody())
    }

    func runSchedule(id: String, request: WireScheduleRunRequest) async throws -> WireScheduleRunResponse {
        guard request.clientId != nil else {
            return try await self.request(
                "POST", "/v1/schedules/\(self.encodePathComponent(id))/run", body: request
            )
        }
        return try await retryingProtectedMutation(
            capability: \.scheduleRunIdempotency,
            isRetryable: Self.isRetryableProtectedMutationError
        ) {
            try await self.request(
                "POST", "/v1/schedules/\(self.encodePathComponent(id))/run", body: request
            )
        }
    }

    func showRun(id: String) async throws -> WireRunResponse {
        try await requestNoBody("GET", "/v1/runs/\(encodePathComponent(id))")
    }

    func limits() async throws -> WireLimits {
        try await requestNoBody("GET", "/v1/limits")
    }

    func events() -> AsyncThrowingStream<ControlPlaneEvent, Error> {
        let lines = client.streamLines(path: "/v1/events", headers: authHeader)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line) {
                            switch continuation.yield(event) {
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
                    }
                    continuation.finish(throwing: ControlPlaneError.transportFailure(
                        "event stream ended"
                    ))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func queryString(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        var components = URLComponents()
        components.queryItems = items
        return components.url?.query.map { "?\($0)" } ?? ""
    }

    private func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func isRetryableSubmissionError(_ error: ControlPlaneError) -> Bool {
        switch error {
        case .unreachable, .timedOut, .transportFailure, .malformedResponse:
            true
        case let .apiError(_, code, _):
            code == "submission_in_flight"
        case .outcomeUnknown:
            false
        }
    }

    private static func isRetryableCreationError(_ error: ControlPlaneError) -> Bool {
        switch error {
        case .unreachable, .timedOut, .transportFailure, .malformedResponse:
            true
        case let .apiError(_, code, _):
            code == "creation_in_flight" || code == "creations_busy"
                || code == "create_retryable" || code == "creation_pending"
                || code == "submission_ledger_unavailable"
        case .outcomeUnknown:
            false
        }
    }

    private func retryingProtectedMutation<Response>(
        capability: KeyPath<WireHealth, Bool?>,
        isRetryable: (ControlPlaneError) -> Bool,
        _ operation: () async throws -> Response
    ) async throws -> Response {
        guard await supports(capability) else {
            do {
                return try await operation()
            } catch let error as ControlPlaneError where isRetryable(error) {
                guard Self.mutationOutcomeMayBeUnknown(error) else { throw error }
                throw ControlPlaneError.outcomeUnknown(Self.outcomeUnknownMessage(for: error))
            }
        }
        var lastError: Error?
        var lastPotentiallyAmbiguousError: ControlPlaneError?
        var anAttemptMayHaveReachedDaemon = false
        for attempt in 0..<4 {
            do {
                return try await operation()
            } catch let error as ControlPlaneError where isRetryable(error) {
                lastError = error
                if Self.mutationOutcomeMayBeUnknown(error) {
                    lastPotentiallyAmbiguousError = error
                }
                anAttemptMayHaveReachedDaemon = anAttemptMayHaveReachedDaemon
                    || Self.mutationOutcomeMayBeUnknown(error)
                guard attempt < 3 else { break }
                guard await supports(capability) else {
                    guard anAttemptMayHaveReachedDaemon else { throw error }
                    throw ControlPlaneError.outcomeUnknown(Self.outcomeUnknownMessage(for: error))
                }
                try await Task.sleep(nanoseconds: UInt64(50_000_000 * (attempt + 1)))
            }
        }
        // A final connect refusal proves only that the final attempt was not sent. It cannot
        // erase an earlier response-loss attempt that may already have crossed the daemon
        // boundary. Preserve that earlier ambiguity so callers keep the same protected id.
        if let lastPotentiallyAmbiguousError { throw lastPotentiallyAmbiguousError }
        throw lastError ?? ControlPlaneError.transportFailure("protected mutation did not complete")
    }

    private func supports(_ capability: KeyPath<WireHealth, Bool?>) async -> Bool {
        guard let status = try? await health() else { return false }
        return status[keyPath: capability] == true
    }

    private static func outcomeUnknownMessage(for error: ControlPlaneError) -> String {
        let detail: String
        switch error {
        case let .unreachable(reason), let .timedOut(reason), let .malformedResponse(reason),
             let .transportFailure(reason), let .outcomeUnknown(reason):
            detail = reason
        case let .apiError(_, code, message):
            detail = "\(code): \(message)"
        }
        return "The mutation result could not be confirmed and this daemon did not advertise replay protection: \(detail)"
    }

    private static func isRetryableProtectedMutationError(_ error: ControlPlaneError) -> Bool {
        switch error {
        case .unreachable, .timedOut, .transportFailure, .malformedResponse:
            true
        case let .apiError(_, code, _):
            code == "schedule_run_in_flight" || code == "submissions_busy"
                || code == "submission_ledger_unavailable"
        case .outcomeUnknown:
            false
        }
    }

    /// A refusal before connect is certainly unsent. Once request bytes or a daemon response are
    /// involved, a dropped response can leave the mutation result unknown.
    private static func mutationOutcomeMayBeUnknown(_ error: ControlPlaneError) -> Bool {
        switch error {
        case .unreachable:
            false
        case .timedOut, .transportFailure, .malformedResponse, .outcomeUnknown:
            true
        case let .apiError(_, code, _):
            code == "submission_in_flight" || code == "creation_in_flight"
                || code == "schedule_run_in_flight"
        }
    }
}

/// A handful of endpoints take no request body; `Never`/`Optional<String>.none` reads awkwardly
/// at call sites, so this documents intent.
private struct EmptyBody: Encodable {}
