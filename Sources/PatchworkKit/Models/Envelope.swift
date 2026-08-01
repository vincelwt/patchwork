import Foundation

/// `{"error": {"code": "…", "message": "…"}}`, the one error shape every endpoint uses.
public struct APIErrorBody: Codable, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct APIErrorEnvelope: Codable, Hashable, Sendable {
    public var error: APIErrorBody

    public init(code: String, message: String) { error = APIErrorBody(code: code, message: message) }
    public init(_ error: APIErrorBody) { self.error = error }
}
