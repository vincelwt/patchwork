import Foundation
import PiDeskKit

/// Pairing and device management are local-only. A paired browser can use the ordinary `/v1`
/// API through the encrypted relay, but can never approve or mint another remote device.
enum RemoteHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/remote") { request, _ in
                try requireLocal(request)
                return .json(await core.relay.status())
            },
            Route("POST", "/v1/remote/pairings") { request, _ in
                try requireLocal(request)
                do {
                    return .json(try await core.relay.createPairingOffer(), status: 201)
                } catch {
                    throw DaemonHTTPError.serviceUnavailable(
                        code: "relay_offline",
                        message: error.localizedDescription
                    )
                }
            },
            Route("POST", "/v1/remote/pairings/:id") { request, params in
                try requireLocal(request)
                let decision = try request.decodeJSON(RemotePairingDecisionRequest.self)
                guard let id = params["id"] else { throw DaemonHTTPError.notFound("Pairing") }
                do {
                    return .json(try await core.relay.decidePairing(id: id, approved: decision.approved))
                } catch {
                    throw DaemonHTTPError.serviceUnavailable(
                        code: "relay_offline",
                        message: error.localizedDescription
                    )
                }
            },
            Route("DELETE", "/v1/remote/devices/:id") { request, params in
                try requireLocal(request)
                guard let id = params["id"] else { throw DaemonHTTPError.notFound("Device") }
                do {
                    try await core.relay.revokeDevice(id: id)
                    return .json(RemoteDeletedResponse(deleted: true))
                } catch {
                    throw DaemonHTTPError.serviceUnavailable(
                        code: "relay_offline",
                        message: error.localizedDescription
                    )
                }
            }
        ]
    }

    private static func requireLocal(_ request: HTTPRequest) throws {
        guard request.origin == .unixSocket else { throw DaemonHTTPError.unauthorized }
    }
}
