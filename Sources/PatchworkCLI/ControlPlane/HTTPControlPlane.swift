import Foundation

/// Default `ControlPlane`: builds JSON requests, sends them over `RawHTTPClient`, and decodes
/// responses into the `Wire*` models. This whole file is the standalone stand-in described in
/// ControlPlane.swift — every method here is a thin, mechanical translation of one
/// docs/daemon-api.md endpoint and should map almost 1:1 onto `PatchworkKit.PatchworkClient` methods
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
        try await self.request("POST", "/v1/threads", body: request)
    }

    func sendMessage(threadId: String, request: WireSendMessageRequest) async throws -> WireSendMessageResponse {
        try await self.request("POST", "/v1/threads/\(encodePathComponent(threadId))/messages", body: request)
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
        try await self.request("POST", "/v1/schedules", body: request)
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

    func runSchedule(id: String) async throws -> WireScheduleRunResponse {
        try await request("POST", "/v1/schedules/\(encodePathComponent(id))/run", body: EmptyBody())
    }

    func limits() async throws -> WireLimits {
        try await requestNoBody("GET", "/v1/limits")
    }

    func events() -> AsyncThrowingStream<ControlPlaneEvent, Error> {
        let lines = client.streamLines(path: "/v1/events", headers: authHeader)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                    continuation.finish()
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
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

/// A handful of endpoints take no request body; `Never`/`Optional<String>.none` reads awkwardly
/// at call sites, so this documents intent.
private struct EmptyBody: Encodable {}
