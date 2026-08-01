import Foundation
import PatchworkKit

private actor PromptBackedCreationResolution {
    enum Outcome: Sendable {
        case created(CreateThreadResponse)
        case failed(String, retryable: Bool)
        case outcomeUnknown(String)
    }

    private enum Phase {
        case pending
        case resolving
        case resolved(Outcome)
    }

    private var phase: Phase = .pending
    private var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]

    func claimResolution() -> Bool {
        guard case .pending = phase else { return false }
        phase = .resolving
        return true
    }

    func finish(_ outcome: Outcome) {
        guard case .resolving = phase else { return }
        phase = .resolved(outcome)
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: outcome) }
    }

    func wait(timeoutNanoseconds: UInt64) async -> Outcome? {
        if case let .resolved(outcome) = phase { return outcome }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.expireWaiter(id)
            }
        }
    }

    private func expireWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

enum ThreadHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/threads") { request, _ in
                let limit = clamp(request.query["limit"].flatMap(Int.init) ?? 50, 1, 200)
                let automatedIDs = Set(await core.scheduleStore.all().compactMap(\.target.existingThreadID))
                let (threads, next) = try await core.threadStore.listThreads(
                    query: request.query["query"],
                    limit: limit,
                    cursor: request.query["cursor"],
                    archived: request.query["archived"].flatMap(parseBool),
                    running: request.query["running"].flatMap(parseBool),
                    automated: request.query["automated"].flatMap(parseBool),
                    automatedThreadIDs: automatedIDs,
                    agent: try parseAgentFilter(request.query["agent"]),
                    sidebar: request.query["sidebar"].flatMap(parseBool) ?? false
                )
                return .json(ThreadListResponse(threads: threads, nextCursor: next))
            },

            Route("GET", "/v1/threads/:id") { request, params in
                let thread = try await requireThread(core, params)
                let limit = clamp(request.query["messages"].flatMap(Int.init) ?? 20, 0, 500)
                let offset = clamp(request.query["offset"].flatMap(Int.init) ?? 0, 0, 5_000)
                let includeTools = request.query["all"].flatMap(parseBool) ?? true
                let page = (try? SessionThreadParser.messagePage(
                    at: URL(fileURLWithPath: thread.path), limit: limit, offset: offset,
                    conversationOnly: !includeTools, transcoder: .make(for: thread.agent)
                )) ?? (messages: [], nextOffset: nil)
                return .json(ThreadDetailResponse(
                    thread: thread, messages: page.messages, nextOffset: page.nextOffset
                ))
            },

            // Image bytes never travel inside a thread detail: one screenshot-heavy transcript
            // would blow past the hosted relay's 1.5 MB encrypted-payload ceiling. `Message.images`
            // carries metadata, and each image is fetched here, one bounded response at a time.
            Route("GET", "/v1/threads/:id/images/:imageId") { _, params in
                let thread = try await requireThread(core, params)
                guard let imageId = params["imageId"], !imageId.isEmpty else {
                    throw DaemonHTTPError.badRequest(code: "missing_image_id", message: "Missing image id.")
                }
                let image = (try? SessionThreadParser.image(
                    at: URL(fileURLWithPath: thread.path), imageId: imageId,
                    transcoder: .make(for: thread.agent)
                )) ?? nil
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
                let requestedAgent = try request.decodeKnownAgent()
                let body = try request.decodeJSON(CreateThreadRequest.self)
                let agent = requestedAgent ?? .pi
                let name = try boundedOptionalValue(body.name, field: "name", maxBytes: 256)
                let mode = try boundedOptionalValue(body.mode, field: "mode", maxBytes: 256)
                if mode != nil, agent != .pi {
                    throw DaemonHTTPError.badRequest(
                        code: "mode_not_supported",
                        message: "The mode field is only supported for Pi threads."
                    )
                }
                let message = body.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstMessage = message.flatMap { $0.isEmpty ? nil : $0 }
                let clientID = try validatedClientID(body.clientId)
                var creationOwnership: SubmissionRegistry.Ownership?
                if let clientID {
                    // Replay lookup must not depend on mutable machine state. A completed request
                    // remains replayable if its folder is later removed or its agent uninstalled.
                    let projectPath = normalizedDirectoryPath(body.cwd)
                    let fingerprint = SubmissionRegistry.fingerprint(parts: [
                        "creation", projectPath, name ?? "",
                        firstMessage ?? "", mode ?? "", body.worktree == true ? "1" : "0",
                        agent.rawValue, body.desktopManaged == true ? "1" : "0"
                    ])
                    switch await core.submissions.claimCreation(
                        clientID: clientID, requestFingerprint: fingerprint
                    ) {
                    case let .replay(response):
                        return .json(response, status: creationStatus(response))
                    case .inFlight:
                        if let response = await core.submissions.waitForCreation(clientID: clientID) {
                            return .json(response, status: creationStatus(response))
                        }
                        if await core.submissions.creationOutcomeIsUnknown(
                            clientID: clientID, requestFingerprint: fingerprint
                        ) {
                            throw DaemonHTTPError.conflict(
                                code: "creation_outcome_unknown",
                                message: "A thread may already have been created. Review the thread list before retrying."
                            )
                        }
                        throw DaemonHTTPError.conflict(
                            code: "creation_in_flight",
                            message: "This thread is already being created."
                        )
                    case .outcomeUnknown:
                        throw DaemonHTTPError.conflict(
                            code: "creation_outcome_unknown",
                            message: "A thread may already have been created before the service restarted. Review the thread list before retrying."
                        )
                    case .conflict:
                        throw DaemonHTTPError.conflict(
                            code: "creation_id_conflict",
                            message: "This clientId already belongs to a different create request."
                        )
                    case .overloaded:
                        throw DaemonHTTPError.serviceUnavailable(
                            code: "creations_busy",
                            message: "The protected replay ledger is full. Retry after an older entry expires."
                        )
                    case let .unavailable(message):
                        throw DaemonHTTPError.serviceUnavailable(
                            code: "submission_ledger_unavailable", message: message
                        )
                    case let .proceed(owner): creationOwnership = owner
                    }
                }
                if firstMessage == nil, !agent.capabilities.persistsSessionBeforeFirstPrompt {
                    if let clientID, let creationOwnership {
                        await core.submissions.abandonCreation(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    throw DaemonHTTPError.badRequest(
                        code: "first_message_required",
                        message: "\(agent.displayName) creates its conversation file with the first message. Pass a non-empty message."
                    )
                }
                if firstMessage != nil, clientID == nil {
                    throw DaemonHTTPError.badRequest(
                        code: "client_id_required",
                        message: "A first message requires clientId so a lost create response cannot send it twice."
                    )
                }
                let projectURL: URL
                do {
                    try requireInstalled(core, agent)
                    projectURL = try existingDirectory(body.cwd)
                } catch {
                    if let clientID, let creationOwnership {
                        await core.submissions.abandonCreation(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    throw error
                }
                let reservation: RunQueue.Reservation?
                if let firstMessage {
                    switch await core.runQueue.reserve(prompt: firstMessage, mode: mode) {
                    case let .reserved(value):
                        reservation = value
                    case let .rejected(code, message):
                        if let clientID, let creationOwnership {
                            await core.submissions.abandonCreation(
                                clientID: clientID, ownership: creationOwnership
                            )
                        }
                        try requireAdmission(.rejected(code: code, message: message))
                        reservation = nil
                    }
                } else {
                    reservation = nil
                }
                let worktreeURL: URL?
                if body.worktree == true {
                    switch await WorktreeService.create(from: projectURL, root: core.worktreeRootURL) {
                    case let .success(url): worktreeURL = url
                    case let .failure(error):
                        if let reservation { await core.runQueue.cancelReservation(reservation) }
                        if let clientID, let creationOwnership {
                            await core.submissions.abandonCreation(
                                clientID: clientID, ownership: creationOwnership
                            )
                        }
                        throw DaemonHTTPError.badRequest(code: "worktree_failed", message: error.message)
                    }
                } else {
                    worktreeURL = nil
                }
                let executionURL = worktreeURL ?? projectURL
                if !agent.capabilities.persistsSessionBeforeFirstPrompt {
                    guard let firstMessage, let reservation else {
                        throw DaemonHTTPError.badRequest(
                            code: "first_message_required",
                            message: "A first message is required for this agent."
                        )
                    }
                    return try await createPromptBackedThread(
                        core: core, agent: agent, projectURL: projectURL,
                        executionURL: executionURL, worktreeURL: worktreeURL,
                        name: name, firstMessage: firstMessage, mode: mode,
                        reservation: reservation, clientID: clientID,
                        creationOwnership: creationOwnership,
                        desktopManaged: body.desktopManaged == true
                    )
                }
                var thread: PatchworkThread
                do {
                    // Resolve the real session before responding. A `pending:<run>` id is not
                    // a thread and made the web client navigate straight into a guaranteed 404.
                    thread = try await core.threadRPC.createIdle(agent: agent, cwd: executionURL, name: name)
                } catch let error as ThreadCreationError {
                    if let reservation { await core.runQueue.cancelReservation(reservation) }
                    await retainPromptBackedWorktreeMapping(
                        core: core, projectURL: projectURL, worktreeURL: worktreeURL
                    )
                    if let clientID, let creationOwnership {
                        await core.submissions.markCreationOutcomeUnknown(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    throw DaemonHTTPError.conflict(
                        code: "creation_outcome_unknown", message: error.localizedDescription
                    )
                } catch {
                    if let reservation { await core.runQueue.cancelReservation(reservation) }
                    if let worktreeURL {
                        _ = await WorktreeService.remove(at: worktreeURL, root: core.worktreeRootURL)
                    }
                    if let clientID, let creationOwnership {
                        await core.submissions.abandonCreation(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    if let error = error as? RunnerError {
                        throw DaemonHTTPError.conflict(code: "create_failed", message: error.localizedDescription)
                    }
                    throw error
                }
                thread.shortId = PatchworkThread.abbreviatedID(for: thread.id)
                if let worktreeURL {
                    thread.project = projectURL.path
                    thread.worktree = worktreeURL.path
                    do {
                        try await core.threadStore.setManagedWorktreeProject(projectURL, for: worktreeURL)
                    } catch {
                        core.logger.warn("Created thread \(thread.id), but could not save its worktree project mapping: \(error)")
                    }
                }
                do {
                    if body.desktopManaged == true {
                        try await core.threadStore.recordDesktopStartedThread(path: thread.path)
                    } else {
                        try await core.threadStore.recordManagedThread(path: thread.path)
                    }
                } catch {
                    if let reservation { await core.runQueue.cancelReservation(reservation) }
                    thread = await core.threadStore.presentCreatedThread(thread)
                    if let clientID, let creationOwnership {
                        await core.submissions.markCreationOutcomeUnknown(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    core.logger.error(
                        "Created thread \(thread.id), but could not durably save its desktop ownership: \(error)"
                    )
                    throw DaemonHTTPError.conflict(
                        code: "creation_outcome_unknown",
                        message: "The conversation exists, but its desktop ownership could not be saved. Review the thread list before retrying."
                    )
                }
                thread = await core.threadStore.presentCreatedThread(thread)
                core.bus.publish(.thread(thread))

                guard let firstMessage else {
                    let response = CreateThreadResponse(thread: thread, runId: nil)
                    if let clientID, let creationOwnership {
                        await core.submissions.completeCreation(
                            clientID: clientID, ownership: creationOwnership, response: response
                        )
                    }
                    return .json(response, status: 201)
                }

                let job = RunJob(
                    id: "run_\(UUID().uuidString)", scheduleId: nil, trigger: .api,
                    target: .existingThread(threadId: thread.id, path: thread.path, cwd: thread.cwd, agent: thread.agent),
                    prompt: firstMessage, mode: mode, timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date()
                )
                let admission = await core.runQueue.enqueue(job, reservation: reservation)
                if case let .rejected(_, message) = admission {
                    // Creation already crossed the agent-owned transcript boundary. Reporting a
                    // total request failure would encourage a retry that creates an orphaned
                    // duplicate thread, so return the real thread and preserve the unsent text.
                    let response = CreateThreadResponse(
                        thread: thread, runId: nil, firstMessageError: message
                    )
                    if let clientID, let creationOwnership {
                        await core.submissions.completeCreation(
                            clientID: clientID, ownership: creationOwnership, response: response
                        )
                    }
                    return .json(response, status: 201)
                }
                let response = CreateThreadResponse(thread: thread, runId: job.id)
                if let clientID, let creationOwnership {
                    await core.submissions.completeCreation(
                        clientID: clientID, ownership: creationOwnership, response: response
                    )
                }
                return .json(response, status: 202)
            },

            Route("GET", "/v1/threads/:id/runtime") { _, params in
                let thread = try await requireThread(core, params)
                return .json(ThreadRuntimeResponse(runtime: try await runtimeState(core, thread: thread)))
            },

            Route("POST", "/v1/threads/:id/runtime/model") { request, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                let body = try request.decodeJSON(SetThreadModelRequest.self)
                let provider = try boundedRuntimeValue(body.provider, field: "provider")
                let modelId = try boundedRuntimeValue(body.modelId, field: "modelId")
                let runtime = try await mutateRuntime(core, thread: thread) { target, running in
                    try await ThreadRuntimeCommands.setModel(
                        using: target, provider: provider, modelId: modelId, running: running
                    )
                } idle: {
                    try await core.threadRPC.setModel(
                        agent: thread.agent,
                        cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path),
                        provider: provider, modelId: modelId
                    )
                }
                return .json(ThreadRuntimeResponse(runtime: runtime))
            },

            Route("POST", "/v1/threads/:id/runtime/thinking") { request, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                guard [.live, .nextTurn].contains(thread.agent.capabilities.thinking) else {
                    throw DaemonHTTPError.conflict(
                        code: "capability_not_supported",
                        message: "\(thread.agent.displayName) cannot change thinking through this remote runtime."
                    )
                }
                let body = try request.decodeJSON(SetThreadThinkingRequest.self)
                let level = try boundedRuntimeValue(body.level, field: "level", max: 64)
                let runtime = try await mutateRuntime(core, thread: thread) { target, running in
                    try await ThreadRuntimeCommands.setThinkingLevel(using: target, level: level, running: running)
                } idle: {
                    try await core.threadRPC.setThinkingLevel(
                        agent: thread.agent,
                        cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path),
                        level: level
                    )
                }
                return .json(ThreadRuntimeResponse(runtime: runtime))
            },

            Route("POST", "/v1/threads/:id/messages") { request, params in
                guard let threadReference = params["id"], !threadReference.isEmpty else {
                    throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing thread id.")
                }
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

                // A lost response is the common failure on a phone, and the natural reaction is to
                // retry. Without this, that retry prompts Pi a second time. `clientId` makes the
                // whole endpoint replayable: the same pair returns the same answer and does not
                // deliver or enqueue anything again.
                let clientID = try validatedClientID(body.clientId)
                let requestFingerprint = clientID.map { _ in
                    SubmissionRegistry.fingerprint(parts: [
                        "message", text, (body.delivery ?? .auto).rawValue
                    ])
                }
                if let clientID, let requestFingerprint,
                   let located = await core.submissions.lookupMessage(
                    reference: threadReference, clientID: clientID,
                    requestFingerprint: requestFingerprint
                   ) {
                    switch try await resolveMessageClaim(
                        core, thread: located.thread, clientID: clientID,
                        claim: located.claim
                    ) {
                    case let .response(response): return .json(response)
                    case .proceed:
                        throw DaemonHTTPError.serviceUnavailable(
                            code: "submission_ledger_unavailable",
                            message: "An existing replay claim was not readable safely."
                        )
                    }
                }

                if let rejection = await core.runQueue.validatePayload(prompt: text, mode: nil) {
                    try requireAdmission(rejection)
                }
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                let threadKey = ThreadInstanceKey(path: thread.path)
                var ownership: SubmissionRegistry.Ownership?
                if let clientID, let requestFingerprint {
                    let claim = await core.submissions.claim(
                        thread: threadKey, clientID: clientID,
                        requestFingerprint: requestFingerprint,
                        messageAliases: [thread.id, threadReference]
                    )
                    switch try await resolveMessageClaim(
                        core, thread: threadKey, clientID: clientID, claim: claim
                    ) {
                    case let .response(response): return .json(response)
                    case let .proceed(value): ownership = value
                    }
                }

                // Existing claims replay independently of today's lease. Only a genuinely new
                // delivery has to prove that no other process currently owns the transcript.
                if await core.leaseStore.isLeased(thread: threadKey) {
                    if let clientID, let ownership {
                        await core.submissions.abandon(
                            thread: threadKey, clientID: clientID, ownership: ownership
                        )
                    }
                    throw DaemonHTTPError.conflict(code: "thread_leased", message: "The app is currently attached to this thread's runtime.")
                }

                do {
                    if thread.archived {
                        let restored = try await core.threadStore.setArchived(false, idOrPath: thread.path)
                        if restored.archived {
                            throw DaemonHTTPError.conflict(
                                code: "archived_in_app",
                                message: "This thread was archived in the Mac app; restore it there."
                            )
                        }
                        core.bus.publish(.thread(restored))
                    }
                    let response = try await deliverOrEnqueue(core, thread: thread, text: text, delivery: body.delivery)
                    if let clientID, let ownership {
                        await core.submissions.complete(
                            thread: threadKey, clientID: clientID,
                            ownership: ownership, response: response
                        )
                    }
                    return .json(response)
                } catch {
                    // Nothing was delivered or queued, so the claim must not lock out an honest
                    // retry of the same submission.
                    if let clientID, let ownership {
                        await core.submissions.abandon(
                            thread: threadKey, clientID: clientID, ownership: ownership
                        )
                    }
                    throw error
                }
            },

            Route("POST", "/v1/threads/:id/abort") { _, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                let aborted = await core.runQueue.abort(thread: ThreadInstanceKey(path: thread.path))
                return .json(AbortResponse(aborted: aborted))
            },

            Route("POST", "/v1/threads/:id/archive") { request, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                let body = try request.decodeJSON(ArchiveRequest.self)
                let updated = try await core.threadStore.setArchived(body.archived, idOrPath: thread.path)
                // The daemon owns its overlay, never the app's `state.json`, so the merge is a
                // union: a thread the app archived stays archived whatever is written here.
                // Reporting that as a restore would be a success the caller never got.
                if !body.archived, updated.archived {
                    throw DaemonHTTPError.conflict(
                        code: "archived_in_app",
                        message: "This thread was archived in the Mac app; restore it there."
                    )
                }
                core.bus.publish(.thread(updated))
                return .json(ThreadResponse(thread: updated))
            },

            Route("POST", "/v1/threads/:id/name") { request, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                guard thread.agent.capabilities.canRenameSession else {
                    throw DaemonHTTPError.conflict(
                        code: "capability_not_supported",
                        message: "\(thread.agent.displayName) cannot rename this conversation."
                    )
                }
                let body = try request.decodeJSON(NameRequest.self)
                let clean = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw DaemonHTTPError.badRequest(code: "empty_name", message: "name must not be empty.") }
                let threadKey = ThreadInstanceKey(path: thread.path)
                try requireInstalled(core, thread.agent)
                // Renaming goes through the agent's own rename command, so the agent appends the
                // record itself and this never touches a session file directly. An agent with no
                // rename command reports that rather than pretending to succeed.
                do {
                    try await withExclusiveIdleRuntime(core, threadKey: threadKey) {
                        try await core.threadRPC.rename(
                            agent: thread.agent,
                            cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path),
                            name: clean
                        )
                    }
                } catch let error as RunnerError {
                    throw DaemonHTTPError.conflict(code: "rename_failed", message: error.localizedDescription)
                }
                guard let refreshed = await core.threadStore.refreshedThread(idOrPath: thread.path) else { throw DaemonHTTPError.notFound("Thread \(thread.id)") }
                core.bus.publish(.thread(refreshed))
                return .json(ThreadResponse(thread: refreshed))
            },

            Route("POST", "/v1/threads/:id/read") { request, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                let body = try request.decodeJSON(ReadRequest.self)
                let updated = try await core.threadStore.setUnread(body.unread, idOrPath: thread.path)
                core.bus.publish(.thread(updated))
                return .json(ThreadResponse(thread: updated))
            },

            Route("POST", "/v1/threads/:id/lease") { request, params in
                let thread = try await requireThread(core, params, refreshingIdentifier: true)
                let body = try request.decodeJSON(LeaseRequest.self)
                let threadKey = ThreadInstanceKey(path: thread.path)
                if body.release == true {
                    await core.leaseStore.release(thread: threadKey, owner: body.owner)
                    return .json(LeaseResponse(leased: false, owner: nil, expiresAt: nil))
                }
                guard await core.runQueue.reserveRuntime(thread: threadKey) else {
                    throw DaemonHTTPError.conflict(
                        code: "thread_busy",
                        message: "A queued or running operation already owns this thread."
                    )
                }
                guard let lease = await core.leaseStore.acquireIfAvailable(
                    thread: threadKey, owner: body.owner, ttlSeconds: body.ttlSeconds
                ) else {
                    await core.runQueue.releaseRuntime(thread: threadKey)
                    throw DaemonHTTPError.conflict(
                        code: "thread_leased", message: "Another runtime is already attached to this thread."
                    )
                }
                await core.runQueue.releaseRuntime(thread: threadKey)
                return .json(LeaseResponse(leased: true, owner: lease.owner, expiresAt: lease.expiresAt))
            }
        ]
    }

    private static func createPromptBackedThread(
        core: DaemonCore,
        agent: AgentKind,
        projectURL: URL,
        executionURL: URL,
        worktreeURL: URL?,
        name: String?,
        firstMessage: String,
        mode: String?,
        reservation: RunQueue.Reservation,
        clientID: String?,
        creationOwnership: SubmissionRegistry.Ownership?,
        desktopManaged: Bool
    ) async throws -> HTTPResponse {
        let resolution = PromptBackedCreationResolution()
        let runID = "run_\(UUID().uuidString)"
        let job = RunJob(
            id: runID, scheduleId: nil, trigger: .api,
            target: .newThread(cwd: executionURL.path, namePattern: name, agent: agent),
            prompt: firstMessage, mode: mode,
            timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date(),
            onThreadReady: { threadID, path in
                guard await resolution.claimResolution() else { return }
                do {
                    let thread = try await materializePromptBackedThread(
                        agent: agent, expectedID: threadID, path: path,
                        expectedPrompt: firstMessage
                    )
                    let response = try await finalizePromptBackedCreation(
                        core: core, thread: thread, runID: runID,
                        projectURL: projectURL, worktreeURL: worktreeURL,
                        clientID: clientID, creationOwnership: creationOwnership,
                        desktopManaged: desktopManaged, running: true
                    )
                    await resolution.finish(.created(response))
                } catch {
                    let message = "The first message was accepted, but its conversation file could not be opened. Review the thread list before retrying."
                    await retainPromptBackedWorktreeMapping(
                        core: core, projectURL: projectURL, worktreeURL: worktreeURL
                    )
                    if let clientID, let creationOwnership {
                        await core.submissions.markCreationOutcomeUnknown(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    core.logger.error(
                        "Run \(runID) accepted its first message but could not materialize thread \(threadID): \(error)"
                    )
                    await resolution.finish(.outcomeUnknown(message))
                }
            },
            onCompletion: { outcome in
                if let path = outcome.resolvedThreadPath, !path.isEmpty {
                    await core.threadStore.markTranscriptSettled(path: path)
                }
                guard await resolution.claimResolution() else { return }
                let message = outcome.error ?? "The agent stopped before creating its conversation."
                if outcome.promptStartedAt == nil {
                    if let worktreeURL {
                        _ = await WorktreeService.remove(
                            at: worktreeURL, root: core.worktreeRootURL
                        )
                    }
                    if let clientID, let creationOwnership {
                        await core.submissions.abandonCreation(
                            clientID: clientID, ownership: creationOwnership
                        )
                    }
                    await resolution.finish(.failed(message, retryable: outcome.retryable))
                    return
                }

                if let threadID = outcome.resolvedThreadId,
                   let path = outcome.resolvedThreadPath,
                   let thread = try? await materializePromptBackedThread(
                    agent: agent, expectedID: threadID, path: path,
                    expectedPrompt: firstMessage
                   ) {
                    do {
                        let response = try await finalizePromptBackedCreation(
                            core: core, thread: thread, runID: runID,
                            projectURL: projectURL, worktreeURL: worktreeURL,
                            clientID: clientID, creationOwnership: creationOwnership,
                            desktopManaged: desktopManaged, running: false
                        )
                        await resolution.finish(.created(response))
                    } catch {
                        await retainPromptBackedWorktreeMapping(
                            core: core, projectURL: projectURL, worktreeURL: worktreeURL
                        )
                        if let clientID, let creationOwnership {
                            await core.submissions.markCreationOutcomeUnknown(
                                clientID: clientID, ownership: creationOwnership
                            )
                        }
                        core.logger.error(
                            "Run \(runID) materialized its conversation, but desktop ownership was not durable: \(error)"
                        )
                        await resolution.finish(.outcomeUnknown(
                            "The first message was accepted, but conversation ownership could not be saved. Review the thread list before retrying."
                        ))
                    }
                    return
                }

                await retainPromptBackedWorktreeMapping(
                    core: core, projectURL: projectURL, worktreeURL: worktreeURL
                )
                if let clientID, let creationOwnership {
                    await core.submissions.markCreationOutcomeUnknown(
                        clientID: clientID, ownership: creationOwnership
                    )
                }
                await resolution.finish(.outcomeUnknown(
                    "The first message may have been accepted, but the conversation could not be confirmed. Review the thread list before retrying."
                ))
            }
        )

        let admission = await core.runQueue.enqueue(job, reservation: reservation)
        if case .rejected = admission {
            if let worktreeURL {
                _ = await WorktreeService.remove(at: worktreeURL, root: core.worktreeRootURL)
            }
            if let clientID, let creationOwnership {
                await core.submissions.abandonCreation(
                    clientID: clientID, ownership: creationOwnership
                )
            }
            try requireAdmission(admission)
        }

        switch await resolution.wait(timeoutNanoseconds: 8_000_000_000) {
        case let .created(response):
            return .json(response, status: 202)
        case let .failed(message, retryable):
            if retryable {
                throw DaemonHTTPError.serviceUnavailable(
                    code: "create_retryable", message: message
                )
            }
            throw DaemonHTTPError.conflict(code: "create_failed", message: message)
        case let .outcomeUnknown(message):
            throw DaemonHTTPError.conflict(code: "creation_outcome_unknown", message: message)
        case nil:
            throw DaemonHTTPError.serviceUnavailable(
                code: "creation_pending",
                message: "The first message is waiting to create its conversation. Retry with the same clientId."
            )
        }
    }

    private static func materializePromptBackedThread(
        agent: AgentKind, expectedID: String, path: String, expectedPrompt: String
    ) async throws -> PatchworkThread {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var lastError: Error?
        for attempt in 0..<41 {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw RunnerError.ioFailure("The reported conversation file is still empty.")
                }
                var thread = try SessionThreadParser.thread(
                    at: url, transcoder: .make(for: agent)
                )
                guard thread.id == expectedID else {
                    throw RunnerError.ioFailure(
                        "The reported conversation id did not match its transcript."
                    )
                }
                let messages = try SessionThreadParser.messagePage(
                    at: url, limit: 500, offset: 0, conversationOnly: true,
                    transcoder: .make(for: agent)
                ).messages
                let expected = expectedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard messages.contains(where: {
                    $0.role == .user
                        && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
                }) else {
                    throw RunnerError.ioFailure(
                        "The conversation file does not contain the accepted first message yet."
                    )
                }
                thread.agent = agent
                thread.shortId = PatchworkThread.abbreviatedID(for: thread.id)
                return thread
            } catch {
                lastError = error
            }
            if attempt < 40 { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        throw lastError ?? RunnerError.ioFailure("The conversation file did not appear.")
    }

    private static func finalizePromptBackedCreation(
        core: DaemonCore,
        thread original: PatchworkThread,
        runID: String,
        projectURL: URL,
        worktreeURL: URL?,
        clientID: String?,
        creationOwnership: SubmissionRegistry.Ownership?,
        desktopManaged: Bool,
        running: Bool
    ) async throws -> CreateThreadResponse {
        var thread = original
        if let worktreeURL {
            thread.project = projectURL.standardizedFileURL.path
            thread.worktree = worktreeURL.standardizedFileURL.path
            await retainPromptBackedWorktreeMapping(
                core: core, projectURL: projectURL, worktreeURL: worktreeURL
            )
        }
        do {
            if desktopManaged {
                try await core.threadStore.recordDesktopStartedThread(path: thread.path)
            } else {
                try await core.threadStore.recordManagedThread(path: thread.path)
            }
        } catch {
            _ = await core.threadStore.presentCreatedThread(thread)
            throw error
        }
        thread = await core.threadStore.presentCreatedThread(
            thread, runningOverride: running
        )
        let response = CreateThreadResponse(thread: thread, runId: runID)
        if let clientID, let creationOwnership {
            await core.submissions.completeCreation(
                clientID: clientID, ownership: creationOwnership, response: response
            )
        }
        core.bus.publish(.thread(thread))
        return response
    }

    private static func retainPromptBackedWorktreeMapping(
        core: DaemonCore, projectURL: URL, worktreeURL: URL?
    ) async {
        guard let worktreeURL else { return }
        do {
            try await core.threadStore.setManagedWorktreeProject(projectURL, for: worktreeURL)
        } catch {
            core.logger.warn(
                "Could not save the source project for prompt-backed worktree \(worktreeURL.path): \(error)"
            )
        }
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

    /// The immutable form used in creation fingerprints. Unlike `existingDirectory`, this does
    /// not consult the filesystem, so a replay can be found after the original folder disappears.
    private static func normalizedDirectoryPath(_ raw: String?) -> String {
        let path = ((raw ?? "").trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// A thread's transcript outlives its agent's installation, so reading always works while
    /// driving needs the binary to still be there. Reported as a clear conflict rather than as a
    /// spawn failure deep inside a run.
    private static func requireInstalled(_ core: DaemonCore, _ agent: AgentKind) throws {
        guard !core.isAgentInstalled(agent) else { return }
        throw DaemonHTTPError.conflict(
            code: "agent_not_installed",
            message: RunnerError.agentNotFound(agent).localizedDescription
        )
    }

    private static func runtimeState(_ core: DaemonCore, thread: PatchworkThread) async throws -> ThreadRuntimeState {
        try await mutateRuntime(core, thread: thread) { target, running in
            try await ThreadRuntimeCommands.snapshot(using: target, running: running)
        } idle: {
            try await core.threadRPC.runtimeSnapshot(
                agent: thread.agent,
                cwd: URL(fileURLWithPath: thread.cwd), sessionPath: URL(fileURLWithPath: thread.path)
            )
        }
    }

    /// Prefer the daemon's already-running Pi process. Otherwise reserve the idle thread in the
    /// run queue while a short-lived setter/query session is attached.
    private static func mutateRuntime(
        _ core: DaemonCore,
        thread: PatchworkThread,
        live: @Sendable (RuntimeRequesting, Bool) async throws -> ThreadRuntimeState,
        idle: @Sendable () async throws -> ThreadRuntimeState
    ) async throws -> ThreadRuntimeState {
        // Every runtime route funnels through here, and the idle path launches the agent
        // against `thread.path`. The adapter makes that correct per agent; what still has to be
        // checked is that the agent is actually installed, since a thread's history outlives it.
        try requireInstalled(core, thread.agent)

        let threadKey = ThreadInstanceKey(path: thread.path)
        if await core.leaseStore.isLeased(thread: threadKey) {
            throw DaemonHTTPError.conflict(
                code: "thread_leased", message: "The app is currently attached to this thread's runtime."
            )
        }

        do {
            if let state = try await core.liveSessions.withRuntime(
                thread: ThreadInstanceKey(path: thread.path), operation: { target in
                try await live(target, true)
            }) {
                return state
            }
        } catch {
            throw DaemonHTTPError.conflict(code: "runtime_failed", message: runtimeErrorMessage(error))
        }

        guard !thread.running else {
            throw DaemonHTTPError.conflict(code: "thread_busy", message: "Runtime controls are temporarily busy. Try again in a moment.")
        }

        do {
            return try await withExclusiveIdleRuntime(core, threadKey: threadKey, operation: idle)
        } catch let error as DaemonHTTPError {
            throw error
        } catch {
            throw DaemonHTTPError.conflict(code: "runtime_failed", message: runtimeErrorMessage(error))
        }
    }

    /// Atomically excludes queued runs, native attachments, and other short-lived RPC sessions.
    /// Queue reservation and lease admission overlap so neither side can slip through the other's
    /// actor hop.
    private static func withExclusiveIdleRuntime<T: Sendable>(
        _ core: DaemonCore,
        threadKey: ThreadInstanceKey,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard await core.runQueue.reserveRuntime(thread: threadKey) else {
            throw DaemonHTTPError.conflict(
                code: "thread_busy", message: "Runtime controls are temporarily busy. Try again in a moment."
            )
        }
        let owner = "web-runtime-\(UUID().uuidString)"
        guard await core.leaseStore.acquireIfAvailable(
            thread: threadKey, owner: owner, ttlSeconds: 180
        ) != nil else {
            await core.runQueue.releaseRuntime(thread: threadKey)
            throw DaemonHTTPError.conflict(
                code: "thread_leased", message: "The app is currently attached to this thread's runtime."
            )
        }

        do {
            let result = try await operation()
            await core.leaseStore.release(thread: threadKey, owner: owner)
            await core.runQueue.releaseRuntime(thread: threadKey)
            return result
        } catch {
            await core.leaseStore.release(thread: threadKey, owner: owner)
            await core.runQueue.releaseRuntime(thread: threadKey)
            throw error
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

    private static func boundedOptionalValue(
        _ raw: String?, field: String, maxBytes: Int
    ) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.lengthOfBytes(using: .utf8) <= maxBytes else {
            throw DaemonHTTPError.payloadTooLarge(
                code: "\(field)_too_large",
                message: "\(field) exceeds the \(maxBytes)-byte limit."
            )
        }
        return value
    }

    private static func runtimeErrorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Pi could not update this runtime."
    }

    private static func requireThread(
        _ core: DaemonCore,
        _ params: [String: String],
        refreshingIdentifier: Bool = false
    ) async throws -> PatchworkThread {
        guard let id = params["id"], !id.isEmpty else {
            throw DaemonHTTPError.badRequest(code: "missing_id", message: "Missing thread id.")
        }
        let resolved = if refreshingIdentifier {
            try await core.threadStore.resolveForMutation(idOrPath: id)
        } else {
            try await core.threadStore.resolve(idOrPath: id)
        }
        guard var thread = resolved else {
            throw DaemonHTTPError.notFound("Thread \(id)")
        }
        thread.shortId = PatchworkThread.abbreviatedID(for: thread.id)
        thread.automated = await core.scheduleStore.all().contains(where: {
            $0.target.existingThreadID == thread.id
        }) ? true : nil
        return thread
    }

    /// An explicit steer/follow-up is delivered into the live Pi turn or not at all: it is never
    /// quietly turned into a queued prompt, because "steer" that actually waits for the current
    /// run to finish is exactly the lie this endpoint used to tell. When nothing is live the
    /// response says so (`delivery: auto`) and the text becomes an ordinary prompt.
    private static func deliverOrEnqueue(
        _ core: DaemonCore, thread: PatchworkThread, text: String, delivery: DeliveryMode?
    ) async throws -> SendMessageResponse {
        // Not every agent can fold a message into the turn already running. Asking one that
        // cannot to `steer` would have it queue the message anyway while this endpoint reported
        // it as steered, so the request is downgraded here and the response says what happened.
        let delivery = effectiveDelivery(delivery, for: thread.agent)
        if let command = liveCommand(for: delivery),
           let delivered = await core.liveSessions.deliver(
               thread: ThreadInstanceKey(path: thread.path), command: command, message: text
           ) {
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

        let job = RunJob(
            id: "run_\(UUID().uuidString)", scheduleId: nil, trigger: .api,
            target: .existingThread(threadId: thread.id, path: thread.path, cwd: thread.cwd, agent: thread.agent),
            prompt: text, mode: nil, timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date()
        )
        let admission = await core.runQueue.enqueue(job)
        try requireAdmission(admission)
        return SendMessageResponse(runId: job.id, queued: admission == .queued, delivery: .auto)
    }

    private static func requireAdmission(_ admission: RunQueue.Admission) throws {
        guard case let .rejected(code, message) = admission else { return }
        if code == "prompt_too_large" {
            throw DaemonHTTPError.payloadTooLarge(code: code, message: message)
        }
        throw DaemonHTTPError.serviceUnavailable(code: code, message: message)
    }

    private enum MessageClaimResolution {
        case response(SendMessageResponse)
        case proceed(SubmissionRegistry.Ownership)
    }

    private static func resolveMessageClaim(
        _ core: DaemonCore,
        thread: ThreadInstanceKey,
        clientID: String,
        claim: SubmissionRegistry.Claim
    ) async throws -> MessageClaimResolution {
        switch claim {
        case let .replay(response):
            return .response(response)
        case .inFlight:
            if let response = await core.submissions.waitForCompletion(
                thread: thread, clientID: clientID
            ) {
                return .response(response)
            }
            throw DaemonHTTPError.conflict(
                code: "submission_in_flight",
                message: "This message is already being sent."
            )
        case .outcomeUnknown:
            throw DaemonHTTPError.conflict(
                code: "submission_outcome_unknown",
                message: "This message may already have been sent before the service restarted. Review the thread before retrying."
            )
        case .conflict:
            throw DaemonHTTPError.conflict(
                code: "submission_id_conflict",
                message: "This clientId already belongs to a different message. Review the thread and use a new id for a new message."
            )
        case .overloaded:
            throw DaemonHTTPError.serviceUnavailable(
                code: "submissions_busy",
                message: "The protected replay ledger is full. Retry after an older entry expires."
            )
        case let .unavailable(message):
            throw DaemonHTTPError.serviceUnavailable(
                code: "submission_ledger_unavailable", message: message
            )
        case let .proceed(ownership):
            return .proceed(ownership)
        }
    }

    private static func creationStatus(_ response: CreateThreadResponse) -> Int {
        response.runId == nil ? 201 : 202
    }

    /// A client-chosen id, so it is untrusted input: bounded in length and restricted to characters
    /// that cannot collide with the registry's own key separator. Absent means "not replayable",
    /// which is what an older client sends.
    private static func validatedClientID(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard (1...128).contains(raw.utf8.count), raw.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DaemonHTTPError.badRequest(
                code: "invalid_client_id",
                message: "clientId must be 1-128 letters, numbers, dashes, or underscores."
            )
        }
        return raw
    }

    /// Downgrades a delivery an agent cannot honour, so the response never claims a message was
    /// steered into a turn that was actually only queued behind it.
    private static func effectiveDelivery(_ requested: DeliveryMode?, for agent: AgentKind) -> DeliveryMode? {
        guard requested == .steer, !agent.capabilities.canSteerMidTurn else { return requested }
        return .followUp
    }

    /// The agent's own verb for a delivery mode, or `nil` when the caller did not ask for one (so
    /// the message is an ordinary prompt and belongs in the queue).
    private static func liveCommand(for delivery: DeliveryMode?) -> String? {
        switch delivery {
        case .steer: "steer"
        case .followUp: "follow_up"
        case .auto, nil: nil
        }
    }

    /// A filter value the daemon does not know is the caller's mistake, so it is rejected with the
    /// list of valid agents rather than silently listing everything (which would look like the
    /// filter worked). Unknown agents *in stored data* still degrade to Pi \u2014 see `AgentKind`.
    private static func parseAgentFilter(_ raw: String?) throws -> AgentKind? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let agent = AgentKind(rawValue: raw.lowercased()) else {
            throw DaemonHTTPError.badRequest(
                code: "invalid_agent",
                message: "agent must be one of: \(AgentKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return agent
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
