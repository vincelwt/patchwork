import Foundation
import PiDeskKit

/// Which listener accepted this connection. Authorization differs entirely by origin: the Unix
/// socket trusts filesystem permissions, loopback TCP requires a bearer token.
enum RequestOrigin: Sendable, Equatable { case unixSocket, tcp, relay }

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String] // lowercased keys
    var body: Data
    var origin: RequestOrigin

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        guard !body.isEmpty else {
            throw DaemonHTTPError.badRequest(code: "invalid_body", message: "Request body is required.")
        }
        do {
            return try PiDeskJSON.decoder.decode(T.self, from: body)
        } catch {
            throw DaemonHTTPError.badRequest(code: "invalid_body", message: "Could not parse request body: \(error)")
        }
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var statusText: String
    var headers: [String: String]
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let body = (try? PiDeskJSON.encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, statusText: Self.statusText(status), headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
    }

    static func noContentJSON(_ status: Int = 204) -> HTTPResponse {
        HTTPResponse(status: status, statusText: Self.statusText(status), headers: [:], body: Data())
    }

    static func error(_ status: Int, code: String, message: String) -> HTTPResponse {
        json(APIErrorEnvelope(code: code, message: message), status: status)
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// Errors a handler can throw; `DaemonRouter` turns these into the doc's `{"error":{...}}` shape.
/// Anything else thrown (or a Swift trap avoided by never happening) is caught as a generic 500
/// so one handler's bug can never take the listener down.
enum DaemonHTTPError: Error {
    case badRequest(code: String, message: String)
    case unauthorized
    case notFound(String)
    case conflict(code: String, message: String)
    case serviceUnavailable(code: String, message: String)

    var response: HTTPResponse {
        switch self {
        case let .badRequest(code, message): .error(400, code: code, message: message)
        case .unauthorized: .error(401, code: "unauthorized", message: "Missing or invalid bearer token.")
        case let .notFound(what): .error(404, code: "not_found", message: "\(what) was not found.")
        case let .conflict(code, message): .error(409, code: code, message: message)
        case let .serviceUnavailable(code, message): .error(503, code: code, message: message)
        }
    }
}
