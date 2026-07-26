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

                if await core.leaseStore.isLeased(threadId: thread.id) {
                    throw DaemonHTTPError.conflict(code: "thread_leased", message: "The app is currently attached to this thread's runtime.")
                }

                let alreadyBusy = await core.runQueue.isThreadBusy(thread.id)
                let job = RunJob(
                    id: "run_\(UUID().uuidString)", scheduleId: nil, trigger: .api,
                    target: .existingThread(threadId: thread.id, path: thread.path, cwd: thread.cwd),
                    prompt: text, mode: nil, timeoutSeconds: ScheduleEngine.defaultTimeoutSeconds, queuedAt: Date()
                )
                await core.runQueue.enqueue(job)
                // Real steering into an already-running daemon session is not implemented (see
                // the top-level report): a busy thread's message queues behind the current run
                // rather than interrupting it, regardless of `delivery`.
                return .json(SendMessageResponse(runId: job.id, queued: alreadyBusy))
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
                guard let refreshed = await core.threadStore.thread(idOrPath: thread.id) else { throw DaemonHTTPError.notFound("Thread \(thread.id)") }
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

    private static func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "1", "yes": true
        case "false", "0", "no": false
        default: nil
        }
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int { max(lower, min(value, upper)) }
}
