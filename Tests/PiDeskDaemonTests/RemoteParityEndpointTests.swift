import XCTest
import PiDeskKit
@testable import PiDeskDaemon

/// The four parity endpoints, driven straight through `DaemonRouter` — the same code a socket,
/// the loopback listener, and the hosted relay all funnel into, minus the transport. Every run
/// here uses `FakeRunExecutor` and every steer uses `FakeLiveRuntime`: nothing spawns `pi`.
final class RemoteParityEndpointTests: XCTestCase {
    private var directory: URL!
    private var core: DaemonCore!
    private var router: DaemonRouter!
    private var executor: FakeRunExecutor!
    private var interactions: InteractionRegistry!
    private var liveSessions: LiveSessionRegistry!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
        executor = FakeRunExecutor()
        interactions = InteractionRegistry()
        liveSessions = LiveSessionRegistry()
        core = TestSupport.makeCore(in: directory, executor: executor, interactions: interactions, liveSessions: liveSessions)
        router = DaemonRouter(routes: Routes.all(core))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func send(_ method: String, _ path: String, body: String? = nil, query: [String: String] = [:]) async -> HTTPResponse {
        await router.handle(HTTPRequest(
            method: method, path: path, query: query, headers: [:],
            body: body.map { Data($0.utf8) } ?? Data(), origin: .unixSocket
        ))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try PiDeskJSON.decoder.decode(type, from: response.body)
    }

    private static let tinyPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    // MARK: - Delivery

    func testSteerGoesToTheLiveTurnAndIsNeverQueuedBehindIt() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"stop that","delivery":"steer"}"#)
        XCTAssertEqual(response.status, 200)

        let decoded = try decode(SendMessageResponse.self, response)
        XCTAssertEqual(decoded.runId, "run_live", "the answer names the run that was interrupted")
        XCTAssertEqual(decoded.queued, false)
        XCTAssertEqual(decoded.delivery, .steer)
        XCTAssertEqual(runtime.delivered.map(\.command), ["steer"])
        XCTAssertEqual(runtime.delivered.map(\.message), ["stop that"])

        let queued = await core.runQueue.queuedCount()
        let active = await core.runQueue.activeCount()
        XCTAssertEqual(queued + active, 0, "an explicit steer must never become a queued prompt")
    }

    func testFollowUpUsesPisOwnFollowUpCommandWhenALiveTurnExists() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"and also","delivery":"followUp"}"#)
        XCTAssertEqual(try decode(SendMessageResponse.self, response).delivery, .followUp)
        XCTAssertEqual(runtime.delivered.map(\.command), ["follow_up"])
    }

    func testSteerWithNoLiveTurnIsReportedAsAnOrdinaryPromptNotAsSteering() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello","delivery":"steer"}"#)
        let decoded = try decode(SendMessageResponse.self, response)
        XCTAssertEqual(decoded.delivery, .auto, "there was nothing to interrupt, and the answer says so")
        XCTAssertNotEqual(decoded.runId, "run_live")
        XCTAssertNotNil(decoded.runId, "the text still runs, as a normal prompt")
    }

    func testARejectedSteerIsAConflictAndIsNotSilentlyQueuedInstead() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.result = .rejected("Nothing to steer.")
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","delivery":"steer"}"#)
        XCTAssertEqual(response.status, 409)
        let queued = await core.runQueue.queuedCount()
        XCTAssertEqual(queued, 0)
    }

    func testAnUnacknowledgedSteerIsReportedDeliveredRatherThanResent() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.result = .unacknowledged
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","delivery":"steer"}"#)
        XCTAssertEqual(response.status, 200)
        let queued = await core.runQueue.queuedCount()
        let active = await core.runQueue.activeCount()
        XCTAssertEqual(queued + active, 0, "resending is the one thing that could prompt Pi twice")
    }

    func testAWriteFailureFallsBackToTheQueueBecauseNothingReachedPi() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.throwsWriteFailure = true
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)

        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","delivery":"steer"}"#)
        XCTAssertEqual(try decode(SendMessageResponse.self, response).delivery, .auto)
    }

    func testAMessageWithNoDeliveryNeverTouchesTheLiveSession() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)

        _ = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"plain"}"#)
        XCTAssertTrue(runtime.delivered.isEmpty, "an ordinary prompt still queues, exactly as before")
    }

    // MARK: - Images

    func testImageEndpointReturnsBoundedBase64ForAProjectedReference() async throws {
        _ = TestSupport.writeSessionFile(
            in: directory, id: "sess-1", cwd: directory.path,
            lines: [#"{"type":"message","id":"m1","message":{"role":"assistant","timestamp":1,"content":[{"type":"image","mimeType":"image/png","fileName":"shot.png","data":"\#(Self.tinyPNG)"}]}}"#]
        )

        let detail = try decode(ThreadDetailResponse.self, await send("GET", "/v1/threads/sess-1", query: ["messages": "10"]))
        let reference = try XCTUnwrap(detail.messages.first?.images.first)
        XCTAssertEqual(reference.status, .ok)

        let image = try decode(MessageImageResponse.self, await send("GET", "/v1/threads/sess-1/images/\(reference.id)"))
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.fileName, "shot.png")
        XCTAssertEqual(Data(base64Encoded: image.data), Data(base64Encoded: Self.tinyPNG))
    }

    func testUnknownImageIDIs404() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let unknownBlock = await send("GET", "/v1/threads/sess-1/images/0-c0")
        XCTAssertEqual(unknownBlock.status, 404)
        let unknownThread = await send("GET", "/v1/threads/nope/images/0-c0")
        XCTAssertEqual(unknownThread.status, 404)
    }

    // MARK: - Folders

    func testFoldersEndpointIsEmptyWhenTheAppHasNoStateFileAtAll() async throws {
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertTrue(tree.folders.isEmpty)
        XCTAssertTrue(tree.assignments.isEmpty)
    }

    func testFoldersEndpointProjectsLegacyStateWithNoParentKeys() async throws {
        TestSupport.writeAppState(
            in: directory,
            folders: #"[{"id":"f1","name":"Review","createdAt":0}]"#,
            assignments: ["/tmp/a.jsonl": "f1", "/tmp/b.jsonl": "missing"]
        )
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertEqual(tree.folders.map(\.name), ["Review"])
        XCTAssertNil(tree.folders[0].parentId)
        XCTAssertEqual(tree.assignments, ["/tmp/a.jsonl": "f1"], "an assignment to a folder that is gone is dropped")
    }

    func testFoldersEndpointFlattensACycleInsteadOfHangingOrFailing() async throws {
        TestSupport.writeAppState(in: directory, folders: """
        [{"id":"a","name":"A","createdAt":0,"parentID":"virtual:b"},
         {"id":"b","name":"B","createdAt":1,"parentID":"virtual:a"}]
        """)
        let tree = try decode(FolderTreeResponse.self, await send("GET", "/v1/folders"))
        XCTAssertEqual(Set(tree.folders.map(\.id)), ["a", "b"])
        XCTAssertTrue(tree.folders.allSatisfy { $0.depth == 0 })
    }

    func testFoldersEndpointSurvivesAMalformedStateFile() async throws {
        try "{ not json".write(to: directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let response = await send("GET", "/v1/folders")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try decode(FolderTreeResponse.self, response).folders.isEmpty)
    }

    // MARK: - Interactions

    private func registerDialog(id: String = "d1", method: InteractionMethod = .select, options: [String] = ["Alpha", "Beta"]) -> ResponseRecorder {
        let recorder = ResponseRecorder()
        _ = interactions.register(
            PendingInteraction(
                id: id, runId: "run_1", threadId: "sess-1", method: method, title: "Pick one",
                options: options, expiresAt: Date().addingTimeInterval(600),
                choices: options.enumerated().map { InteractionOption(id: $0.offset, value: $0.element, label: $0.element) }
            ),
            responder: { recorder.append($0) }
        )
        return recorder
    }

    func testPendingInteractionsAreListedAndFilterByThread() async throws {
        _ = registerDialog()
        let all = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(all.interactions.map(\.id), ["d1"])
        XCTAssertEqual(all.interactions[0].options, ["Alpha", "Beta"])

        let mine = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions", query: ["threadId": "sess-1"]))
        XCTAssertEqual(mine.interactions.count, 1)
        let other = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions", query: ["threadId": "sess-9"]))
        XCTAssertTrue(other.interactions.isEmpty)
    }

    func testRespondingWithAnExactOptionAnswersPiAndRetiresTheDialog() async throws {
        let recorder = registerDialog()
        let response = await send("POST", "/v1/interactions/d1/respond", body: #"{"value":"Beta"}"#)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(recorder.all.first?["value"]?.stringValue, "Beta")
        XCTAssertEqual(recorder.all.first?["type"]?.stringValue, "extension_ui_response")

        let remaining = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertTrue(remaining.interactions.isEmpty)
    }

    func testASelectValuePisNeverOfferedIsRejectedRatherThanGuessed() async throws {
        let recorder = registerDialog()
        let response = await send("POST", "/v1/interactions/d1/respond", body: #"{"value":"Gamma"}"#)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(recorder.all.isEmpty, "Pi is left waiting rather than answered with a guess")
        let still = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(still.interactions.count, 1, "the dialog stays answerable")
    }

    func testAFreeTextAnswerIsNotOptionCheckedAndIsLengthBounded() async throws {
        let recorder = registerDialog(id: "i1", method: .input, options: [])
        let accepted = await send("POST", "/v1/interactions/i1/respond", body: #"{"value":"1,3"}"#)
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(recorder.all.first?["value"]?.stringValue, "1,3")

        _ = registerDialog(id: "i2", method: .input, options: [])
        let huge = String(repeating: "x", count: 20_001)
        let oversized = await send("POST", "/v1/interactions/i2/respond", body: #"{"value":"\#(huge)"}"#)
        XCTAssertEqual(oversized.status, 400)
    }

    func testAnEmptyBodyIsRejectedButAnExplicitCancellationIsAccepted() async throws {
        let recorder = registerDialog()
        let empty = await send("POST", "/v1/interactions/d1/respond", body: "{}")
        XCTAssertEqual(empty.status, 400)
        XCTAssertTrue(recorder.all.isEmpty)

        let cancelled = await send("POST", "/v1/interactions/d1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(cancelled.status, 200)
        XCTAssertEqual(recorder.all.first?["cancelled"]?.boolValue, true)
    }

    func testRespondingToAnUnknownOrAlreadyAnsweredDialogIs404() async throws {
        _ = registerDialog()
        let unknown = await send("POST", "/v1/interactions/nope/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(unknown.status, 404)
        let first = await send("POST", "/v1/interactions/d1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(first.status, 200)
        let second = await send("POST", "/v1/interactions/d1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(second.status, 404)
    }
}

/// Captures what the daemon would have written back to Pi.
final class ResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: PiJSONValue]] = []
    func append(_ value: [String: PiJSONValue]) { lock.lock(); storage.append(value); lock.unlock() }
    var all: [[String: PiJSONValue]] { lock.lock(); defer { lock.unlock() }; return storage }
}
