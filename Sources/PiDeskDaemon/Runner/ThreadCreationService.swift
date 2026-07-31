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
    let logger: DaemonLogger
    var piExecutableOverride: URL?

    func createIdle(agent: AgentKind, cwd: URL, name: String?) async throws -> PiThread {
        let session = try start(agent: agent, cwd: cwd, sessionPath: nil)
        defer { session.stop() }
        let runtime = DetachedRuntimeRequester(session: session)
        let data = try ThreadRuntimeCommands.data(try await runtime.request(type: "get_state", payload: [:]))
        guard let sessionId = data["sessionId"]?.stringValue, let sessionFile = data["sessionFile"]?.stringValue else {
            throw RunnerError.processExited("\(agent.displayName) did not report a session id/file.")
        }

        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedTitle = title
        if let title, !title.isEmpty {
            do {
                let response = try await runtime.request(type: "set_session_name", payload: ["name": .string(title)])
                if response["success"]?.boolValue == false { resolvedTitle = nil }
            } catch {
                // The session already exists. An optional title must not turn a successful create
                // into an orphan the caller believes was never created.
                resolvedTitle = nil
                logger.warn("Created thread \(sessionId), but could not set its initial name: \(error)")
            }
        }

        let now = Date()
        let standardizedCwd = cwd.standardizedFileURL
        return PiThread(
            id: sessionId,
            path: sessionFile,
            name: (resolvedTitle?.isEmpty == false ? resolvedTitle : nil) ?? "Untitled conversation",
            cwd: standardizedCwd.path,
            folder: standardizedCwd.lastPathComponent.isEmpty ? standardizedCwd.path : standardizedCwd.lastPathComponent,
            createdAt: now,
            updatedAt: now
        )
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
        guard let executable = piExecutableOverride ?? AgentCatalog.executable(for: agent) else {
            throw RunnerError.agentNotFound(agent)
        }
        return try PiRPCSession.start(
            cwd: cwd,
            sessionPath: sessionPath,
            piExecutable: executable,
            environment: AgentCatalog.augmentedEnvironment(executable: executable, cwd: cwd),
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
