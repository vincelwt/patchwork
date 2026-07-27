import Foundation
import PiDeskKit

/// Dialogs a daemon run is blocked on: what is pending, and how to answer it.
///
/// `GET /v1/interactions` is the authoritative list and the rehydration source. The `interaction`
/// SSE event is only a hint that something changed — a client that reconnects, was backgrounded,
/// or missed a frame must re-read this endpoint rather than trust its own accumulated state.
enum InteractionHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/interactions") { request, _ in
                .json(InteractionListResponse(interactions: core.interactions.pending(threadID: request.query["threadId"])))
            },

            Route("POST", "/v1/interactions/:id/respond") { request, params in
                guard let id = params["id"], !id.isEmpty else {
                    throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing interaction id.")
                }
                guard let interaction = core.interactions.interaction(id: id) else {
                    // Already answered, expired, or its run ended. A stale phone retrying is
                    // routine, so this is a plain 404 rather than an error worth alarming about.
                    throw DaemonHTTPError.notFound("Interaction \(id)")
                }
                let body = try request.decodeJSON(InteractionRespondRequest.self)
                let cancelled = body.cancelled == true

                // A `select` answer must be one of the exact strings Pi offered. Anything else is
                // the client's mistake, and guessing on the user's behalf is precisely what this
                // bridge must never do.
                if !cancelled, let value = body.value, interaction.method == .select, !interaction.options.isEmpty {
                    guard interaction.options.contains(value) else {
                        throw DaemonHTTPError.badRequest(code: "invalid_option", message: "value must be one of the offered options.")
                    }
                }
                if !cancelled, body.value == nil, body.confirmed == nil {
                    throw DaemonHTTPError.badRequest(code: "empty_response", message: "Provide value, confirmed, or cancelled.")
                }
                if let value = body.value, value.count > 20_000 {
                    throw DaemonHTTPError.badRequest(code: "value_too_long", message: "value must be 20000 characters or fewer.")
                }

                guard core.interactions.respond(id: id, value: body.value, confirmed: body.confirmed, cancelled: cancelled) else {
                    throw DaemonHTTPError.notFound("Interaction \(id)")
                }
                return .json(InteractionRespondResponse(accepted: true))
            }
        ]
    }
}
