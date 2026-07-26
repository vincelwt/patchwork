import Foundation
import PiDeskKit

/// `POST /v1/threads` without a `message` ("the session is created idle") has no prompt to run,
/// so it does not go through `RunQueue` at all: this spawns `pi --mode rpc` in `cwd` just long
/// enough to learn the session identity Pi allocates on connect, then stops it immediately.
struct ThreadCreationService {
    let logger: DaemonLogger
    var piExecutableOverride: URL?

    func createIdle(cwd: URL, name: String?) async throws -> PiThread {
        guard let piURL = piExecutableOverride ?? PiLocator.resolve() else { throw RunnerError.piNotFound }
        let environment = PiLocator.augmentedEnvironment(piURL: piURL, cwd: cwd)
        let session = try PiRPCSession.start(cwd: cwd, sessionPath: nil, piExecutable: piURL, environment: environment)
        defer { session.stop() }

        let requestID = try session.send(type: "get_state")
        let response = try await session.receiveMatching(id: requestID, timeout: 15)
        guard response["success"]?.boolValue != false, let data = response["data"] else {
            throw RunnerError.processExited(response["error"]?.stringValue ?? "Pi did not report a session.")
        }
        guard let sessionId = data["sessionId"]?.stringValue, let sessionFile = data["sessionFile"]?.stringValue else {
            throw RunnerError.processExited("Pi did not report a session id/file.")
        }

        let now = Date()
        let standardizedCwd = cwd.standardizedFileURL
        let title = name?.trimmingCharacters(in: .whitespaces)
        return PiThread(
            id: sessionId,
            path: sessionFile,
            name: (title?.isEmpty == false ? title : nil) ?? "Untitled conversation",
            cwd: standardizedCwd.path,
            folder: standardizedCwd.lastPathComponent.isEmpty ? standardizedCwd.path : standardizedCwd.lastPathComponent,
            createdAt: now,
            updatedAt: now
        )
    }

    /// `POST /v1/threads/{id}/name`, via Pi's own `set_session_name` RPC — matching the app's
    /// `AppStore.renameSession(_:to:)` — rather than writing a `session_info` entry directly,
    /// which would violate "never rewrite a Pi JSONL file".
    func rename(cwd: URL, sessionPath: URL, name: String) async throws {
        guard let piURL = piExecutableOverride ?? PiLocator.resolve() else { throw RunnerError.piNotFound }
        let environment = PiLocator.augmentedEnvironment(piURL: piURL, cwd: cwd)
        let session = try PiRPCSession.start(cwd: cwd, sessionPath: sessionPath, piExecutable: piURL, environment: environment)
        defer { session.stop() }
        let requestID = try session.send(type: "set_session_name", payload: ["name": .string(name)])
        // Best-effort wait: like the app, a timeout here does not necessarily mean the rename
        // failed — it may already be in the session file — so this does not throw on timeout,
        // only on a definite failure response.
        if let response = try? await session.receiveMatching(id: requestID, timeout: 30), response["success"]?.boolValue == false {
            throw RunnerError.processExited(response["error"]?.stringValue ?? "Pi rejected the rename.")
        }
    }
}
