import Darwin
import Foundation
import PiDeskKit

/// The thread-scoped RPC work handlers need without owning or retaining a Pi process.
/// Short-lived agent sessions for the control-plane's own commands. Every method takes the
/// thread's agent: the executable and the protocol both follow from it, and defaulting it would
/// mean a mis-threaded call silently attached Pi to another agent's transcript.
protocol ThreadRPCServing: Sendable {
    func createIdle(agent: AgentKind, cwd: URL, name: String?) async throws -> PiThread
    func rename(agent: AgentKind, cwd: URL, sessionPath: URL, name: String) async throws
    func runtimeSnapshot(agent: AgentKind, cwd: URL, sessionPath: URL) async throws -> ThreadRuntimeState
    func setModel(agent: AgentKind, cwd: URL, sessionPath: URL, provider: String, modelId: String) async throws -> ThreadRuntimeState
    func setThinkingLevel(agent: AgentKind, cwd: URL, sessionPath: URL, level: String) async throws -> ThreadRuntimeState
}

/// The materialization command may have reached the agent even when its acknowledgement did not
/// reach us. Callers must preserve replay protection and any worktree until the transcript can be
/// reconciled instead of treating this as a definite pre-creation failure.
enum ThreadCreationError: Error, LocalizedError, Sendable {
    case outcomeUnknown(agent: AgentKind, sessionReference: String)

    var errorDescription: String? {
        switch self {
        case let .outcomeUnknown(agent, sessionReference):
            return "\(agent.displayName) may have created conversation \(sessionReference), but its acknowledgement was lost and the transcript could not be confirmed. Review the thread list before retrying."
        }
    }
}

/// A command target whose stdout has exactly one owner. Detached runtimes read their own pipe;
/// live runtimes collect responses from the run loop's bounded cache.
protocol RuntimeRequesting: Sendable {
    func request(type: String, payload: [String: PiJSONValue]) async throws -> PiJSONValue
}

private struct DetachedRuntimeRequester: RuntimeRequesting {
    let session: PiRPCSession

    func request(type: String, payload: [String: PiJSONValue] = [:]) async throws -> PiJSONValue {
        let id = try session.send(type: type, payload: payload)
        return try await session.receiveMatching(id: id, timeout: 30)
    }
}

/// Short-lived RPC sessions used for idle thread creation, rename, and runtime controls. None of
/// these commands sends a provider prompt.
struct ThreadCreationService: ThreadRPCServing {
    static let initialNameByteLimit = 256
    static let defaultIdleName = "Untitled conversation"
    static let piReservationFilenamePrefix = "pidesk-idle-reservation-"

    let logger: DaemonLogger
    var piExecutableOverride: URL?
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func createIdle(agent: AgentKind, cwd: URL, name: String?) async throws -> PiThread {
        guard agent.capabilities.persistsSessionBeforeFirstPrompt else {
            throw RunnerError.unsupportedCommand(
                agent: agent, what: "creating an empty conversation before its first message"
            )
        }
        // Pi 0.82 deliberately delays a brand-new session file until the first assistant message.
        // Its effective directory can come from CLI state, environment, or merged settings, so
        // only Pi can authoritatively choose the directory. Start it normally, reserve a tagged
        // path beside the file reported by get_state, then ask that same process to open it. Pi
        // writes every JSONL byte.
        var reservedPiSession: OwnedEmptySessionReservation?
        var reportedSessionID: String?
        var processStopped = true
        defer {
            if let descriptor = reservedPiSession?.descriptor { _ = Darwin.close(descriptor) }
        }
        do {
            let session = try start(agent: agent, cwd: cwd, sessionPath: nil)
            processStopped = false
            defer { processStopped = session.stop() }
            let runtime = DetachedRuntimeRequester(session: session)
            var data = try ThreadRuntimeCommands.data(
                try await runtime.request(type: "get_state", payload: [:])
            )
            guard var sessionId = data["sessionId"]?.stringValue, !sessionId.isEmpty,
                  var sessionFile = data["sessionFile"]?.stringValue, !sessionFile.isEmpty else {
                throw RunnerError.processExited("\(agent.displayName) did not report a session id/file.")
            }
            reportedSessionID = sessionId

            var sessionURL = Self.reportedSessionURL(sessionFile, cwd: cwd)
            if agent == .pi, !Self.isMaterializedFile(
                at: sessionURL, expectedID: sessionId, cwd: cwd
            ) {
                let reservation = try Self.reservePiIdleSessionFile(
                    in: sessionURL.deletingLastPathComponent()
                )
                reservedPiSession = reservation
                // Opening an empty explicit path causes Pi to allocate a second identity. The
                // probe identity is discarded and must never be exposed as the possible result.
                reportedSessionID = nil
                let switchData = try ThreadRuntimeCommands.data(
                    try await runtime.request(
                        type: "switch_session",
                        payload: ["sessionPath": .string(reservation.url.path)]
                    )
                )
                if switchData["cancelled"]?.boolValue == true {
                    throw RunnerError.processExited("Pi cancelled conversation initialization.")
                }
                data = try ThreadRuntimeCommands.data(
                    try await runtime.request(type: "get_state", payload: [:])
                )
                guard let resolvedID = data["sessionId"]?.stringValue, !resolvedID.isEmpty,
                      let resolvedFile = data["sessionFile"]?.stringValue, !resolvedFile.isEmpty else {
                    throw RunnerError.processExited("Pi did not report its initialized conversation.")
                }
                sessionId = resolvedID
                sessionFile = resolvedFile
                reportedSessionID = resolvedID
                sessionURL = Self.reportedSessionURL(resolvedFile, cwd: cwd)
                guard sessionURL.path == reservation.url.path else {
                    throw RunnerError.processExited(
                        "Pi initialized a different conversation file than the exclusively reserved path."
                    )
                }
            }
            let creationStyle = agent.capabilities.idleThreadCreation
            let requestedTitle = Self.boundedInitialName(name)
            let title = requestedTitle ?? (creationStyle == .sessionName ? Self.defaultIdleName : nil)
            var resolvedTitle: String?
            if let title {
                let response: PiJSONValue?
                do {
                    response = try await runtime.request(
                        type: "set_session_name", payload: ["name": .string(title)]
                    )
                } catch {
                    // A name-backed agent does not write a rollout for `thread/start`;
                    // `thread/name/set` is its prompt-free materialization barrier. Treating that
                    // lost acknowledgement as a definite failure could make a retry create a second
                    // conversation. First salvage the transcript, then report an unknown outcome.
                    if creationStyle == .sessionName {
                        do {
                            let thread = try await Self.materializedThread(
                                at: sessionURL, expectedID: sessionId, agent: agent, name: title
                            )
                            logger.warn(
                                "Recovered thread \(sessionId) after its materialization acknowledgement was lost: \(error)"
                            )
                            return thread
                        } catch let recoveryError {
                            logger.error(
                                "Thread \(sessionId) may have materialized after an acknowledgement failure, but its transcript could not be confirmed: \(recoveryError)"
                            )
                            throw ThreadCreationError.outcomeUnknown(
                                agent: agent, sessionReference: sessionId
                            )
                        }
                    }
                    // Other agents already have a transcript. Their optional title can fail without
                    // turning a successful create into an orphan the caller believes never existed.
                    logger.warn("Created thread \(sessionId), but could not set its initial name: \(error)")
                    response = nil
                }
                if let response {
                    do {
                        _ = try ThreadRuntimeCommands.data(response)
                        resolvedTitle = title
                    } catch {
                        // A received rejection is definite. Unlike a lost acknowledgement, it is
                        // safe for the request handler to clean up and permit a retry.
                        if creationStyle == .sessionName { throw error }
                        logger.warn("Created thread \(sessionId), but could not set its initial name: \(error)")
                    }
                }
            }

            return try await Self.materializedThread(
                at: sessionURL, expectedID: sessionId, agent: agent, name: resolvedTitle
            )
        } catch {
            guard let reservedPiSession else { throw error }
            guard processStopped else {
                throw ThreadCreationError.outcomeUnknown(
                    agent: .pi, sessionReference: reservedPiSession.url.path
                )
            }
            if let recovered = Self.recoveredReservedPiThread(
                reservation: reservedPiSession, cwd: cwd,
                expectedID: reportedSessionID
            ) {
                logger.warn(
                    "Recovered Pi thread \(recovered.id) from its reserved transcript after startup acknowledgement failed: \(error)"
                )
                return recovered
            }
            // There is no race-free unlink-by-descriptor operation on Darwin. Keep an owned empty
            // reservation after a definite failure instead of using a pathname check followed by
            // unlink, which could remove a replacement file. Empty JSONL files are ignored by all
            // scanners and the random tagged name cannot shadow a future reservation.
            if !Self.isStillOwnedAndEmpty(reservedPiSession) {
                throw ThreadCreationError.outcomeUnknown(
                    agent: .pi,
                    sessionReference: reportedSessionID ?? reservedPiSession.url.path
                )
            }
            throw error
        }
    }

    private static func reportedSessionURL(_ path: String, cwd: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return cwd.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func isMaterializedFile(
        at url: URL, expectedID: String, cwd: URL
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0,
              let thread = try? SessionThreadParser.thread(
                  at: url, transcoder: .make(for: .pi)
              ) else { return false }
        return thread.id == expectedID
            && thread.path == url.standardizedFileURL.path
            && thread.cwd == cwd.standardizedFileURL.path
    }

    private struct OwnedEmptySessionReservation: Sendable {
        let url: URL
        let descriptor: Int32
        let device: UInt64
        let inode: UInt64
    }

    private static func reservePiIdleSessionFile(
        in reportedDirectory: URL
    ) throws -> OwnedEmptySessionReservation {
        // Resolve an existing agent-configured symlink once, then reserve and report the real
        // absolute path. This supports symlinked session roots without creating through a final
        // directory symlink that could be swapped between validation and open.
        let directory = reportedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        // Pi selected and owns this directory. Validate it without calling the app's metadata
        // directory helper, which intentionally chmods existing directories to 0700.
        var directoryInfo = Darwin.stat()
        guard directory.path.withCString({ Darwin.lstat($0, &directoryInfo) }) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw RunnerError.ioFailure(
                "Pi reported a conversation directory that does not exist or is not a directory."
            )
        }
        for _ in 0..<8 {
            let url = directory.appendingPathComponent(
                "\(piReservationFilenamePrefix)\(UUID().uuidString.lowercased()).jsonl"
            )
            let descriptor = url.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw RunnerError.ioFailure(
                    "Could not exclusively reserve Pi's conversation file: \(String(cString: strerror(errno)))."
                )
            }
            var info = Darwin.stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else {
                _ = Darwin.close(descriptor)
                throw RunnerError.ioFailure("Could not verify Pi's reserved conversation file.")
            }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                _ = Darwin.close(descriptor)
                throw RunnerError.ioFailure(
                    "Could not secure Pi's reserved conversation file permissions."
                )
            }
            return OwnedEmptySessionReservation(
                url: url,
                descriptor: descriptor,
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            )
        }
        throw RunnerError.ioFailure(
            "Could not allocate a unique Pi conversation reservation."
        )
    }

    private static func ownedFileInfo(
        _ reservation: OwnedEmptySessionReservation
    ) -> Darwin.stat? {
        var info = Darwin.stat()
        guard reservation.url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              UInt64(info.st_dev) == reservation.device,
              UInt64(info.st_ino) == reservation.inode else { return nil }
        return info
    }

    private static func isStillOwnedAndEmpty(
        _ reservation: OwnedEmptySessionReservation
    ) -> Bool {
        guard let info = ownedFileInfo(reservation), info.st_size == 0 else { return false }
        var opened = Darwin.stat()
        return Darwin.fstat(reservation.descriptor, &opened) == 0
            && (opened.st_mode & S_IFMT) == S_IFREG
            && opened.st_size == 0
            && UInt64(opened.st_dev) == reservation.device
            && UInt64(opened.st_ino) == reservation.inode
    }

    private static func recoveredReservedPiThread(
        reservation: OwnedEmptySessionReservation, cwd: URL, expectedID: String?
    ) -> PiThread? {
        guard let info = ownedFileInfo(reservation), info.st_size > 0 else { return nil }
        let url = reservation.url
        guard var thread = try? SessionThreadParser.thread(
            at: url, transcoder: .make(for: .pi)
        ), thread.path == url.standardizedFileURL.path,
        thread.cwd == cwd.standardizedFileURL.path,
        expectedID == nil || thread.id == expectedID,
        let verified = ownedFileInfo(reservation), verified.st_size > 0 else { return nil }
        thread.agent = .pi
        return thread
    }

    private static func materializedThread(
        at url: URL, expectedID: String, agent: AgentKind, name: String?
    ) async throws -> PiThread {
        var thread = try await Self.waitForPersistedThread(
            at: url, expectedID: expectedID, agent: agent
        )
        thread.agent = agent
        if let name { thread.name = name }
        return thread
    }

    static func waitForPersistedThread(
        at url: URL, expectedID: String, agent: AgentKind
    ) async throws -> PiThread {
        let expectedPath = url.standardizedFileURL.path
        for attempt in 0..<41 {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                do {
                    let thread = try SessionThreadParser.thread(
                        at: url, transcoder: .make(for: agent)
                    )
                    guard thread.id == expectedID else {
                        throw RunnerError.processExited(
                            "\(agent.displayName) persisted session \(thread.id) at the path reported for \(expectedID)."
                        )
                    }
                    guard thread.path == expectedPath else {
                        throw RunnerError.processExited(
                            "\(agent.displayName) persisted a conversation that does not match its reported path."
                        )
                    }
                    return thread
                } catch let error as RunnerError {
                    throw error
                } catch SessionThreadParser.ParseError.subsession {
                    throw RunnerError.processExited(
                        "\(agent.displayName) reported a subagent transcript as the new conversation."
                    )
                } catch {
                    // A writer can create the file before its first complete JSONL record lands.
                    // Keep polling that bounded transient instead of accepting an unparseable file.
                }
            }
            if attempt < 40 { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        throw RunnerError.processExited(
            "\(agent.displayName) reported a conversation file but did not persist a parseable session."
        )
    }

    static func boundedInitialName(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
            return nil
        }
        var byteCount = 0
        let prefix = clean.prefix { character in
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= initialNameByteLimit else { return false }
            byteCount += bytes
            return true
        }
        let bounded = String(prefix)
        return bounded.isEmpty ? nil : bounded
    }

    func rename(agent: AgentKind, cwd: URL, sessionPath: URL, name: String) async throws {
        let session = try start(agent: agent, cwd: cwd, sessionPath: sessionPath)
        defer { session.stop() }
        let id = try session.send(type: "set_session_name", payload: ["name": .string(name)])
        // A timed-out response is ambiguous: Pi may already have appended the name. Only a
        // definite rejection is safe to report as a failed rename.
        if let response = try? await session.receiveMatching(id: id, timeout: 30), response["success"]?.boolValue == false {
            throw RunnerError.processExited(response["error"]?.stringValue ?? "\(agent.displayName) rejected the rename.")
        }
    }

    func runtimeSnapshot(agent: AgentKind, cwd: URL, sessionPath: URL) async throws -> ThreadRuntimeState {
        let session = try start(agent: agent, cwd: cwd, sessionPath: sessionPath)
        defer { session.stop() }
        return try await ThreadRuntimeCommands.snapshot(using: DetachedRuntimeRequester(session: session), running: false)
    }

    func setModel(agent: AgentKind, cwd: URL, sessionPath: URL, provider: String, modelId: String) async throws -> ThreadRuntimeState {
        let session = try start(agent: agent, cwd: cwd, sessionPath: sessionPath)
        defer { session.stop() }
        return try await ThreadRuntimeCommands.setModel(
            using: DetachedRuntimeRequester(session: session), provider: provider, modelId: modelId, running: false
        )
    }

    func setThinkingLevel(agent: AgentKind, cwd: URL, sessionPath: URL, level: String) async throws -> ThreadRuntimeState {
        let session = try start(agent: agent, cwd: cwd, sessionPath: sessionPath)
        defer { session.stop() }
        return try await ThreadRuntimeCommands.setThinkingLevel(
            using: DetachedRuntimeRequester(session: session), level: level, running: false
        )
    }

    private func start(agent: AgentKind, cwd: URL, sessionPath: URL?) throws -> PiRPCSession {
        guard let executable = piExecutableOverride ?? AgentCatalog.executable(
            for: agent, environment: environment
        ) else {
            throw RunnerError.agentNotFound(agent)
        }
        return try PiRPCSession.start(
            cwd: cwd,
            sessionPath: sessionPath,
            piExecutable: executable,
            environment: AgentCatalog.augmentedEnvironment(
                executable: executable, cwd: cwd, base: environment
            ),
            adapter: AgentAdapterFactory.make(agent)
        )
    }
}

/// Pi's model/thinking RPC contract, shared by detached and already-running sessions.
enum ThreadRuntimeCommands {
    static func snapshot(using runtime: RuntimeRequesting, running: Bool) async throws -> ThreadRuntimeState {
        let state = try data(try await runtime.request(type: "get_state", payload: [:]))
        let modelsData = try data(try await runtime.request(type: "get_available_models", payload: [:]))
        let levelsData = try data(try await runtime.request(type: "get_available_thinking_levels", payload: [:]))

        let currentModel = state["model"]
        let currentLevel = bounded(levelsData["current"]?.stringValue ?? state["thinkingLevel"]?.stringValue, max: 64) ?? "off"
        var seenModels: Set<String> = []
        let models = (modelsData["models"]?.arrayValue ?? []).prefix(500).compactMap { value -> ThreadRuntimeModel? in
            guard let provider = bounded(value["provider"]?.stringValue, max: 256), !provider.isEmpty,
                  let modelId = bounded(value["id"]?.stringValue, max: 256), !modelId.isEmpty,
                  seenModels.insert("\(provider)\u{0}\(modelId)").inserted else { return nil }
            return ThreadRuntimeModel(
                provider: provider,
                modelId: modelId,
                name: bounded(value["name"]?.stringValue, max: 256) ?? modelId,
                reasoning: value["reasoning"]?.boolValue ?? false
            )
        }

        var seenLevels: Set<String> = []
        var levels = (levelsData["levels"]?.arrayValue ?? []).prefix(32).compactMap { value -> String? in
            guard let level = bounded(value.stringValue, max: 64), !level.isEmpty, seenLevels.insert(level).inserted else { return nil }
            return level
        }
        if !levels.contains(currentLevel) { levels.insert(currentLevel, at: 0) }
        if levels.isEmpty { levels = ["off"] }

        return ThreadRuntimeState(
            provider: bounded(currentModel?["provider"]?.stringValue, max: 256),
            modelId: bounded(currentModel?["id"]?.stringValue, max: 256),
            modelName: bounded(currentModel?["name"]?.stringValue, max: 256),
            thinkingLevel: currentLevel,
            availableModels: models,
            availableThinkingLevels: levels,
            running: running
        )
    }

    static func setModel(
        using runtime: RuntimeRequesting, provider: String, modelId: String, running: Bool
    ) async throws -> ThreadRuntimeState {
        _ = try data(try await runtime.request(type: "set_model", payload: [
            "provider": .string(provider), "modelId": .string(modelId)
        ]))
        return try await snapshot(using: runtime, running: running)
    }

    static func setThinkingLevel(
        using runtime: RuntimeRequesting, level: String, running: Bool
    ) async throws -> ThreadRuntimeState {
        _ = try data(try await runtime.request(type: "set_thinking_level", payload: ["level": .string(level)]))
        return try await snapshot(using: runtime, running: running)
    }

    static func data(_ response: PiJSONValue) throws -> PiJSONValue {
        guard response["success"]?.boolValue != false else {
            throw RunnerError.processExited(response["error"]?.stringValue ?? "Pi rejected the command.")
        }
        return response["data"] ?? .object([:])
    }

    private static func bounded(_ value: String?, max: Int) -> String? {
        guard let value, value.count <= max else { return nil }
        return value
    }
}
