import Foundation
import PatchworkKit

/// Dialogs a daemon run is blocked on: what is pending, and how to answer it.
///
/// `GET /v1/interactions` is the authoritative list and the rehydration source. The `interaction`
/// SSE event is only a hint that something changed — a client that reconnects, was backgrounded,
/// or missed a frame must re-read this endpoint rather than trust its own accumulated state.
enum InteractionHandlers {
    /// Long enough for an `editor` dialog's real content, short enough that one answer cannot be
    /// used to push an unbounded string through the daemon into Pi.
    static let maxValueLength = 20_000

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
                try validate(body, against: interaction)

                switch core.interactions.respond(
                    id: id, value: body.value, confirmed: body.confirmed, cancelled: body.cancelled == true
                ) {
                case .answered:
                    return .json(InteractionRespondResponse(accepted: true))
                case .notFound:
                    throw DaemonHTTPError.notFound("Interaction \(id)")
                case let .writeFailed(reason):
                    // Pi never received the answer, so reporting success would strand the run and
                    // leave the reader believing they answered it. The dialog is still pending.
                    throw DaemonHTTPError.serviceUnavailable(
                        code: "response_not_delivered",
                        message: "Pi did not accept the answer: \(reason)"
                    )
                }
            }
        ]
    }

    /// Exactly one answer field, and one that suits the dialog's method. Guessing on the reader's
    /// behalf — treating a `confirmed` on a `select` as "the first option", or an absent field as
    /// a blank string — is precisely what this bridge must never do.
    private static func validate(_ body: InteractionRespondRequest, against interaction: PendingInteraction) throws {
        if body.cancelled == true {
            guard body.value == nil, body.confirmed == nil else {
                throw DaemonHTTPError.badRequest(
                    code: "ambiguous_response",
                    message: "cancelled cannot be combined with value or confirmed."
                )
            }
            return
        }

        guard body.value == nil || body.confirmed == nil else {
            throw DaemonHTTPError.badRequest(code: "ambiguous_response", message: "Provide either value or confirmed, not both.")
        }
        guard body.value != nil || body.confirmed != nil else {
            throw DaemonHTTPError.badRequest(code: "empty_response", message: "Provide value, confirmed, or cancelled.")
        }

        if interaction.method == .confirm {
            guard body.confirmed != nil else {
                throw DaemonHTTPError.badRequest(code: "wrong_response_field", message: "This dialog expects confirmed.")
            }
            return
        }

        guard let value = body.value else {
            throw DaemonHTTPError.badRequest(code: "wrong_response_field", message: "This dialog expects value.")
        }
        guard value.count <= maxValueLength else {
            throw DaemonHTTPError.badRequest(
                code: "value_too_long",
                message: "value must be \(maxValueLength) characters or fewer."
            )
        }
        // A `select` answer must be one of the exact strings Pi offered.
        if interaction.method == .select, !interaction.options.isEmpty, !interaction.options.contains(value) {
            throw DaemonHTTPError.badRequest(code: "invalid_option", message: "value must be one of the offered options.")
        }
        // A method this build does not recognise is surfaced so the run is visible, but the only
        // answer that is certainly safe for it is a cancellation.
        if !interaction.method.isAnswerable {
            throw DaemonHTTPError.badRequest(
                code: "unsupported_method",
                message: "This daemon cannot answer a \"\(interaction.method.rawValue)\" dialog; cancel it or answer it in the Mac app."
            )
        }
    }
}
