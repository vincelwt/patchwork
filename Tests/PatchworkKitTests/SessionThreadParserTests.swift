import XCTest
@testable import PatchworkKit

final class SessionThreadParserTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("patchworkkit-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func write(_ lines: [String], name: String = "session.jsonl") -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func messageLine(role: String, text: String, timestampMs: Int = 1_700_000_000_000, id: String = UUID().uuidString, isError: Bool = false) -> String {
        """
        {"type":"message","id":"\(id)","message":{"role":"\(role)","content":"\(text)","timestamp":\(timestampMs),"isError":\(isError)}}
        """
    }

    // MARK: - thread(at:)

    func testExplicitSessionInfoNameWinsOverFirstUserMessage() throws {
        let url = write([
            #"{"type":"session","id":"sess-1","cwd":"/Users/x/code","timestamp":"2026-01-01T09:00:00.000Z"}"#,
            #"{"type":"session_info","id":"e1","name":"Nightly triage"}"#,
            messageLine(role: "user", text: "Please check CI", id: "e2")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.name, "Nightly triage")
        XCTAssertEqual(thread.id, "sess-1")
        XCTAssertEqual(thread.cwd, "/Users/x/code")
        XCTAssertEqual(thread.folder, "code")
    }

    func testTitleFallsBackToFirstUserMessageWhenNoExplicitName() throws {
        let url = write([
            #"{"type":"session","id":"sess-2","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "Investigate the flaky test suite please", id: "e1")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.name, "Investigate the flaky test suite please")
    }

    func testPreviewIsLastAssistantMessageNotFirstUserMessage() throws {
        // The doc defines Thread.preview as "first line of the last assistant message" —
        // deliberately different from the app's own sidebar preview (first user prompt).
        let url = write([
            #"{"type":"session","id":"sess-3","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "What is 2+2?", timestampMs: 1, id: "e1"),
            messageLine(role: "assistant", text: "It is 4.", timestampMs: 2, id: "e2"),
            messageLine(role: "user", text: "And 3+3?", timestampMs: 3, id: "e3"),
            messageLine(role: "assistant", text: "It is 6.", timestampMs: 4, id: "e4")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.preview, "It is 6.")
    }

    func testCostAccumulatesAcrossMessagesAndCompaction() throws {
        let url = write([
            #"{"type":"session","id":"sess-4","cwd":"/Users/x/code"}"#,
            #"{"type":"message","id":"e1","message":{"role":"assistant","content":"ok","usage":{"cost":{"total":0.5}}}}"#,
            #"{"type":"compaction","id":"e2","summary":"trimmed","usage":{"cost":{"total":0.25}}}"#
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.cost ?? 0, 0.75, accuracy: 0.0001)
    }

    func testMissingSessionEntryFallsBackToFilenameAndFileCwd() throws {
        let url = write([messageLine(role: "user", text: "hi", id: "e1")], name: "019f9dea-abc.jsonl")
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertEqual(thread.id, "019f9dea-abc")
        XCTAssertEqual(thread.cwd, tempDirectory.standardizedFileURL.path)
    }

    func testEmptyFileThrowsRatherThanProducingAPhantomThread() throws {
        let url = write([])
        XCTAssertThrowsError(try SessionThreadParser.thread(at: url))
    }

    func testDefaultsForRunningUnreadArchivedAreFalseForTheCallerToOverlay() throws {
        let url = write([
            #"{"type":"session","id":"sess-5","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "hi", id: "e1")
        ])
        let thread = try SessionThreadParser.thread(at: url)
        XCTAssertFalse(thread.running)
        XCTAssertFalse(thread.unread)
        XCTAssertFalse(thread.archived)
        XCTAssertNil(thread.contextPercent)
    }

    // MARK: - messages(at:limit:)

    func testMessagesReturnsOnlyTheLastNInFileOrder() throws {
        let lines = (1...10).map { messageLine(role: $0 % 2 == 0 ? "assistant" : "user", text: "msg \($0)", timestampMs: $0, id: "e\($0)") }
        let url = write([#"{"type":"session","id":"sess-6","cwd":"/Users/x/code"}"#] + lines)
        let messages = try SessionThreadParser.messages(at: url, limit: 3)
        XCTAssertEqual(messages.map(\.text), ["msg 8", "msg 9", "msg 10"])
    }

    func testMessagesMapsRolesAndBashExecutionToToolResult() throws {
        let url = write([
            #"{"type":"session","id":"sess-7","cwd":"/Users/x/code"}"#,
            messageLine(role: "user", text: "run ls", id: "e1"),
            messageLine(role: "bashExecution", text: "file1 file2", id: "e2"),
            messageLine(role: "assistant", text: "done", id: "e3")
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.map(\.role), [.user, .toolResult, .assistant])
    }

    func testMessagesSynthesizesSystemEntriesForCompactionAndBranchSummary() throws {
        let url = write([
            #"{"type":"session","id":"sess-8","cwd":"/Users/x/code"}"#,
            #"{"type":"compaction","id":"e1","summary":"trimmed the middle","timestamp":1}"#,
            #"{"type":"branch_summary","id":"e2","summary":"forked here","timestamp":2}"#
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].text.contains("trimmed the middle"))
        XCTAssertTrue(messages[1].text.contains("forked here"))
    }

    func testMessagesMarksErrorFlag() throws {
        let url = write([
            #"{"type":"session","id":"sess-9","cwd":"/Users/x/code"}"#,
            messageLine(role: "assistant", text: "boom", id: "e1", isError: true)
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.first?.isError, true)
    }

    func testMessagesToleratesUnknownEntryTypesByIgnoringThem() throws {
        let url = write([
            #"{"type":"session","id":"sess-10","cwd":"/Users/x/code"}"#,
            #"{"type":"a_future_entry_type","id":"e1","payload":{"whatever":true}}"#,
            messageLine(role: "user", text: "still works", id: "e2")
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages.map(\.text), ["still works"])
    }

    func testMessagesZeroLimitReturnsEmpty() throws {
        let url = write([messageLine(role: "user", text: "hi", id: "e1")])
        XCTAssertEqual(try SessionThreadParser.messages(at: url, limit: 0), [])
    }

    func testDialoguePagesExcludeToolsAndOffsetAfterFiltering() throws {
        let url = write([
            messageLine(role: "user", text: "u1", id: "e1"),
            messageLine(role: "assistant", text: "a1", id: "e2"),
            messageLine(role: "toolResult", text: "large tool result", id: "e3"),
            messageLine(role: "user", text: "u2", id: "e4"),
            messageLine(role: "assistant", text: "a2", id: "e5")
        ])
        let newest = try SessionThreadParser.messagePage(
            at: url, limit: 2, offset: 0, conversationOnly: true
        )
        XCTAssertEqual(newest.messages.map(\.text), ["u2", "a2"])
        XCTAssertEqual(newest.nextOffset, 2)

        let older = try SessionThreadParser.messagePage(
            at: url, limit: 2, offset: 2, conversationOnly: true
        )
        XCTAssertEqual(older.messages.map(\.text), ["u1", "a1"])
        XCTAssertNil(older.nextOffset)
    }

    func testMessagesReadOnlyTheTailOfALargeSession() throws {
        let hugeIgnoredRecord = String(repeating: "x", count: SessionThreadParser.initialTailBytes + 1_024)
        let url = write([
            hugeIgnoredRecord,
            messageLine(role: "user", text: "older", id: "old"),
            imageContentLine(id: "new", data: Self.tinyPNG)
        ])

        let messages = try SessionThreadParser.messages(at: url, limit: 2)
        XCTAssertEqual(messages.map(\.text), ["older", "see this\n[image]"])
        XCTAssertNotNil(try SessionThreadParser.tailMessages(at: url, limit: 2), "the bounded tail was sufficient; no full scan was needed")
        let imageID = try XCTUnwrap(messages.last?.images.first?.id)
        XCTAssertTrue(imageID.hasPrefix("b"), "tail projections identify the record by byte offset")
        XCTAssertNotNil(try SessionThreadParser.image(at: url, imageId: imageID), "byte-offset image lookup seeks directly to the record")
    }

    // MARK: - SessionScanner

    func testScannerFindsRootAndOneLevelProjectFilesButNotDeeperNesting() throws {
        let root = tempDirectory!
        let project = root.appendingPathComponent("--Users-x-code--", isDirectory: true)
        let deep = project.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        try "{}".write(to: root.appendingPathComponent("top.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: project.appendingPathComponent("child.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: deep.appendingPathComponent("nested.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

        let found = Set(SessionScanner.discoverSessionFiles(rootURL: root).map(\.lastPathComponent))
        XCTAssertEqual(found, ["top.jsonl", "child.jsonl"])
    }

    func testScannerReturnsEmptyForMissingRootInsteadOfThrowing() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist")
        XCTAssertEqual(SessionScanner.discoverSessionFiles(rootURL: missing), [])
    }

    // MARK: - Structured blocks

    func testAssistantBlocksKeepOrderToolIdentityAndArgumentsWhileTextStaysFlattened() throws {
        let url = write([
            """
            {"type":"message","id":"m1","message":{"role":"assistant","timestamp":1,"stopReason":"toolUse","content":[\
            {"type":"thinking","thinking":"weigh the options"},\
            {"type":"text","text":"Running the suite."},\
            {"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"swift test"}}]}}
            """
        ])
        let message = try XCTUnwrap(try SessionThreadParser.messages(at: url, limit: 10).first)

        let blocks = try XCTUnwrap(message.blocks)
        XCTAssertEqual(blocks.map(\.type), ["thinking", "text", "toolCall"], "order is what separates narration from the answer")
        XCTAssertEqual(blocks[0].text, "weigh the options")
        XCTAssertEqual(blocks[1].text, "Running the suite.")
        XCTAssertEqual(blocks[2].callId, "call_1")
        XCTAssertEqual(blocks[2].name, "bash")
        XCTAssertEqual(blocks[2].arguments?.contains("swift test"), true)
        XCTAssertEqual(message.stopReason, "toolUse")

        // The flattened projection older clients read is untouched.
        XCTAssertEqual(message.text, "[thinking] weigh the options\nRunning the suite.\n[tool: bash]")
    }

    func testToolResultsCarryTheCallTheyAnswerAndNoBlocks() throws {
        let url = write([
            """
            {"type":"message","id":"m1","message":{"role":"toolResult","timestamp":1,"toolCallId":"call_1","toolName":"bash","content":"42 tests passed"}}
            """
        ])
        let message = try XCTUnwrap(try SessionThreadParser.messages(at: url, limit: 10).first)
        XCTAssertEqual(message.toolCallId, "call_1")
        XCTAssertEqual(message.toolName, "bash")
        XCTAssertEqual(message.text, "42 tests passed")
        XCTAssertNil(message.blocks, "only an assistant turn's block order says something `text` cannot")
    }

    func testCompactionSplitsTitleFromSummaryWhileKeepingItsFlattenedLine() throws {
        let url = write([
            #"{"type":"compaction","id":"e1","summary":"dropped the middle","timestamp":1}"#,
            #"{"type":"branch_summary","id":"e2","summary":"forked here","timestamp":2}"#
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages[0].blocks?.compactMap(\.text), ["Context compacted", "dropped the middle"])
        XCTAssertEqual(messages[0].text, "Context compacted: dropped the middle")
        XCTAssertEqual(messages[1].blocks?.compactMap(\.text), ["Branch summary", "forked here"])
    }

    func testBlocksShareOneBoundedTextBudgetAndSurviveUnknownBlockKinds() throws {
        let long = String(repeating: "x", count: 3_000)
        let url = write([
            """
            {"type":"message","id":"m1","message":{"role":"assistant","timestamp":1,"content":[\
            {"type":"text","text":"\(long)"},{"type":"text","text":"\(long)"},\
            {"type":"image","mimeType":"image/png","data":""},\
            {"type":"a_future_block","whatever":true},\
            {"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"\(long)"}}]}}
            """
        ])
        let blocks = try XCTUnwrap(try SessionThreadParser.messages(at: url, limit: 10).first?.blocks)

        XCTAssertEqual(blocks.map(\.type), ["text", "text", "image", "a_future_block", "toolCall"], "an unknown kind keeps its place")
        let carried = blocks.compactMap(\.text).reduce(0) { $0 + $1.count }
            + blocks.compactMap(\.arguments).reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(carried, SessionThreadParser.blockTextLimit, "one message cannot outgrow the shared budget")
        XCTAssertEqual(blocks[4].callId, "call_1", "a tool call keeps its identity even once the budget is spent")
    }

    func testStructuredMetadataAndCompactionBlocksAreExactlyBounded() throws {
        let long = String(repeating: "x", count: SessionThreadParser.blockMetadataLimit + 100)
        let summary = String(repeating: "s", count: SessionThreadParser.blockTextLimit + 100)
        let url = write([
            """
            {"type":"message","id":"m1","message":{"role":"assistant","stopReason":"\(long)","content":[\
            {"type":"toolCall","id":"\(long)","name":"\(long)","arguments":{}},\
            {"type":"\(long)"}]}}
            """,
            """
            {"type":"message","id":"m2","message":{"role":"toolResult","toolCallId":"\(long)","toolName":"\(long)","content":"done"}}
            """,
            """
            {"type":"message","id":"m3","message":{"role":"\(long)","content":"future"}}
            """,
            #"{"type":"compaction","id":"c1","summary":"\#(summary)"}"#
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        let call = try XCTUnwrap(messages[0].blocks?.first)
        let future = try XCTUnwrap(messages[0].blocks?.last)

        XCTAssertEqual(call.callId?.count, SessionThreadParser.blockMetadataLimit)
        XCTAssertEqual(call.name?.count, SessionThreadParser.blockMetadataLimit)
        XCTAssertEqual(future.type.count, SessionThreadParser.blockMetadataLimit)
        XCTAssertEqual(messages[0].stopReason?.count, SessionThreadParser.blockMetadataLimit)
        XCTAssertEqual(messages[1].toolCallId, call.callId, "bounded call ids still match their result")
        XCTAssertEqual(messages[1].toolName?.count, SessionThreadParser.blockMetadataLimit)
        XCTAssertEqual(messages[2].role.rawValue.count, SessionThreadParser.blockMetadataLimit)
        XCTAssertLessThanOrEqual(
            messages[3].blocks?.compactMap(\.text).reduce(0) { $0 + $1.count } ?? Int.max,
            SessionThreadParser.blockTextLimit
        )
    }

    func testRichFieldsAreOptionalOnTheWireInBothDirections() throws {
        // An older daemon's payload: none of the new keys, and it must still decode.
        let legacy = Data(#"{"id":"m1","role":"assistant","text":"hello","at":"2026-01-01T00:00:00.000Z"}"#.utf8)
        let decoded = try PatchworkJSON.decoder.decode(Message.self, from: legacy)
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertNil(decoded.blocks)
        XCTAssertNil(decoded.toolCallId)
        XCTAssertNil(decoded.stopReason)

        // And a message with nothing structured to say does not put empty keys on the wire.
        let json = String(decoding: try PatchworkJSON.encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(json.contains("blocks"))
        XCTAssertFalse(json.contains("toolCallId"))

        // A block kind from a newer daemon round-trips instead of failing the whole message.
        let future = Data(#"{"id":"m2","role":"assistant","text":"hi","blocks":[{"type":"videoClip","text":"x"}]}"#.utf8)
        XCTAssertEqual(try PatchworkJSON.decoder.decode(Message.self, from: future).blocks?.first?.type, "videoClip")
    }

    // MARK: - Real session directory smoke test

    /// Mirrors the app's own `testInstalledSessionDirectorySmokeWhenRequested` convention
    /// (`Tests/PatchworkTests/SessionParserTests.swift`): skipped by default, opt in with
    /// `PATCHWORK_REAL_SESSION_SMOKE=1 swift test` to scan whatever sessions are actually
    /// installed and prove the parser survives real, messy data instead of only fixtures.
    func testInstalledSessionDirectorySmokeWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["PATCHWORK_REAL_SESSION_SMOKE"] == "1" else {
            throw XCTSkip("Set PATCHWORK_REAL_SESSION_SMOKE=1 to scan the installed Pi session directory")
        }
        let root = SessionScanner.defaultRootURL()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("No installed Pi session directory")
        }
        let files = SessionScanner.discoverSessionFiles(rootURL: root)
        XCTAssertFalse(files.isEmpty)

        var parsed = 0
        for file in files {
            let thread = try SessionThreadParser.thread(at: file)
            XCTAssertFalse(thread.id.isEmpty)
            XCTAssertFalse(thread.cwd.isEmpty)
            let messages = try SessionThreadParser.messages(at: file, limit: 20)
            XCTAssertLessThanOrEqual(messages.count, 20)
            parsed += 1
        }
        XCTAssertEqual(parsed, files.count, "every real session file must parse without throwing")
    }
    // MARK: - Inline images

    /// A 1x1 PNG: small, real, and decodable, so the round trip proves actual bytes rather than
    /// an opaque string being handed back.
    private static let tinyPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func imageContentLine(id: String, role: String = "assistant", data: String, mime: String = "image/png", fileName: String? = nil) -> String {
        let name = fileName.map { #","fileName":"\#($0)""# } ?? ""
        return """
        {"type":"message","id":"\(id)","message":{"role":"\(role)","timestamp":1,"content":[{"type":"text","text":"see this"},{"type":"image","mimeType":"\(mime)","data":"\(data)"\(name)}]}}
        """
    }

    func testAssistantContentImageIsProjectedAsFetchableMetadataNotBase64() throws {
        let url = write([imageContentLine(id: "m1", data: Self.tinyPNG, fileName: "shot.png")])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)

        XCTAssertEqual(messages.count, 1)
        let image = try XCTUnwrap(messages[0].images.first)
        XCTAssertEqual(image.status, .ok)
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.fileName, "shot.png")
        XCTAssertGreaterThan(image.byteCount, 0)
        XCTAssertEqual(image.id, "b0-c1", "record byte offset plus the content block index")

        // The transcript itself must stay small: no payload travels inside the message.
        let encoded = try PatchworkJSON.encoder.encode(messages)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(Self.tinyPNG))
    }

    func testToolResultAttachmentImagesAreProjectedToo() throws {
        let url = write([
            """
            {"type":"message","id":"m1","message":{"role":"toolResult","timestamp":1,"content":"screenshot taken","attachments":[{"type":"image","mimeType":"image/png","content":"\(Self.tinyPNG)"}]}}
            """
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages[0].images.map(\.id), ["b0-a0"])
        XCTAssertEqual(messages[0].images.first?.status, .ok)
    }

    func testImageRoundTripsThroughTheByIDLookup() throws {
        let url = write([imageContentLine(id: "m1", data: Self.tinyPNG, fileName: "shot.png")])
        let image = try XCTUnwrap(SessionThreadParser.image(at: url, imageId: "0-c1"))
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.fileName, "shot.png")
        XCTAssertEqual(Data(base64Encoded: image.data), Data(base64Encoded: Self.tinyPNG))
        XCTAssertEqual(image.byteCount, Data(base64Encoded: Self.tinyPNG)?.count)
    }

    func testUnknownOrMalformedImageIDsResolveToNilRatherThanThrowing() throws {
        let url = write([imageContentLine(id: "m1", data: Self.tinyPNG)])
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "0-c9"), "no such block")
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "0-c0"), "that block is text, not an image")
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "99-c1"), "no such record")
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "garbage"))
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "-1-c0"))
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: ""))
    }

    func testAnEmptyOrUndecodableImageStaysVisibleAsAnInvalidPlaceholder() throws {
        let url = write([
            imageContentLine(id: "m1", data: ""),
            imageContentLine(id: "m2", data: "!!!!not base64!!!!")
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages[0].images.first?.status, .invalid)
        XCTAssertNotNil(messages[0].images.first?.note, "a placeholder must say why")
        // Undecodable but small: listed as ok, and the fetch is what refuses it.
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "1-c1"))
    }

    func testAnOversizedImageIsReportedAsTooLargeAndIsNeverServed() throws {
        let oversized = String(repeating: "A", count: (SessionThreadParser.imageByteLimit / 3 * 4) + 1_024)
        let url = write([imageContentLine(id: "m1", data: oversized)])

        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages[0].images.first?.status, .tooLarge)
        XCTAssertNotNil(messages[0].images.first?.note)
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "0-c1"), "the bound is enforced on the way out too")
    }

    func testImagesPerMessageAreCapped() throws {
        let blocks = (0..<(SessionThreadParser.imagesPerMessageLimit + 4))
            .map { _ in #"{"type":"image","mimeType":"image/png","data":"\#(Self.tinyPNG)"}"# }
            .joined(separator: ",")
        let url = write([#"{"type":"message","id":"m1","message":{"role":"assistant","timestamp":1,"content":[\#(blocks)]}}"#])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages[0].images.count, SessionThreadParser.imagesPerMessageLimit)
    }

    func testPerRequestImageBudgetKeepsTheNewestAndMarksTheRestOmitted() throws {
        let lines = (0..<12).map { index in
            let blocks = (0..<6).map { _ in #"{"type":"image","mimeType":"image/png","data":"\#(Self.tinyPNG)"}"# }.joined(separator: ",")
            return #"{"type":"message","id":"m\#(index)","message":{"role":"assistant","timestamp":1,"content":[\#(blocks)]}}"#
        }
        let url = write(lines)
        let messages = try SessionThreadParser.messages(at: url, limit: 50)

        let all = messages.flatMap(\.images)
        XCTAssertEqual(all.count, 72, "every image is still listed")
        XCTAssertEqual(all.filter { $0.status == .ok }.count, SessionThreadParser.imagesPerRequestLimit)
        XCTAssertTrue(all.filter { $0.status == .omitted }.allSatisfy { $0.note != nil })
        XCTAssertTrue(messages.last?.images.allSatisfy { $0.status == MessageImageStatus.ok } ?? false, "the newest images win")
        XCTAssertTrue(messages.first?.images.allSatisfy { $0.status == MessageImageStatus.omitted } ?? false)
    }

    func testAMessageWithNoImagesCarriesAnEmptyArray() throws {
        let url = write([messageLine(role: "assistant", text: "just text")])
        XCTAssertEqual(try SessionThreadParser.messages(at: url, limit: 10)[0].images, [])
    }

    func testBase64ValidationAcceptsRealPayloadsAndRejectsMalformedOnes() {
        XCTAssertTrue(SessionThreadParser.isWellFormedBase64(Self.tinyPNG))
        XCTAssertTrue(SessionThreadParser.isWellFormedBase64("AAAA"))
        XCTAssertTrue(SessionThreadParser.isWellFormedBase64("AA=="))
        XCTAssertTrue(SessionThreadParser.isWellFormedBase64("AAA="))

        XCTAssertFalse(SessionThreadParser.isWellFormedBase64(""), "empty is not an image")
        XCTAssertFalse(SessionThreadParser.isWellFormedBase64("AAA"), "length must be a multiple of four")
        XCTAssertFalse(SessionThreadParser.isWellFormedBase64("A!AA"), "outside the alphabet")
        XCTAssertFalse(SessionThreadParser.isWellFormedBase64("A A A"), "whitespace is not padding")
        XCTAssertFalse(SessionThreadParser.isWellFormedBase64("A==="), "at most two pad characters")
        XCTAssertFalse(SessionThreadParser.isWellFormedBase64("AA=A"), "padding only at the end")
        XCTAssertFalse(SessionThreadParser.isWellFormedBase64("AA-_"), "base64url is not what Pi writes")
    }

    func testAnImageIsOnlyMarkedOkWhenItsEncodingActuallyDecodes() throws {
        // Right length, right size, wrong alphabet: advertising this as `ok` would promise a
        // client a thumbnail that can only ever fail to load.
        let url = write([imageContentLine(id: "m1", data: "!!!!!!!!")])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        XCTAssertEqual(messages[0].images.first?.status, .invalid)
        XCTAssertNil(try SessionThreadParser.image(at: url, imageId: "0-c1"))
    }

    func testAnOkImageIsAlwaysActuallyFetchable() throws {
        let url = write([
            imageContentLine(id: "m1", data: Self.tinyPNG),
            imageContentLine(id: "m2", data: "AAA"),
            imageContentLine(id: "m3", data: "not base64 at all!!")
        ])
        let messages = try SessionThreadParser.messages(at: url, limit: 10)
        for message in messages {
            for image in message.images where image.status == .ok {
                XCTAssertNotNil(
                    try SessionThreadParser.image(at: url, imageId: image.id),
                    "\(image.id) was advertised as ok but does not resolve"
                )
            }
        }
    }

    func testDecodingAMessageFromAnOlderDaemonWithNoImagesFieldSucceeds() throws {
        let json = Data(#"{"id":"m1","role":"assistant","text":"hi","at":"2026-01-01T00:00:00.000Z"}"#.utf8)
        let message = try PatchworkJSON.decoder.decode(Message.self, from: json)
        XCTAssertEqual(message.images, [])
    }
}

final class ThreadPreviewProseTests: XCTestCase {
    func testAPreviewShowsWhatPiSaidNotItsReasoning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("2026-07-26T10-00-00-000Z_abc.jsonl")
        let lines = [
            #"{"type":"session","id":"s","cwd":"/Users/x/code","timestamp":"2026-07-26T10:00:00.000Z"}"#,
            #"{"type":"message","id":"u","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
            #"{"type":"message","id":"a","message":{"role":"assistant","content":[{"type":"thinking","thinking":"weighing options"},{"type":"text","text":"Deployed and verified."}]}}"#
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let thread = try SessionThreadParser.thread(at: file)
        XCTAssertEqual(thread.preview, "Deployed and verified.")
        XCTAssertFalse(thread.preview.contains("[thinking]"))
    }

    func testAReasoningOnlyTurnStillPreviewsSomething() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("2026-07-26T10-00-00-000Z_def.jsonl")
        let lines = [
            #"{"type":"session","id":"s","cwd":"/Users/x/code","timestamp":"2026-07-26T10:00:00.000Z"}"#,
            #"{"type":"message","id":"u","message":{"role":"user","content":[{"type":"text","text":"do it"}]}}"#,
            #"{"type":"message","id":"a","message":{"role":"assistant","content":[{"type":"thinking","thinking":"still working"}]}}"#
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let thread = try SessionThreadParser.thread(at: file)
        XCTAssertFalse(thread.preview.isEmpty, "a mid-turn thread must still preview something")
    }
}
