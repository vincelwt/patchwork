import Foundation

/// A route pattern like `/v1/threads/:id/messages`: literal segments must match exactly, `:name`
/// segments capture (and are percent-decoded, since a caller may pass a thread's raw file path
/// as `{id}` and must percent-encode any `/` within it for the segment count to line up).
struct RoutePattern {
    enum Segment: Equatable { case literal(String); case parameter(String) }
    let segments: [Segment]
    let raw: String

    init(_ pattern: String) {
        raw = pattern
        segments = pattern.split(separator: "/", omittingEmptySubsequences: true).map { part in
            part.hasPrefix(":") ? .parameter(String(part.dropFirst())) : .literal(String(part))
        }
    }

    func match(_ pathSegments: [Substring]) -> [String: String]? {
        guard pathSegments.count == segments.count else { return nil }
        var params: [String: String] = [:]
        for (segment, raw) in zip(segments, pathSegments) {
            switch segment {
            case let .literal(value):
                guard value == raw else { return nil }
            case let .parameter(name):
                params[name] = raw.removingPercentEncoding ?? String(raw)
            }
        }
        return params
    }
}

struct Route {
    let method: String
    let pattern: RoutePattern
    let handler: @Sendable (HTTPRequest, [String: String]) async throws -> HTTPResponse

    init(_ method: String, _ pattern: String, _ handler: @escaping @Sendable (HTTPRequest, [String: String]) async throws -> HTTPResponse) {
        self.method = method
        self.pattern = RoutePattern(pattern)
        self.handler = handler
    }
}

/// Routes are registered once at startup and never mutated afterward, so concurrent request
/// handling only ever reads `routes` \u2014 no locking needed.
final class DaemonRouter: Sendable {
    private let routes: [Route]

    init(routes: [Route]) { self.routes = routes }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let pathSegments = request.path.split(separator: "/", omittingEmptySubsequences: true)
        var methodMismatch = false
        for route in routes {
            guard let params = route.pattern.match(pathSegments) else { continue }
            guard route.method == request.method else { methodMismatch = true; continue }
            do {
                return try await route.handler(request, params)
            } catch let error as DaemonHTTPError {
                return error.response
            } catch {
                // A single handler's unexpected failure becomes a 500, never a crashed daemon.
                return .error(500, code: "internal_error", message: "\(error)")
            }
        }
        if methodMismatch {
            return .error(405, code: "method_not_allowed", message: "\(request.method) is not supported for \(request.path).")
        }
        return .error(404, code: "not_found", message: "No such endpoint: \(request.path)")
    }
}
