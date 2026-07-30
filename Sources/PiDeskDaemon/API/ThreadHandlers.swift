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

            // Existing checkouts of the repository a folder belongs to, so a new thread can be
            // started in one of them. Discovery only: this never creates or removes a worktree.
            Route("GET", "/v1/worktrees") { request, _ in
                let directory = try existingDirectory(request.query["cwd"])
                // `git` is a blocking child process; keeping it off the cooperative pool means a
                // slow repository cannot stall unrelated requests.
                let worktrees = await Task.detached(priority: .utility) { GitWorktrees.list(for: directory) }.value
                return .json(WorktreeListResponse(worktrees: worktrees))
            },

            Route("POST", "/v1/threads") { request, _ in
                let body = try request.decodeJSON(CreateThreadRequest.self)
                let cwdURL = try existingDirectory(body.cwd)
                let thread: PiThread
                do {
                    // Resolve the real Pi session before responding. A `pending:<run>` id is not
                    // a thread and made the web client navigate straight into a guaranteed 404.
                    thread = try await core.threadRPC.createIdle(cwd: cwdURL, name: body.name)
                } catch let error as RunnerError {
                    throw DaemonHTTPError.conflict(code: "create_failed", message: error.localizedDescription)
                }

                guard let message = body.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
                    return .json(CreateThreadResponse(thread: thread, runId: nil), status: 201)
                }

                let job = RunJob(
                    id: "run_\(UUID().uuidString)", scheduleId: nil, trigger: .api,
                    target: .existingThread(threadId: thread.id, path: thread.path, cwd: thread.cwd),
                    prompt: message, mode: body.mode, timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date()
                )
                await core.runQueue.enqueue(job)
                return .json(CreateThreadResponse(thread: thread, runId: job.id), status: 202)
            },

            Route("GET", "/v1/threads/:id/runtime") { _, params in
                let thread = try await requireThread(core, params)
                return .json(ThreadRuntimeResponse(runtime: try await runtimeState(core, thread: thread)))
            },

            Route("POST", "/v1/threads/:id/runtime/model") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(SetThreadModelRequest.self)
                let provider = try boundedRuntimeValue(body.provider, field: "provider")
                let modelId = try boundedRuntimeValue(body.modelId, field: "modelId")
                let runtime = try await mutateRuntime(core, thread: thread) { target, running in
                    try await ThreadRuntimeCommands.setModel(
                        using: target, provider: provider, modelId: modelId, running: running
                    )
                } idle: {
                    try await core.threadRPC.setModel(
                        cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path),
                        provider: provider, modelId: modelId
                    )
                }
                return .json(ThreadRuntimeResponse(runtime: runtime))
            },

            Route("POST", "/v1/threads/:id/runtime/thinking") { request, params in
                let thread = try await requireThread(core, params)
                let body = try request.decodeJSON(SetThreadThinkingRequest.self)
                let level = try boundedRuntimeValue(body.level, field: "level", max: 64)
                let runtime = try await mutateRuntime(core, thread: thread) { target, running in
                    try await ThreadRuntimeCommands.setThinkingLevel(using: target, level: level, running: running)
                } idle: {
                    try await core.threadRPC.setThinkingLevel(
                        cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path), level: level
                    )
                }
                return .json(ThreadRuntimeResponse(runtime: runtime))
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
                // The daemon owns its overlay, never the app's `state.json`, so the merge is a
                // union: a thread the app archived stays archived whatever is written here.
                // Reporting that as a restore would be a success the caller never got.
                if !body.archived, updated.archived {
                    throw DaemonHTTPError.conflict(
                        code: "archived_in_app",
                        message: "This thread was archived in the Mac app; restore it there."
                    )
                }
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
                do {
                    try await core.threadRPC.rename(cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path), name: clean)
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
                guard let lease = await core.leaseStore.acquireIfAvailable(
                    threadId: thread.id, owner: body.owner, ttlSeconds: body.ttlSeconds
                ) else {
                    throw DaemonHTTPError.conflict(
                        code: "thread_leased", message: "Another runtime is already attached to this thread."
                    )
                }
                return .json(LeaseResponse(leased: true, owner: lease.owner, expiresAt: lease.expiresAt))
            }
        ]
    }

    /// A caller-supplied directory path: tilde-expanded, required to exist, and required to be a
    /// directory rather than a file.
    private static func existingDirectory(_ raw: String?) throws -> URL {
        // Trim before expanding: `expandingTildeInPath` only fires on a leading `~`, so a padded
        // " ~/code" would otherwise be taken literally.
        let path = ((raw ?? "").trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DaemonHTTPError.badRequest(code: "invalid_cwd", message: "cwd must be an existing directory.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func runtimeState(_ core: DaemonCore, thread: PiThread) async throws -> ThreadRuntimeState {
        try await mutateRuntime(core, thread: thread) { target, running in
            try await ThreadRuntimeCommands.snapshot(using: target, running: running)
        } idle: {
            try await core.threadRPC.runtimeSnapshot(
                cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path)
            )
        }
    }

    /// Prefer the daemon's already-running Pi process. Otherwise reserve the idle thread in the
    /// run queue while a short-lived setter/query session is attached.
    private static func mutateRuntime(
        _ core: DaemonCore,
        thread: PiThread,
        live: @Sendable (RuntimeRequesting, Bool) async throws -> ThreadRuntimeState,
        idle: @Sendable () async throws -> ThreadRuntimeState
    ) async throws -> ThreadRuntimeState {
        if await core.leaseStore.isLeased(threadId: thread.id) {
            throw DaemonHTTPError.conflict(
                code: "thread_leased", message: "The app is currently attached to this thread's runtime."
            )
        }

        do {
            if let state = try await core.liveSessions.withRuntime(threadID: thread.id, operation: { target in
                try await live(target, true)
            }) {
                return state
            }
        } catch {
            throw DaemonHTTPError.conflict(code: "runtime_failed", message: runtimeErrorMessage(error))
        }

        guard !thread.running, await core.runQueue.reserveRuntime(threadID: thread.id) else {
            throw DaemonHTTPError.conflict(code: "thread_busy", message: "Runtime controls are temporarily busy. Try again in a moment.")
        }
        let leaseOwner = "web-runtime-\(UUID().uuidString)"
        guard await core.leaseStore.acquireIfAvailable(
            threadId: thread.id, owner: leaseOwner, ttlSeconds: 180
        ) != nil else {
            await core.runQueue.releaseRuntime(threadID: thread.id)
            throw DaemonHTTPError.conflict(
                code: "thread_leased", message: "The app is currently attached to this thread's runtime."
            )
        }

        do {
            let state = try await idle()
            await core.leaseStore.release(threadId: thread.id, owner: leaseOwner)
            await core.runQueue.releaseRuntime(threadID: thread.id)
            return state
        } catch {
            await core.leaseStore.release(threadId: thread.id, owner: leaseOwner)
            await core.runQueue.releaseRuntime(threadID: thread.id)
            throw DaemonHTTPError.conflict(code: "runtime_failed", message: runtimeErrorMessage(error))
        }
    }

    private static func boundedRuntimeValue(_ raw: String, field: String, max: Int = 256) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= max else {
            throw DaemonHTTPError.badRequest(
                code: "invalid_\(field.lowercased())", message: "\(field) must be 1-\(max) characters."
            )
        }
        return value
    }

    private static func runtimeErrorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Pi could not update this runtime."
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
