import Foundation
import PiDeskKit
import XCTest
@testable import PiDesktop

private final class IntentRuntime: AgentRuntimeProtocol {
    enum RouteOutcome { case success, cancelled, error }

    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var agent: AgentKind = .pi
    var routeOutcome: RouteOutcome = .success
    var delayState = false
    var delayModels = false
    var delayThinking = false
    var delayStats = false
    var delayPrompt = false
    var promptError: String?
    var onStart: (() -> Void)?
    private(set) var starts: [(cwd: URL, session: URL?)] = []
    private(set) var stopCount = 0
    private(set) var sent: [(String, [String: JSONValue])] = []
    private var stateCompletion: ((Result<JSONValue, Error>) -> Void)?
    private var modelCompletion: ((Result<JSONValue, Error>) -> Void)?
    private var thinkingCompletion: ((Result<JSONValue, Error>) -> Void)?
    private var promptCompletion: ((Result<JSONValue, Error>) -> Void)?
    private(set) var sessionFile = ""
    private var sessionID = ""

    func start(cwd: URL, sessionPath: URL?) throws {
        starts.append((cwd, sessionPath))
        sessionFile = sessionPath?.standardizedFileURL.path
            ?? cwd.appendingPathComponent("cold-\(starts.count).jsonl").path
        sessionID = "runtime-\(starts.count)"
        isRunning = true
        onStart?()
    }

    func stop() { isRunning = false; stopCount += 1 }

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        sent.append((type, payload))
        switch type {
        case "switch_session":
            switch routeOutcome {
            case .success:
                sessionFile = payload["sessionPath"]?.stringValue ?? sessionFile
                sessionID = "switched"
                completion?(success(["cancelled": .bool(false)]))
            case .cancelled:
                routeOutcome = .success
                completion?(success(["cancelled": .bool(true)]))
            case .error:
                routeOutcome = .success
                completion?(.success(.object(["success": .bool(false), "error": .string("switch failed")])))
            }
        case "new_session":
            sessionFile = starts.last!.cwd.appendingPathComponent("new-\(sent.count).jsonl").path
            sessionID = "new"
            completion?(success(["cancelled": .bool(false)]))
        case "get_state" where delayState:
            stateCompletion = completion
        case "get_state":
            completion?(stateResponse())
        case "get_available_models" where delayModels:
            modelCompletion = completion
        case "get_available_models":
            completion?(success(["models": .array([])]))
        case "get_available_thinking_levels" where delayThinking:
            thinkingCompletion = completion
        case "get_available_thinking_levels":
            completion?(success(["levels": .array([.string("off")])]))
        case "get_session_stats" where delayStats:
            break
        case "prompt" where delayPrompt:
            promptCompletion = completion
        case "prompt" where promptError != nil:
            completion?(.success(.object([
                "success": .bool(false),
                "error": .string(promptError ?? "prompt rejected")
            ])))
        default:
            completion?(success([:]))
        }
    }

    func sendUncorrelated(_ value: JSONValue) {}

    func finishState() { stateCompletion?(stateResponse()); stateCompletion = nil }
    func finishModels() {
        modelCompletion?(success(["models": .array([])])); modelCompletion = nil
    }
    func finishThinking() {
        thinkingCompletion?(success(["levels": .array([.string("off")])]))
        thinkingCompletion = nil
    }
    func finishPrompt() {
        promptCompletion?(success([:]))
        promptCompletion = nil
    }
    func finishPrompt(with error: Error) {
        promptCompletion?(.failure(error))
        promptCompletion = nil
    }
    func count(_ command: String) -> Int { sent.filter { $0.0 == command }.count }

    private func stateResponse() -> Result<JSONValue, Error> {
        .success(.object([
            "success": .bool(true),
            "data": .object([
                "isStreaming": .bool(false),
                "sessionFile": .string(sessionFile),
                "sessionId": .string(sessionID),
                "model": .object(["id": .string("m"), "name": .string("M"), "provider": .string("p")])
            ])
        ]))
    }

    private func success(_ data: [String: JSONValue]) -> Result<JSONValue, Error> {
        .success(.object(["success": .bool(true), "data": .object(data)]))
    }
}

private struct IntentRepository: SessionRepositoryProtocol {
    let rootURL: URL
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary { throw CancellationError() }
}

private struct IntentGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

@MainActor
private final class ManualRuntimeLease {
    struct Entry {
        let delay: TimeInterval
        var cancelled = false
        let action: @MainActor () -> Void
    }
    var entries: [Entry] = []

    func schedule(delay: TimeInterval, action: @escaping @MainActor () -> Void) -> () -> Void {
        let index = entries.count
        entries.append(Entry(delay: delay, action: action))
        return { [weak self] in self?.entries[index].cancelled = true }
    }

    func fire(_ index: Int) {
        guard entries.indices.contains(index), !entries[index].cancelled else { return }
        entries[index].action()
    }
}

@MainActor
final class AppStoreRuntimeIntentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PiRuntimeIntent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testBootstrapIsLazyAndComposerEditShowsStartupPhasesWithImmediateBubble() {
        let runtime = IntentRuntime()
        let probe = IntentRuntime()
        runtime.delayState = true
        runtime.delayThinking = true
        runtime.delayStats = true
        let store = makeStore(runtime: runtime, probe: probe)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)
        store.bootstrap()
        XCTAssertEqual(runtime.starts.count, 0)
        XCTAssertEqual(probe.starts.count, 0)

        var phaseDuringStart: RuntimePhase?
        runtime.onStart = { phaseDuringStart = store.currentRouteRuntimePhase }
        store.composerContentDidChange()
        XCTAssertEqual(phaseDuringStart, .startingPi)
        XCTAssertEqual(store.currentRouteRuntimePhase, .openingConversation)

        store.draft = "hello"
        store.submitDraft()
        XCTAssertEqual(store.messages.last?.textContent, "hello")
        XCTAssertEqual(runtime.count("prompt"), 0)
        XCTAssertTrue(store.currentRouteHasPendingStartupPrompt)
        XCTAssertTrue(store.isRunning(session), "startup itself must show the transcript waiting state")
        let startupItems = TranscriptPresenter.items(
            messages: store.messages, streaming: nil, isRunning: store.isRunning(session)
        )
        XCTAssertTrue(startupItems.contains { item in
            guard case let .work(block) = item else { return false }
            return block.isActive && block.entries.isEmpty
        })

        runtime.finishState()
        XCTAssertEqual(runtime.count("prompt"), 1, "thinking/stats requests must not gate dispatch")
        XCTAssertEqual(store.currentRouteRuntimePhase, .waitingForModel)
        XCTAssertEqual(RuntimePhase.waitingForModel.label, "Waiting for first response…")
        runtime.onEvent?(.object(["type": .string("agent_start")]))
        runtime.onEvent?(.object([
            "type": .string("message_start"),
            "message": .object(["role": .string("user")])
        ]))
        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object(["role": .string("user"), "content": .string("hello")])
        ]))
        runtime.onEvent?(.object(["type": .string("turn_start")]))
        XCTAssertEqual(store.currentRouteRuntimePhase, .waitingForModel, "local user events are not provider output")
        runtime.onEvent?(.object([
            "type": .string("message_update"),
            "message": .object(["role": .string("assistant"), "content": .string("Hi")])
        ]))
        XCTAssertEqual(store.currentRouteRuntimePhase, .working)
        XCTAssertEqual(runtime.count("get_messages"), 0)
    }

    func testExistingConversationDoesNotStartUntilItsNativeLeaseIsGranted() async {
        let runtime = IntentRuntime()
        let gate = LeaseOperationGateForStore()
        await gate.blockAcquire()
        let store = makeStore(
            runtime: runtime,
            runtimeLeaseOperation: { path, request in
                try await gate.perform(path: path, request: request)
            }
        )
        let session = summary("leased", cwd: root)
        store.sessions = [session]
        store.selectSession(session)

        store.composerContentDidChange()
        for _ in 0..<50 where await gate.requestCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestCount = await gate.counts().requests
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(runtime.starts.count, 0)

        await gate.releaseAcquire()
        for _ in 0..<50 where runtime.starts.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(runtime.starts.count, 1)
    }

    func testSwitchDuringBlockedLeaseDoesNotLetTheOldContinuationCloseTheReplacementLease() async {
        let runtime = IntentRuntime()
        let gate = LeaseOperationGateForStore()
        await gate.blockAcquire()
        let store = makeStore(
            runtime: runtime,
            runtimeLeaseOperation: { path, request in
                try await gate.perform(path: path, request: request)
            }
        )
        let first = summary("blocked", cwd: root)
        let replacement = summary("replacement", cwd: root)
        store.sessions = [first, replacement]
        store.selectSession(first)
        store.draft = "restore this exactly once"
        store.submitDraft()

        for _ in 0..<50 where await gate.requestCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let initialCounts = await gate.counts()
        XCTAssertEqual(initialCounts.requests, 1)
        XCTAssertTrue(runtime.starts.isEmpty)

        store.selectSession(replacement)
        store.composerContentDidChange()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let blockedCounts = await gate.counts()
        XCTAssertEqual(
            blockedCounts.requests, 1,
            "the replacement waits behind the transferred coordinator's in-flight request"
        )
        XCTAssertTrue(runtime.starts.isEmpty)

        await gate.releaseAcquire()
        for _ in 0..<100 {
            let current = await gate.counts()
            if !runtime.starts.isEmpty, current.releases > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let counts = await gate.counts()
        XCTAssertEqual(counts.requests, 2)
        XCTAssertEqual(counts.releases, 1, "only the superseded path is released")
        XCTAssertEqual(runtime.starts.count, 1)
        XCTAssertEqual(runtime.starts.first?.session?.standardizedFileURL.path, replacement.fileURL.standardizedFileURL.path)
        XCTAssertEqual(runtime.stopCount, 0)

        store.selectSession(first)
        XCTAssertEqual(store.draft, "restore this exactly once")
    }

    func testFreshClaudeDefersLeaseUntilTheFirstPromptMaterializes() async throws {
        let runtime = IntentRuntime()
        runtime.agent = .claude
        runtime.delayPrompt = true
        let gate = LeaseOperationGateForStore()
        await gate.failNextNotFound(2)
        let store = makeStore(
            runtime: runtime,
            runtimeLeaseOperation: { path, request in
                try await gate.perform(path: path, request: request)
            }
        )
        store.newChatAgent = .claude
        store.selectedFolder = root
        store.draft = "hello from a fresh conversation"

        store.submitDraft()

        XCTAssertEqual(runtime.count("prompt"), 1)
        let requestsBeforeAcknowledgement = await gate.counts().requests
        XCTAssertEqual(requestsBeforeAcknowledgement, 0)
        XCTAssertEqual(store.sessions.first?.agent, .claude)
        try Data("materialized transcript".utf8).write(
            to: URL(fileURLWithPath: runtime.sessionFile), options: .atomic
        )
        runtime.finishPrompt()

        for _ in 0..<100 where await gate.counts().requests < 3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let requestsAfterMaterialization = await gate.counts().requests
        XCTAssertEqual(requestsAfterMaterialization, 3)
        XCTAssertEqual(runtime.stopCount, 0)
    }

    func testAmbiguousFreshCodexPromptAcquiresItsMaterializedLease() async throws {
        let runtime = IntentRuntime()
        runtime.agent = .codex
        runtime.delayPrompt = true
        let gate = LeaseOperationGateForStore()
        let store = makeStore(
            runtime: runtime,
            runtimeLeaseOperation: { path, request in
                try await gate.perform(path: path, request: request)
            }
        )
        store.newChatAgent = .codex
        store.selectedFolder = root
        store.draft = "ambiguous but accepted"

        store.submitDraft()
        try Data("materialized transcript".utf8).write(
            to: URL(fileURLWithPath: runtime.sessionFile), options: .atomic
        )
        runtime.finishPrompt(with: AgentRuntimeError.outcomeUnknown("prompt acknowledgement timed out"))

        for _ in 0..<50 where await gate.counts().requests == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestCount = await gate.counts().requests
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(runtime.stopCount, 0)
    }

    func testFreshClaudeAgentStartAcquiresLeaseBeforePromptAcknowledgement() async throws {
        let runtime = IntentRuntime()
        runtime.agent = .claude
        runtime.delayPrompt = true
        let gate = LeaseOperationGateForStore()
        let store = makeStore(
            runtime: runtime,
            runtimeLeaseOperation: { path, request in
                try await gate.perform(path: path, request: request)
            }
        )
        store.newChatAgent = .claude
        store.selectedFolder = root
        store.draft = "event arrives first"

        store.submitDraft()
        try Data("materialized transcript".utf8).write(
            to: URL(fileURLWithPath: runtime.sessionFile), options: .atomic
        )
        runtime.onEvent?(.object(["type": .string("agent_start")]))

        for _ in 0..<50 where await gate.counts().requests == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestCount = await gate.counts().requests
        XCTAssertEqual(requestCount, 1)
        runtime.finishPrompt()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let requestCountAfterAcknowledgement = await gate.counts().requests
        XCTAssertEqual(requestCountAfterAcknowledgement, 1, "the later acknowledgement is idempotent")
    }

    func testFreshClaudeSettlementAlsoAcquiresLeaseWhenStartWasMissed() async throws {
        let runtime = IntentRuntime()
        runtime.agent = .claude
        runtime.delayPrompt = true
        let gate = LeaseOperationGateForStore()
        let store = makeStore(
            runtime: runtime,
            runtimeLeaseOperation: { path, request in
                try await gate.perform(path: path, request: request)
            }
        )
        store.newChatAgent = .claude
        store.selectedFolder = root
        store.draft = "settled event is the first observed lifecycle"

        store.submitDraft()
        try Data("materialized transcript".utf8).write(
            to: URL(fileURLWithPath: runtime.sessionFile), options: .atomic
        )
        runtime.onEvent?(.object(["type": .string("agent_settled")]))

        for _ in 0..<50 where await gate.counts().requests == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestCount = await gate.counts().requests
        XCTAssertEqual(requestCount, 1)
    }

    func testDefiniteFreshPromptFailureRemovesTheUnmaterializedSidebarRow() {
        let runtime = IntentRuntime()
        runtime.agent = .claude
        runtime.promptError = "prompt rejected"
        let store = makeStore(runtime: runtime)
        store.newChatAgent = .claude
        store.selectedFolder = root
        store.draft = "please retry me"

        store.submitDraft()

        XCTAssertEqual(runtime.count("prompt"), 1)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSession)
        XCTAssertEqual(store.draft, "please retry me")
        XCTAssertTrue(runtime.isRunning, "the untouched fresh runtime can accept the corrected retry")
    }

    func testDefiniteFreshPromptFailureMakesTheUnusedWorktreeDiscardableAgain() {
        let runtime = IntentRuntime()
        runtime.agent = .claude
        runtime.promptError = "prompt rejected"
        let store = makeStore(runtime: runtime)
        let worktree = root.appendingPathComponent("unused-worktree", isDirectory: true)
        store.newChatAgent = .claude
        store.selectedFolder = root
        store.setNewChatWorktreeForTesting(worktree, origin: root)
        store.draft = "please retry me"

        store.submitDraft()

        XCTAssertFalse(store.newChatWorktreeSubmittedForTesting)
        store.setNewChatWorktree(false)
        XCTAssertNil(store.newChatWorktree)
        XCTAssertNil(store.managedWorktreeProjects[worktree.standardizedFileURL.path])
    }

    func testStopDuringStartupPreventsThePendingPromptFromDispatching() {
        let runtime = IntentRuntime()
        runtime.delayState = true
        let store = makeStore(runtime: runtime)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)
        store.draft = "never send this"
        store.submitDraft()
        XCTAssertTrue(store.canStopCurrentThread)
        XCTAssertEqual(runtime.count("prompt"), 0)

        store.abort()
        runtime.finishState()

        XCTAssertFalse(store.canStopCurrentThread)
        XCTAssertEqual(runtime.count("abort"), 1)
        XCTAssertEqual(runtime.count("prompt"), 0)
        XCTAssertEqual(runtime.stopCount, 1)
        XCTAssertEqual(store.draft, "never send this")
        XCTAssertFalse(store.messages.contains { $0.textContent == "never send this" })
    }

    func testSendingAnArchivedConversationRestoresIt() {
        let runtime = IntentRuntime()
        let store = makeStore(runtime: runtime)
        var session = summary("archived", cwd: root)
        session.isArchived = true
        store.sessions = [session]
        store.selectSession(session)
        store.draft = "resume this"

        store.submitDraft()

        XCTAssertFalse(store.sessions[0].isArchived)
        XCTAssertFalse(store.selectedSession?.isArchived ?? true)
        XCTAssertEqual(runtime.count("prompt"), 1)
    }

    func testPendingModelOptionsDoNotGatePromptDispatch() {
        let runtime = IntentRuntime()
        runtime.delayModels = true
        let store = makeStore(runtime: runtime)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)
        store.composerContentDidChange()
        XCTAssertEqual(runtime.count("get_available_models"), 1)
        store.draft = "send now"
        store.submitDraft()
        XCTAssertEqual(runtime.count("prompt"), 1)
    }

    func testNewChatPresetIsAppliedBeforeTheFirstPrompt() throws {
        let runtime = IntentRuntime()
        let store = makeStore(runtime: runtime)
        store.selectedFolder = root
        let preset = AgentPreset(
            name: "Focused",
            agent: .pi,
            provider: "openai",
            modelID: "gpt-test",
            modelName: "GPT Test",
            thinkingLevel: "xhigh"
        )
        store.savePreset(preset)
        store.draft = "Use the preset"

        store.submitDraft()

        let commands = runtime.sent.map(\.0)
        let modelIndex = try XCTUnwrap(commands.firstIndex(of: "set_model"))
        let thinkingIndex = try XCTUnwrap(commands.firstIndex(of: "set_thinking_level"))
        let promptIndex = try XCTUnwrap(commands.firstIndex(of: "prompt"))
        XCTAssertLessThan(modelIndex, thinkingIndex)
        XCTAssertLessThan(thinkingIndex, promptIndex)
        XCTAssertEqual(runtime.sent[modelIndex].1["modelId"]?.stringValue, "gpt-test")
        XCTAssertEqual(runtime.sent[thinkingIndex].1["level"]?.stringValue, "xhigh")
    }

    func testPresetShortcutCyclesInSavedOrderOnlyOnNewChat() {
        let runtime = IntentRuntime()
        let store = makeStore(runtime: runtime)
        let first = AgentPreset(
            name: "One", agent: .pi, provider: "p", modelID: "one", modelName: "One", thinkingLevel: "high"
        )
        let second = AgentPreset(
            name: "Two", agent: .pi, provider: "p", modelID: "two", modelName: "Two", thinkingLevel: "xhigh"
        )
        store.savePreset(first)
        store.savePreset(second)
        XCTAssertEqual(store.selectedPresetID, first.id)

        store.cyclePreset()

        XCTAssertEqual(store.selectedPresetID, second.id)
    }

    func testImageAttachmentsStayVisibleOnTheUserMessage() throws {
        let runtime = IntentRuntime()
        let store = makeStore(runtime: runtime)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)
        store.composerContentDidChange()

        let imageURL = root.appendingPathComponent("reference image.png")
        let imageData = Data("pixels".utf8)
        store.draft = "Build this"
        store.attachments = [ImageAttachment(
            data: imageData,
            mimeType: "image/png",
            fileName: imageURL.lastPathComponent,
            fileURL: imageURL
        )]
        store.submitDraft()

        let payload = try XCTUnwrap(runtime.sent.last { $0.0 == "prompt" }?.1)
        XCTAssertEqual(
            payload["message"]?.stringValue,
            "Build this\n\nAttached image file paths:\n- \(imageURL.path)"
        )
        XCTAssertEqual(payload["images"]?.arrayValue?.count, 1)
        XCTAssertEqual(store.messages.last?.textContent, "Build this")
        XCTAssertEqual(store.messages.last?.images.map(\.data), [imageData])

        runtime.onEvent?(.object([
            "type": .string("message_end"),
            "message": .object([
                "id": .string("codex-user-echo"),
                "role": .string("user"),
                "content": .string(payload["message"]?.stringValue ?? "")
            ])
        ]))
        let userRows = store.messages.filter { $0.role == .user }
        XCTAssertEqual(userRows.count, 1, "the lossy Codex echo must not append a second bubble")
        XCTAssertTrue(userRows[0].id.hasPrefix("local-"), "the richer optimistic row stays until JSONL is durable")
        XCTAssertEqual(userRows[0].textContent, "Build this")
        XCTAssertEqual(userRows[0].images.map(\.data), [imageData])
    }

    func testIdleSameCwdProcessSwitchesSavedAndNewRoutesButCrossCwdColdStarts() throws {
        let runtime = IntentRuntime()
        let store = makeStore(runtime: runtime)
        let a = summary("a", cwd: root)
        let b = summary("b", cwd: root)
        store.sessions = [a, b]
        store.selectSession(a)
        store.composerContentDidChange()
        store.selectSession(b)
        store.composerContentDidChange()
        XCTAssertEqual(runtime.starts.count, 1)
        XCTAssertEqual(runtime.count("switch_session"), 1)
        XCTAssertEqual(runtime.sent.first { $0.0 == "switch_session" }?.1["sessionPath"]?.stringValue, b.fileURL.path)

        store.openNewChat()
        store.selectedFolder = root
        store.composerContentDidChange()
        XCTAssertEqual(runtime.count("new_session"), 1)
        XCTAssertEqual(runtime.starts.count, 1)

        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        store.openNewChat()
        store.selectedFolder = other
        store.composerContentDidChange()
        XCTAssertEqual(runtime.starts.count, 2)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testBufferedEventsFromBeforeReuseCannotMutateOrStopTheNewRoute() {
        let runtime = IntentRuntime()
        let store = makeStore(runtime: runtime)
        let a = summary("a", cwd: root)
        let b = summary("b", cwd: root)
        store.sessions = [a, b]
        store.selectSession(a)
        store.composerContentDidChange()
        let staleHandler = runtime.onEvent

        runtime.delayState = true
        store.selectSession(b)
        store.composerContentDidChange()
        XCTAssertNil(runtime.onEvent, "Events stay gated until the switched route passes get_state validation")
        staleHandler?(.object([
            "type": .string("message_end"),
            "message": .object([
                "role": .string("assistant"), "content": .string("stale A answer"),
                "stopReason": .string("stop"), "timestamp": .number(1_000)
            ])
        ]))
        staleHandler?(.object(["type": .string("agent_settled")]))
        runtime.finishState()

        XCTAssertFalse(store.messages.contains { $0.textContent == "stale A answer" })
        XCTAssertEqual(runtime.stopCount, 0)
        XCTAssertEqual(store.currentRouteRuntimePhase, .idle)
    }

    func testBusyRuntimeIsPreservedAndReuseCancellationOrErrorFallsBackCold() {
        let busy = IntentRuntime()
        let replacement = IntentRuntime()
        let store = makeStore(runtime: busy, factory: { _ in replacement })
        let a = summary("a", cwd: root)
        let b = summary("b", cwd: root)
        store.sessions = [a, b]
        store.selectSession(a)
        store.composerContentDidChange()
        store.draft = "working"
        store.submitDraft()
        busy.onEvent?(.object(["type": .string("agent_start")]))
        store.selectSession(b)
        store.composerContentDidChange()
        XCTAssertEqual(busy.stopCount, 0)
        XCTAssertEqual(busy.count("switch_session"), 0)
        XCTAssertEqual(replacement.starts.count, 1)

        for outcome in [IntentRuntime.RouteOutcome.cancelled, .error] {
            let runtime = IntentRuntime()
            let localStore = makeStore(runtime: runtime)
            localStore.sessions = [a, b]
            localStore.selectSession(a)
            localStore.composerContentDidChange()
            runtime.routeOutcome = outcome
            localStore.selectSession(b)
            localStore.composerContentDidChange()
            XCTAssertEqual(runtime.count("switch_session"), 1)
            XCTAssertEqual(runtime.stopCount, 1)
            XCTAssertEqual(runtime.starts.count, 2)
            XCTAssertEqual(runtime.starts.last?.session?.path, b.fileURL.path)
        }
    }

    func testOptionsRequestMustFinishBeforeIdleLeaseStarts() {
        let runtime = IntentRuntime()
        runtime.delayModels = true
        let lease = ManualRuntimeLease()
        let store = makeStore(runtime: runtime, lease: lease)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)

        store.composerContentDidChange()
        XCTAssertTrue(lease.entries.isEmpty)
        XCTAssertEqual(runtime.stopCount, 0)

        runtime.finishModels()
        XCTAssertEqual(lease.entries.last?.delay, 120)
        lease.fire(lease.entries.count - 1)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testRepeatedComposerEditsDoNotChurnIdleLeaseOrRetireBusyAndDialogRuntimes() {
        let runtime = IntentRuntime()
        let lease = ManualRuntimeLease()
        let store = makeStore(runtime: runtime, lease: lease)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)
        store.composerContentDidChange()
        XCTAssertEqual(lease.entries.last?.delay, 120)
        let activeLease = lease.entries.count - 1
        XCTAssertFalse(lease.entries[activeLease].cancelled)
        store.composerContentDidChange()
        XCTAssertEqual(lease.entries.count - 1, activeLease)
        XCTAssertFalse(lease.entries[activeLease].cancelled)

        store.draft = "waiting"
        store.submitDraft()
        XCTAssertTrue(lease.entries[activeLease].cancelled)
        lease.fire(activeLease)
        XCTAssertEqual(runtime.stopCount, 0)
        runtime.onEvent?(.object(["type": .string("agent_start")]))
        lease.fire(lease.entries.count - 1)
        XCTAssertEqual(runtime.stopCount, 0)
        runtime.onEvent?(.object(["type": .string("agent_settled")]))

        runtime.onEvent?(.object([
            "type": .string("extension_ui_request"), "method": .string("input"),
            "id": .string("dialog"), "title": .string("Question")
        ]))
        lease.fire(lease.entries.count - 1)
        XCTAssertEqual(runtime.stopCount, 0)
        store.respondToExtensionDialog(value: "ok")
        let finalLease = lease.entries.count - 1
        lease.fire(finalLease)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testRunningSubagentsHoldTheRuntimeOpenUntilTheStatusClears() {
        let runtime = IntentRuntime()
        let lease = ManualRuntimeLease()
        let store = makeStore(runtime: runtime, lease: lease)
        let session = summary("a", cwd: root)
        store.sessions = [session]
        store.selectSession(session)
        store.composerContentDidChange()
        XCTAssertEqual(lease.entries.last?.delay, 120)
        store.activities = [ActivityItem(
            id: "agent-call", sourceID: "agent-call", kind: .subagent, title: "Live agent",
            status: .running, raw: .null
        )]

        runtime.onEvent?(Self.subagentStatus("5 running agents"))
        XCTAssertTrue(lease.entries[lease.entries.count - 1].cancelled, "live subagents must drop the idle lease")
        for index in lease.entries.indices { lease.fire(index) }
        XCTAssertEqual(runtime.stopCount, 0, "a runtime hosting background agents must never be stopped")

        // A blank value is the degenerate case: it must not pin the process open.
        runtime.onEvent?(Self.subagentStatus("   "))
        XCTAssertEqual(store.activities.first?.status, .stopped, "the authoritative empty status must clear stale activity")
        let blankLease = lease.entries.count - 1
        XCTAssertEqual(lease.entries[blankLease].delay, 120)
        XCTAssertFalse(lease.entries[blankLease].cancelled)

        runtime.onEvent?(Self.subagentStatus("2 running, 3 queued agents"))
        XCTAssertTrue(lease.entries[blankLease].cancelled)
        runtime.onEvent?(Self.subagentStatus(nil))
        let finalLease = lease.entries.count - 1
        XCTAssertGreaterThan(finalLease, blankLease, "clearing the last agent must re-arm retirement")
        lease.fire(finalLease)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testManagedProcessKeepsBackgroundConversationRunningUntilItsLifecycleUpdate() {
        let runtime = IntentRuntime()
        let replacement = IntentRuntime()
        let store = makeStore(runtime: runtime, factory: { _ in replacement })
        let a = summary("a", cwd: root)
        let b = summary("b", cwd: root)
        store.sessions = [a, b]
        store.selectSession(a)
        store.composerContentDidChange()

        runtime.onEvent?(.object(["type": .string("agent_start")]))
        runtime.onEvent?(Self.processStarted("proc-1"))
        runtime.onEvent?(.object(["type": .string("agent_settled")]))
        XCTAssertTrue(store.isRunning(a), "a settled model turn must stay running while its managed process works")

        store.selectSession(b)
        store.composerContentDidChange()
        XCTAssertEqual(runtime.stopCount, 0, "switching conversations must not kill the managed process")
        XCTAssertEqual(replacement.starts.count, 1)

        runtime.onEvent?(Self.processEnded("proc-1"))
        XCTAssertEqual(runtime.stopCount, 1, "the parked runtime can retire after the process posts its lifecycle update")
        XCTAssertFalse(store.isRunning(a))
    }

    func testSwitchingAwayParksARuntimeWithSubagentsAndRetiresItWhenTheyFinish() {
        let runtime = IntentRuntime()
        let replacement = IntentRuntime()
        let store = makeStore(runtime: runtime, factory: { _ in replacement })
        let a = summary("a", cwd: root)
        let b = summary("b", cwd: root)
        store.sessions = [a, b]
        store.selectSession(a)
        store.composerContentDidChange()
        runtime.onEvent?(Self.subagentStatus("2 running, 3 queued agents"))

        store.selectSession(b)
        store.composerContentDidChange()
        XCTAssertEqual(runtime.stopCount, 0, "the hosting process must be parked, not stopped")
        XCTAssertEqual(runtime.count("switch_session"), 0, "reusing the process would abandon its agents")
        XCTAssertEqual(replacement.starts.count, 1)

        runtime.onEvent?(Self.subagentStatus(nil))
        XCTAssertEqual(runtime.stopCount, 1, "the parked runtime retires once its agents finish")
    }

    private static func processStarted(_ id: String) -> JSONValue {
        .object([
            "type": .string("tool_execution_end"),
            "toolCallId": .string("start-process"),
            "toolName": .string("process"),
            "result": .object([
                "details": .object([
                    "action": .string("start"),
                    "success": .bool(true),
                    "process": .object([
                        "id": .string(id),
                        "status": .string("running"),
                        "startTime": .number(Date().timeIntervalSince1970 * 1_000)
                    ])
                ])
            ])
        ])
    }

    private static func processEnded(_ id: String) -> JSONValue {
        .object([
            "type": .string("message_end"),
            "message": .object([
                "role": .string("custom"),
                "customType": .string("ad-process:update"),
                "content": .string("Process completed"),
                "display": .bool(true),
                "timestamp": .number(Date().timeIntervalSince1970 * 1_000),
                "details": .object([
                    "kind": .string("lifecycle"),
                    "processId": .string(id),
                    "status": .string("exited"),
                    "success": .bool(true)
                ])
            ])
        ])
    }

    private static func subagentStatus(_ text: String?) -> JSONValue {
        var event: [String: JSONValue] = [
            "type": .string("extension_ui_request"),
            "method": .string("setStatus"),
            "statusKey": .string("subagents")
        ]
        if let text { event["statusText"] = .string(text) }
        return .object(event)
    }

    private func makeStore(
        runtime: IntentRuntime,
        factory: @escaping (AgentKind) -> AgentRuntimeProtocol = { _ in IntentRuntime() },
        probe: IntentRuntime? = nil,
        lease: ManualRuntimeLease? = nil,
        runtimeLeaseOperation: RuntimeLeaseOperation? = nil
    ) -> AppStore {
        let store = AppStore(
            repository: IntentRepository(rootURL: root),
            gitService: IntentGitService(),
            runtime: runtime,
            runtimeFactory: factory,
            installedAgentProvider: { [.pi] },
            persistence: AppPersistence(baseURL: root.appendingPathComponent(UUID().uuidString)),
            activityPresenter: ActivityPresenter(),
            probeRuntimeFactory: probe.map { value in { value } },
            isActiveOverride: true,
            runtimeRetirementScheduler: lease.map { value in
                { delay, action in value.schedule(delay: delay, action: action) }
            } ?? { _, _ in {} },
            runtimeLeaseOperation: runtimeLeaseOperation
        )
        store.cachedScheduleService = InMemoryScheduleService()
        return store
    }

    private func summary(_ id: String, cwd: URL) -> SessionSummary {
        var value = SessionSummary(
            id: id,
            fileURL: cwd.appendingPathComponent("\(id).jsonl"),
            cwd: cwd,
            createdAt: Date(), modifiedAt: Date(), name: id, preview: "", messageCount: 0,
            metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }
}

private actor LeaseOperationGateForStore {
    private(set) var requestCount = 0
    private(set) var releaseCount = 0
    private var shouldBlock = false
    private var notFoundFailures = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func blockAcquire() { shouldBlock = true }
    func failNextNotFound(_ count: Int) { notFoundFailures = max(0, count) }

    func perform(path: String, request: LeaseRequest) async throws -> LeaseResponse {
        if request.release == true {
            releaseCount += 1
            return LeaseResponse(leased: false)
        }
        requestCount += 1
        if notFoundFailures > 0 {
            notFoundFailures -= 1
            throw PiDeskClientError.notFound("thread")
        }
        if shouldBlock {
            shouldBlock = false
            await withCheckedContinuation { waiter = $0 }
        }
        return LeaseResponse(
            leased: true, owner: request.owner, expiresAt: Date().addingTimeInterval(60)
        )
    }

    func releaseAcquire() {
        waiter?.resume()
        waiter = nil
    }

    func counts() -> (requests: Int, releases: Int) {
        (requestCount, releaseCount)
    }
}
