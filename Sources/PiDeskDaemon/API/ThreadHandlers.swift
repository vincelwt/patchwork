import Foundation
import PiDeskKit

enum ThreadHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/threads") { request, _ in
                let limit = clamp(request.query["limit"].flatMap(Int.init) ?? 50, 1, 200)
                let (threads, next) = await core.threadStore.listThreads(
                    query: request.query["query"],
                    limit: limit,
                    cursor: request.query["cursor"],
                    archived: request.query["archived"].flatMap(parseBool),
                    running: request.query["running"].flatMap(parseBool)
                )
                return .json(ThreadListResponse(threads: threads, nextCursor: next))
            },

            Route("GET", "/v1/threads/:id") { request, params in
                let thread = try await requireThread(core, params)
                let limit = clamp(request.query["messages"].flatMap(Int.init) ?? 20, 0, 500)
                let messages = (try? SessionThreadParser.messages(at: URL(fileURLWithPath: thread.path), limit: limit)) ?? []
                return .json(ThreadDetailResponse(thread: thread, messages: messages))
            },

            // Image bytes never travel inside a thread detail: one screenshot-heavy transcript
            // would blow past the hosted relay's 1.5 MB encrypted-payload ceiling. `Message.images`
            // carries metadata, and each image is fetched here, one bounded response at a time.
            Route("GET", "/v1/threads/:id/images/:imageId") { _, params in
                let thread = try await requireThread(core, params)
                guard let imageId = params["imageId"], !imageId.isEmpty else {
                    throw DaemonHTTPError.badRequest(code: "missing_image_id", message: "Missing image id.")
                }
                let image = (try? SessionThreadParser.image(at: URL(fileURLWithPath: thread.path), imageId: imageId)) ?? nil
                guard let image else { throw DaemonHTTPError.notFound("Image \(imageId)") }
                return .json(image)
            },

            // Read-only projection of the app's own `state.json` folders. The daemon never writes
            // that file; a folder tree that is missing, legacy, or cyclic degrades to a flat or
            // empty list rather than an error.
            Route("GET", "/v1/folders") { _, _ in
                .json(AppStatePeek.load(from: core.appStateURL).folderTree)
            },

            Route("POST", "/v1/threads") { request, _ in
                let body = try request.decodeJSON(CreateThreadRequest.self)
                let cwd = (body.cwd as NSString).expandingTildeInPath
                guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
                    throw DaemonHTTPError.badRequest(code: "invalid_cwd", message: "cwd must be an existing directory.")
                }
                let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)

                guard let message = body.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
                    // No message: created idle, resolved synchronously, nothing queued.
                    let service = ThreadCreationService(logger: core.logger)
                    do {
                        let thread = try await service.createIdle(cwd: cwdURL, name: body.name)
                        return .json(CreateThreadResponse(thread: thread, runId: nil), status: 201)
                    } catch let error as RunnerError {
                        throw DaemonHTTPError.conflict(code: "create_failed", message: error.localizedDescription)
                    }
                }

                // A message is provided: the real thread identity is not known until the run
                // actually starts, so this responds with a placeholder and a `runId` the caller
                // polls (`GET /v1/runs/{runId}`, whose `threadId` is filled in once resolved).
                let job = RunJob(
                    id: "run_\(UUID().uuidString)", scheduleId: nil, trigger: .api,
                    target: .newThread(cwd: cwdURL.standardizedFileURL.path, namePattern: body.name),
                    prompt: message, mode: body.mode, timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date()
                )
                await core.runQueue.enqueue(job)
                let now = Date()
                let placeholder = PiThread(
                    id: "pending:\(job.id)", path: "", name: body.name?.isEmpty == false ? body.name! : "Untitled conversation",
                    cwd: cwdURL.standardizedFileURL.path, folder: cwdURL.standardizedFileURL.lastPathComponent,
                    createdAt: now, updatedAt: now, preview: message
                )
                return .json(CreateThreadResponse(thread: placeholder, runId: job.id), status: 202)
            },

            Route("POST", "/v1/threads/:id/messages") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(SendMessageRequest.self)
                let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw DaemonHTTPError.badRequest(code: "empty_text", message: "text must not be empty.") }

                // Accepting attachments and then dropping them would report a success the caller
                // never got. The web remote has no attachment picker, so rather than build an
                // untested image path into Pi's prompt, this says plainly that it is not supported.
                if let attachments = body.attachments, !attachments.isEmpty {
                    throw DaemonHTTPError.badRequest(
                        code: "attachments_unsupported",
                        message: "This daemon cannot forward message attachments; send the text alone or attach the image in the Mac app."
                    )
                }

                if await core.leaseStore.isLeased(threadId: thread.id) {
                    throw DaemonHTTPError.conflict(code: "thread_leased", message: "The app is currently attached to this thread's runtime.")
                }

                // A lost response is the common failure on a phone, and the natural reaction is to
                // retry. Without this, that retry prompts Pi a second time. `clientId` makes the
                // whole endpoint replayable: the same pair returns the same answer and does not
                // deliver or enqueue anything again.
                let clientID = try validatedClientID(body.clientId)
                if let clientID {
                    switch await core.submissions.claim(threadID: thread.id, clientID: clientID) {
                    case let .replay(response):
                        return .json(response)
                    case .inFlight:
                        throw DaemonHTTPError.conflict(
                            code: "submission_in_flight",
                            message: "This message is already being sent."
                        )
                    case .overloaded:
                        // Refusing is the safe end of this trade: making room would mean
                        // forgetting a send that is still running, and its retry would prompt
                        // Pi twice.
                        throw DaemonHTTPError.serviceUnavailable(
                            code: "submissions_busy",
                            message: "Too many sends are still in flight. Try again in a moment."
                        )
                    case .proceed:
                        break
                    }
                }

                do {
                    let response = try await deliverOrEnqueue(core, thread: thread, text: text, delivery: body.delivery)
                    if let clientID {
                        await core.submissions.complete(threadID: thread.id, clientID: clientID, response: response)
                    }
                    return .json(response)
                } catch {
                    // Nothing was delivered or queued, so the claim must not lock out an honest
                    // retry of the same submission.
                    if let clientID { await core.submissions.abandon(threadID: thread.id, clientID: clientID) }
                    throw error
                }
            },

            Route("POST", "/v1/threads/:id/abort") { _, params in
                let thread = try await requireThread(core, params)
                let aborted = await core.runQueue.abort(threadId: thread.id)
                return .json(AbortResponse(aborted: aborted))
            },

            Route("POST", "/v1/threads/:id/archive") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(ArchiveRequest.self)
                let updated = try await core.threadStore.setArchived(body.archived, idOrPath: thread.id)
                return .json(ThreadResponse(thread: updated))
            },

            Route("POST", "/v1/threads/:id/name") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(NameRequest.self)
                let clean = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw DaemonHTTPError.badRequest(code: "empty_name", message: "name must not be empty.") }
                if await core.leaseStore.isLeased(threadId: thread.id) {
                    throw DaemonHTTPError.conflict(code: "thread_leased", message: "The app is currently attached to this thread's runtime.")
                }
                if await core.runQueue.isThreadBusy(thread.id) {
                    throw DaemonHTTPError.conflict(code: "thread_busy", message: "Rename once the thread is idle.")
                }
                // Renaming goes through Pi's own `set_session_name` RPC — Pi appends the new
                // `session_info` entry itself, so this never touches a Pi JSONL file directly.
                let service = ThreadCreationService(logger: core.logger)
                do {
                    try await service.rename(cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path), name: clean)
                } catch let error as RunnerError {
                    throw DaemonHTTPError.conflict(code: "rename_failed", message: error.localizedDescription)
                }
                guard let refreshed = await core.threadStore.refreshedThread(idOrPath: thread.id) else { throw DaemonHTTPError.notFound("Thread \(thread.id)") }
                return .json(ThreadResponse(thread: refreshed))
            },

            Route("POST", "/v1/threads/:id/read") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(ReadRequest.self)
                let updated = try await core.threadStore.setUnread(body.unread, idOrPath: thread.id)
                return .json(ThreadResponse(thread: updated))
            },

            Route("POST", "/v1/threads/:id/lease") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(LeaseRequest.self)
                if body.release == true {
                    await core.leaseStore.release(threadId: thread.id, owner: body.owner)
                    return .json(LeaseResponse(leased: false, owner: nil, expiresAt: nil))
                }
                let lease = await core.leaseStore.acquire(threadId: thread.id, owner: body.owner, ttlSeconds: body.ttlSeconds)
                return .json(LeaseResponse(leased: true, owner: lease.owner, expiresAt: lease.expiresAt))
            }
        ]
    }

    private static func requireThread(_ core: DaemonCore, _ params: [String: String]) async throws -> PiThread {
        guard let id = params["id"], !id.isEmpty else {
            throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing thread id.")
        }
        guard let thread = await core.threadStore.thread(idOrPath: id) else {
            throw DaemonHTTPError.notFound("Thread \(id)")
        }
        return thread
    }

    /// An explicit steer/follow-up is delivered into the live Pi turn or not at all: it is never
    /// quietly turned into a queued prompt, because "steer" that actually waits for the current
    /// run to finish is exactly the lie this endpoint used to tell. When nothing is live the
    /// response says so (`delivery: auto`) and the text becomes an ordinary prompt.
    private static func deliverOrEnqueue(
        _ core: DaemonCore, thread: PiThread, text: String, delivery: DeliveryMode?
    ) async throws -> SendMessageResponse {
        if let command = liveCommand(for: delivery),
           let delivered = await core.liveSessions.deliver(threadID: thread.id, command: command, message: text) {
            switch delivered.result {
            case let .rejected(reason):
                throw DaemonHTTPError.conflict(code: "delivery_rejected", message: reason)
            case .acknowledged, .unacknowledged:
                // `.unacknowledged` means the write reached Pi's stdin but no ack arrived in time.
                // Re-queueing here is the one thing that could prompt Pi twice, so it is reported
                // as delivered and never resent.
                return SendMessageResponse(runId: delivered.runID, queued: false, delivery: delivery)
            }
        }

        let alreadyBusy = await core.runQueue.isThreadBusy(thread.id)
        let job = RunJob(
            id: "run_\(UUID().uuidString)", scheduleId: nil, trigger: .api,
            target: .existingThread(threadId: thread.id, path: thread.path, cwd: thread.cwd),
            prompt: text, mode: nil, timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date()
        )
        await core.runQueue.enqueue(job)
        return SendMessageResponse(runId: job.id, queued: alreadyBusy, delivery: .auto)
    }

    /// A client-chosen id, so it is untrusted input: bounded in length and restricted to characters
    /// that cannot collide with the registry's own key separator. Absent means "not replayable",
    /// which is what an older client sends.
    private static func validatedClientID(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard raw.count <= 128, raw.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DaemonHTTPError.badRequest(
                code: "invalid_client_id",
                message: "clientId must be 1-128 letters, numbers, dashes, or underscores."
            )
        }
        return raw
    }

    /// Pi's own RPC verb for a delivery mode, or `nil` when the caller did not ask for one (so
    /// the message is an ordinary prompt and belongs in the queue).
    private static func liveCommand(for delivery: DeliveryMode?) -> String? {
        switch delivery {
        case .steer: "steer"
        case .followUp: "follow_up"
        case .auto, nil: nil
        }
    }

    private static func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "1", "yes": true
        case "false", "0", "no": false
        default: nil
        }
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int { max(lower, min(value, upper)) }
}
