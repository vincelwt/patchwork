import Foundation
import PatchworkKit
import XCTest
@testable import Patchwork

// MARK: - Pure palette logic

final class SlashCommandPaletteTests: XCTestCase {
    private func content(_ text: String, attachments: [ImageAttachment] = []) -> ComposerContent {
        ComposerContent(text: text, attachments: attachments)
    }

    func testPaletteOpensOnlyForABareLeadingSlashToken() {
        XCTAssertEqual(SlashCommandPalette.query(in: content("/")), "")
        XCTAssertEqual(SlashCommandPalette.query(in: content("/mo")), "mo")
        XCTAssertNil(SlashCommandPalette.query(in: content("")))
        XCTAssertNil(SlashCommandPalette.query(in: content("ship /mode")), "not at the start")
        XCTAssertNil(SlashCommandPalette.query(in: content("/mode fast")), "arguments are a prompt")
        XCTAssertNil(SlashCommandPalette.query(in: content("/mode\nsecond line")))
        XCTAssertNil(
            SlashCommandPalette.query(in: content("/mode", attachments: [
                ImageAttachment(
                    data: Data("x".utf8),
                    mimeType: "image/png",
                    fileName: "a.png",
                    fileURL: URL(fileURLWithPath: "/tmp/a.png")
                )
            ])),
            "an attached image means the draft is no longer a command"
        )
    }

    func testFilterRanksNamePrefixesFirstAndRespectsTheLimit() {
        let commands = [
            AgentCommand(name: "limits", detail: "Show provider usage", source: "extension"),
            AgentCommand(name: "mode", detail: "Set effort", source: "extension"),
            AgentCommand(name: "codex-mode", detail: "", source: "extension")
        ]
        // ⌘K's buckets: an exact name prefix, then a name substring, and only then the fuzzy
        // subsequence fallback over the description ("limits" ▸ "Show provider usage").
        let matches = SlashCommandPalette.filter(commands, query: "mode", limit: 10)
        XCTAssertEqual(matches.map(\.name), ["mode", "codex-mode", "limits"])
        XCTAssertEqual(SlashCommandPalette.filter(commands, query: "", limit: 10).map(\.name),
                       ["limits", "mode", "codex-mode"], "an empty query keeps the agent's order")
        XCTAssertEqual(SlashCommandPalette.filter(commands, query: "", limit: 2).count, 2)
        XCTAssertTrue(SlashCommandPalette.filter(commands, query: "zzzz", limit: 10).isEmpty)
    }

    func testFilterMatchesDescriptionsAndSources() {
        let commands = [
            AgentCommand(name: "review", detail: "Audit a pull request", source: "skill"),
            AgentCommand(name: "plan", detail: "", source: "claude")
        ]
        XCTAssertEqual(SlashCommandPalette.filter(commands, query: "pull", limit: 10).map(\.name), ["review"])
        XCTAssertEqual(SlashCommandPalette.filter(commands, query: "claude", limit: 10).map(\.name), ["plan"])
    }

    func testKeyCodesMapToExactlyTheFourPaletteKeys() {
        XCTAssertEqual(ComposerPaletteKey(keyCode: 126), .up)
        XCTAssertEqual(ComposerPaletteKey(keyCode: 125), .down)
        XCTAssertEqual(ComposerPaletteKey(keyCode: 36), .run)
        XCTAssertEqual(ComposerPaletteKey(keyCode: 76), .run, "keypad Enter sends like Return")
        XCTAssertEqual(ComposerPaletteKey(keyCode: 53), .dismiss)
        XCTAssertNil(ComposerPaletteKey(keyCode: 48), "Tab stays with the text view")
        XCTAssertNil(ComposerPaletteKey(keyCode: 49))
    }

    func testKeyOutcomesClampAndHandBackWhatThePaletteCannotUse() {
        XCTAssertEqual(SlashCommandPalette.outcome(for: .down, selection: 0, matchCount: 3), .move(1))
        XCTAssertEqual(SlashCommandPalette.outcome(for: .down, selection: 2, matchCount: 3), .move(2))
        XCTAssertEqual(SlashCommandPalette.outcome(for: .up, selection: 0, matchCount: 3), .move(0))
        XCTAssertEqual(SlashCommandPalette.outcome(for: .run, selection: 1, matchCount: 3), .run(1))
        XCTAssertEqual(SlashCommandPalette.outcome(for: .dismiss, selection: 0, matchCount: 0), .dismiss)
        // With nothing to act on the composer keeps its own behaviour: Return sends, arrows move
        // the caret.
        XCTAssertEqual(SlashCommandPalette.outcome(for: .run, selection: 0, matchCount: 0), .ignored)
        XCTAssertEqual(SlashCommandPalette.outcome(for: .down, selection: 0, matchCount: 0), .ignored)
        XCTAssertEqual(SlashCommandPalette.outcome(for: .run, selection: 5, matchCount: 3), .ignored)
    }
}

// MARK: - Command parsing

final class AgentCommandParsingTests: XCTestCase {
    private func command(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    func testParsesEveryAgentShapeAndDegradesOnMissingFields() throws {
        let parsed = AgentCommand.parse(.array([
            command([
                "name": .string("limits"),
                "source": .string("extension"),
                "description": .string("Show usage"),
                "sourceInfo": .object(["path": .string("/tmp/limits.ts")])
            ]),
            command(["name": .string("code-review"), "source": .string("skill"), "description": .string("")]),
            command(["name": .string("compact"), "source": .string("claude")]),
            command(["name": .string("/leading-slash")]),
            command(["source": .string("skill")]),
            command(["name": .string("   ")]),
            .string("not an object")
        ]))

        XCTAssertEqual(parsed.map(\.name), ["limits", "code-review", "compact", "leading-slash"])
        XCTAssertEqual(parsed[0].prompt, "/limits")
        XCTAssertEqual(parsed[0].detail, "Show usage")
        XCTAssertEqual(parsed[1].detail, "")
        XCTAssertEqual(parsed[2].sourceLabel(agent: .claude), "Claude Code")
        XCTAssertEqual(parsed[1].sourceLabel(agent: .codex), "skill")
        XCTAssertEqual(parsed[3].sourceLabel(agent: .pi), AgentKind.pi.displayName, "no source falls back to the agent")
        XCTAssertEqual(parsed[3].prompt, "/leading-slash", "a reported slash is never doubled")
    }

    func testUnknownSourceIsShownVerbatimRatherThanDropped() {
        let parsed = AgentCommand.parse(.array([
            command(["name": .string("future"), "source": .string("mcp-prompt")])
        ]))
        XCTAssertEqual(parsed.map(\.name), ["future"])
        XCTAssertEqual(parsed[0].sourceLabel(agent: .pi), "mcp-prompt")
    }

    func testListAndDetailAreBoundedAndDeduplicated() {
        let overflow = (0..<(PatchworkTheme.commandListLimit + 25)).map {
            command(["name": .string("cmd-\($0)"), "source": .string("skill")])
        }
        XCTAssertEqual(AgentCommand.parse(.array(overflow)).count, PatchworkTheme.commandListLimit)

        let duplicated = AgentCommand.parse(.array([
            command(["name": .string("mode"), "source": .string("extension")]),
            command(["name": .string("mode"), "source": .string("extension")]),
            command(["name": .string("mode"), "source": .string("skill")])
        ]))
        XCTAssertEqual(duplicated.map(\.source), ["extension", "skill"], "same name, different source stays")

        let long = AgentCommand.parse(.array([
            command(["name": .string("x"), "description": .string(String(repeating: "d", count: 5_000))])
        ]))
        XCTAssertEqual(long.first?.detail.count, PatchworkTheme.commandDetailLimit)
    }

    func testMissingAndMalformedPayloadsProduceAnEmptyListRatherThanACrash() {
        XCTAssertTrue(AgentCommand.parse(nil).isEmpty)
        XCTAssertTrue(AgentCommand.parse(.object(["commands": .array([])])).isEmpty)
        XCTAssertTrue(AgentCommand.parse(.string("nope")).isEmpty)
    }
}

// MARK: - Store caching

private final class CommandRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    var sessionFile = ""
    var sessionID = ""
    var commands: [JSONValue] = []
    var defersCommands = false
    private var commandsCompletion: ((Result<JSONValue, Error>) -> Void)?
    private(set) var sent: [String] = []

    func start(cwd: URL, sessionPath: URL?) throws { isRunning = true }
    func stop() { isRunning = false }
    func sendUncorrelated(_ value: JSONValue) {}

    func send(type: String, payload: [String: JSONValue], completion: ((Result<JSONValue, Error>) -> Void)?) {
        sent.append(type)
        switch type {
        case "get_state":
            completion?(reply([
                "isStreaming": .bool(false),
                "sessionFile": .string(sessionFile),
                "sessionId": .string(sessionID)
            ]))
        case "switch_session":
            sessionFile = payload["sessionPath"]?.stringValue ?? sessionFile
            completion?(reply(["cancelled": .bool(false)]))
        case "get_available_models":
            completion?(reply(["models": .array([])]))
        case "get_available_thinking_levels":
            completion?(reply(["levels": .array([.string("off")])]))
        case "get_commands" where defersCommands:
            commandsCompletion = completion
        case "get_commands":
            completion?(reply(["commands": .array(commands)]))
        default:
            completion?(reply([:]))
        }
    }

    func finishCommands() {
        commandsCompletion?(reply(["commands": .array(commands)]))
        commandsCompletion = nil
    }

    func count(_ type: String) -> Int { sent.filter { $0 == type }.count }

    private func reply(_ data: [String: JSONValue]) -> Result<JSONValue, Error> {
        .success(.object(["type": .string("response"), "success": .bool(true), "data": .object(data)]))
    }
}

private struct CommandRepository: SessionRepositoryProtocol {
    var rootURL = URL(fileURLWithPath: "/tmp/patchwork-commands")
    func discoverSessions(archivedIDs: Set<String>) async throws -> [SessionSummary] { [] }
    func loadConversation(from fileURL: URL) async throws -> SessionConversation {
        SessionConversation(messages: [], leafID: nil, rawEntryCount: 0)
    }
    func refreshSummary(at fileURL: URL, archivedIDs: Set<String>) async throws -> SessionSummary {
        throw CancellationError()
    }
}

private struct CommandGitService: GitStatusProviding {
    func snapshot(for directory: URL) async -> GitSnapshot { .none }
}

@MainActor
final class AppStoreCommandCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchworkCommands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testCommandsLoadOnceWithTheComposerPrewarmAndAreCachedPerSlot() {
        let (store, runtime, session, _) = makeStore()
        runtime.commands = [
            .object(["name": .string("mode"), "source": .string("extension"), "description": .string("Set effort")])
        ]
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id

        XCTAssertEqual(runtime.count("get_commands"), 0, "nothing is asked before the first edit")
        store.composerContentDidChange()

        XCTAssertEqual(runtime.count("get_commands"), 1)
        XCTAssertEqual(store.availableCommands.map(\.prompt), ["/mode"])
        XCTAssertFalse(store.commandsLoading)
        XCTAssertFalse(store.isLoadingCommands)

        // Typing more, or re-preparing, must never re-ask.
        store.composerContentDidChange()
        store.prepareComposerOptions()
        XCTAssertEqual(runtime.count("get_commands"), 1)
    }

    func testLoadingStaysHonestUntilTheAnswerArrives() {
        let (store, runtime, session, _) = makeStore()
        runtime.defersCommands = true
        runtime.commands = [.object(["name": .string("limits"), "source": .string("extension")])]
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id

        store.prepareComposerOptions()
        XCTAssertTrue(store.commandsLoading)
        XCTAssertTrue(store.isLoadingCommands)
        XCTAssertTrue(store.availableCommands.isEmpty)

        runtime.finishCommands()
        XCTAssertFalse(store.isLoadingCommands)
        XCTAssertEqual(store.availableCommands.map(\.name), ["limits"])
    }

    func testReconfiguringTheSlotClearsTheCachedCommands() {
        let (store, runtime, session, other) = makeStore()
        runtime.commands = [.object(["name": .string("mode"), "source": .string("extension")])]
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.prepareComposerOptions()
        XCTAssertEqual(store.availableCommands.count, 1)

        runtime.commands = []
        runtime.sessionFile = other.fileURL.path
        runtime.sessionID = other.id
        store.selectSession(other)
        store.prepareComposerOptions()

        XCTAssertTrue(store.availableCommands.isEmpty, "the new route's runtime answered with nothing")
        XCTAssertEqual(runtime.count("get_commands"), 2)
    }

    func testALateAnswerFromAnotherRouteNeverOverwritesThePalette() {
        let (store, runtime, session, other) = makeStore()
        runtime.defersCommands = true
        runtime.commands = [.object(["name": .string("stale"), "source": .string("extension")])]
        store.selectSession(session)
        runtime.sessionFile = session.fileURL.path
        runtime.sessionID = session.id
        store.prepareComposerOptions()
        XCTAssertTrue(store.availableCommands.isEmpty)

        runtime.sessionFile = other.fileURL.path
        runtime.sessionID = other.id
        store.selectSession(other)
        runtime.finishCommands()

        XCTAssertTrue(store.availableCommands.isEmpty, "a superseded route must not publish into the palette")
    }

    // MARK: Fixtures

    private func makeStore() -> (AppStore, CommandRuntime, SessionSummary, SessionSummary) {
        let runtime = CommandRuntime()
        let store = AppStore(
            repository: CommandRepository(),
            gitService: CommandGitService(),
            runtime: runtime,
            runtimeFactory: { _ in CommandRuntime() },
            persistence: AppPersistence(baseURL: directory),
            activityPresenter: ActivityPresenter()
        )
        let a = summary(id: "session-a", file: "a.jsonl")
        let b = summary(id: "session-b", file: "b.jsonl")
        store.sessions = [a, b]
        return (store, runtime, a, b)
    }

    private func summary(id: String, file: String) -> SessionSummary {
        var value = SessionSummary(
            id: id,
            fileURL: directory.appendingPathComponent(file),
            cwd: directory,
            createdAt: Date(),
            modifiedAt: Date(),
            name: id,
            preview: "preview",
            messageCount: 0,
            metrics: TokenMetrics()
        )
        value.prepareSearchKey()
        return value
    }
}
