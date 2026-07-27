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

    // MARK: - Replay protection

    func testRepeatingASubmissionReplaysTheAnswerInsteadOfPromptingPiTwice() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"hello","clientId":"web-abc123"}"#

        let first = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))
        let second = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))

        XCTAssertEqual(first.runId, second.runId, "the retry gets the original answer")
        XCTAssertEqual(first, second)
    }

    /// The property that actually matters: a repeat never reaches the runner. Asserted against the
    /// executor rather than the queue's counters, which drain as soon as a fake run finishes.
    func testARepeatedSubmissionNeverReachesTheRunner() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"hello","clientId":"web-once"}"#

        _ = await send("POST", "/v1/threads/sess-1/messages", body: body)
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1)

        _ = await send("POST", "/v1/threads/sess-1/messages", body: body)
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 1, "Pi was prompted once, however many times the phone asked")
    }

    /// Lets an enqueued fake run start and finish. The fake executor returns immediately, so a few
    /// short yields are enough; the assertions above it are what make a regression visible.
    private func settle() async throws {
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 5_000_000)
            if await core.runQueue.activeCount() == 0, await core.runQueue.queuedCount() == 0 { return }
        }
    }

    func testARepeatedSteerIsNotDeliveredIntoTheLiveTurnASecondTime() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)
        let body = #"{"text":"stop","delivery":"steer","clientId":"web-steer1"}"#

        let first = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))
        let second = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: body))

        XCTAssertEqual(first, second)
        XCTAssertEqual(runtime.delivered.count, 1, "Pi was steered once, however many times the phone asked")
    }

    func testADifferentClientIDIsADifferentMessage() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let one = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"one","clientId":"web-a"}"#))
        let two = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"two","clientId":"web-b"}"#))
        XCTAssertNotEqual(one.runId, two.runId)
        try await settle()
        XCTAssertEqual(executor.executedJobs.count, 2)
    }

    func testAMessageWithNoClientIDStillWorksButGetsNoReplayProtection() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let one = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello"}"#))
        let two = try decode(SendMessageResponse.self, await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"hello"}"#))
        XCTAssertNotEqual(one.runId, two.runId, "an older client behaves exactly as before")
    }

    func testAFailedSubmissionDoesNotLockOutAnHonestRetry() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let runtime = FakeLiveRuntime()
        runtime.result = .rejected("Nothing to steer.")
        liveSessions.register(threadID: "sess-1", runID: "run_live", handle: runtime)
        let body = #"{"text":"x","delivery":"steer","clientId":"web-retry"}"#

        let rejected = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(rejected.status, 409)

        // Pi refused, so nothing happened and the same submission must be allowed to try again.
        liveSessions.unregister(threadID: "sess-1", runID: "run_live")
        let retry = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(retry.status, 200)
    }

    func testAMalformedClientIDIsRejected() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let bad = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","clientId":"has spaces"}"#)
        XCTAssertEqual(bad.status, 400)

        let long = String(repeating: "a", count: 129)
        let tooLong = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"x","clientId":"\#(long)"}"#)
        XCTAssertEqual(tooLong.status, 400)
    }

    // MARK: - Attachments

    func testAttachmentsAreRejectedRatherThanAcceptedAndDropped() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let body = #"{"text":"look","attachments":[{"type":"image","data":"\#(Self.tinyPNG)","mimeType":"image/png"}]}"#

        let response = await send("POST", "/v1/threads/sess-1/messages", body: body)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("attachments_unsupported"))

        try await settle()
        XCTAssertTrue(executor.executedJobs.isEmpty, "never reported as sent, and never silently sent without them")
    }

    func testAnEmptyAttachmentsArrayIsNotAnAttachment() async throws {
        _ = TestSupport.writeSessionFile(in: directory, id: "sess-1", cwd: directory.path)
        let response = await send("POST", "/v1/threads/sess-1/messages", body: #"{"text":"plain","attachments":[]}"#)
        XCTAssertEqual(response.status, 200)
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

    func testAnOversizedStateFileIsRefusedRatherThanRead() async throws {
        // A corrupted or hostile state.json must not be pulled into memory on every folder
        // request. The guard is on the file size, so the check never allocates the contents.
        let url = directory.appendingPathComponent("state.json")
        let padding = String(repeating: " ", count: AppStatePeek.maxStateBytes + 1_024)
        try (#"{"virtualFolders":[{"id":"f1","name":"Review","createdAt":0}]}"# + padding)
            .write(to: url, atomically: true, encoding: .utf8)

        let response = await send("GET", "/v1/folders")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try decode(FolderTreeResponse.self, response).folders.isEmpty)
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

    func testAResponseFieldMustSuitTheDialogsMethod() async throws {
        let recorder = registerDialog(id: "s1")
        let confirmedOnSelect = await send("POST", "/v1/interactions/s1/respond", body: #"{"confirmed":true}"#)
        XCTAssertEqual(confirmedOnSelect.status, 400, "a yes is not an option choice")

        let both = await send("POST", "/v1/interactions/s1/respond", body: #"{"value":"Alpha","confirmed":true}"#)
        XCTAssertEqual(both.status, 400, "two answers is no answer")

        let mixedCancel = await send("POST", "/v1/interactions/s1/respond", body: #"{"value":"Alpha","cancelled":true}"#)
        XCTAssertEqual(mixedCancel.status, 400)
        XCTAssertTrue(recorder.all.isEmpty, "Pi is left waiting rather than answered ambiguously")

        _ = registerDialog(id: "c1", method: .confirm, options: [])
        let valueOnConfirm = await send("POST", "/v1/interactions/c1/respond", body: #"{"value":"yes"}"#)
        XCTAssertEqual(valueOnConfirm.status, 400)
    }

    func testADialogMethodThisBuildCannotAnswerIsVisibleAndOnlyCancellable() async throws {
        let recorder = registerDialog(id: "x1", method: .other("holographicPicker"), options: [])

        let listed = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(listed.interactions.map(\.id), ["x1"], "an unknown blocking dialog must still be seen")

        let answered = await send("POST", "/v1/interactions/x1/respond", body: #"{"value":"guess"}"#)
        XCTAssertEqual(answered.status, 400)
        XCTAssertTrue(recorder.all.isEmpty)

        let cancelled = await send("POST", "/v1/interactions/x1/respond", body: #"{"cancelled":true}"#)
        XCTAssertEqual(cancelled.status, 200, "cancelling is always safe, and unblocks the run")
    }

    func testAResponseThatNeverReachedPiIsNotReportedAsAnswered() async throws {
        let recorder = ResponseRecorder()
        _ = interactions.register(
            PendingInteraction(
                id: "w1", runId: "run_1", threadId: "sess-1", method: .input, title: "Type",
                expiresAt: Date().addingTimeInterval(600)
            ),
            responder: { _ in throw RunnerError.ioFailure("stdin closed") }
        )

        let response = await send("POST", "/v1/interactions/w1/respond", body: #"{"value":"hello"}"#)
        XCTAssertEqual(response.status, 503, "the reader must not believe they answered it")
        XCTAssertTrue(recorder.all.isEmpty)

        let still = try decode(InteractionListResponse.self, await send("GET", "/v1/interactions"))
        XCTAssertEqual(still.interactions.count, 1, "and it stays answerable, because Pi is still blocked")
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
