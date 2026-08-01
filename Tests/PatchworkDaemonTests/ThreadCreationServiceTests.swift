import PatchworkKit
import XCTest
@testable import PatchworkDaemon

final class ThreadCreationServiceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testNameBackedIdleCreationUsesABoundedFallbackAndReturnsTheParsedFile() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000001"
        let fixture = try makeNameBackedAgent(sessionID: sessionID, persistedID: sessionID)
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory), piExecutableOverride: fixture.executable
        )

        let thread = try await service.createIdle(agent: .codex, cwd: directory, name: nil)

        XCTAssertEqual(thread.id, sessionID)
        XCTAssertEqual(thread.path, fixture.transcript.standardizedFileURL.path)
        XCTAssertEqual(thread.cwd, directory.standardizedFileURL.path)
        XCTAssertEqual(thread.name, ThreadCreationService.defaultIdleName)
        XCTAssertEqual(thread.agent, .codex)

        let requests = try requestObjects(at: fixture.requests)
        let methods = requests.compactMap { $0["method"]?.stringValue }
        XCTAssertTrue(methods.contains("thread/name/set"))
        XCTAssertFalse(methods.contains("turn/start"), "idle creation must not send a provider prompt")
        let rename = try XCTUnwrap(requests.first { $0["method"]?.stringValue == "thread/name/set" })
        XCTAssertEqual(rename["params"]?["name"]?.stringValue, ThreadCreationService.defaultIdleName)
    }

    func testPiIdleCreationReservesPisAuthoritativePathAndInitializesWithoutAPrompt() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000010"
        let fixture = try makePiIdleAgent(sessionID: sessionID)
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable,
            // Deliberately disagree with the fake agent's reported path. The service must trust
            // Pi's merged runtime configuration, not reimplement its settings precedence.
            environment: [
                "PI_CODING_AGENT_SESSION_DIR": directory
                    .appendingPathComponent("wrong-derived-directory").path
            ]
        )

        let thread = try await service.createIdle(
            agent: .pi, cwd: directory, name: "Reserved idle"
        )

        XCTAssertEqual(thread.id, sessionID)
        XCTAssertEqual(thread.name, "Reserved idle")
        XCTAssertEqual(thread.cwd, directory.standardizedFileURL.path)
        XCTAssertEqual(thread.agent, .pi)
        XCTAssertEqual(thread.path, try selectedPiTranscript(fixture).path)
        XCTAssertTrue(
            URL(fileURLWithPath: thread.path).lastPathComponent.hasPrefix(
                ThreadCreationService.piReservationFilenamePrefix
            )
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: thread.path)[.size] as? NSNumber
            ).intValue,
            0
        )

        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8)
        XCTAssertFalse(arguments.contains("--session\n"), arguments)
        XCTAssertFalse(arguments.contains("--session-id\n"), arguments)
        let requests = try requestObjects(at: fixture.requests)
        let types = requests.compactMap { $0["type"]?.stringValue }
        XCTAssertEqual(types, ["get_state", "switch_session", "get_state", "set_session_name"])
        XCTAssertFalse(types.contains("prompt"), "idle creation must not send a provider prompt")
    }

    func testPiIdleCreationUsesAnAlreadyMaterializedProbeWithoutCreatingADuplicate() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000020"
        let fixture = try makePiIdleAgent(
            sessionID: sessionID, preMaterializedProbe: true
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        let thread = try await service.createIdle(
            agent: .pi, cwd: directory, name: "Existing idle"
        )

        XCTAssertEqual(thread.id, sessionID)
        XCTAssertEqual(thread.path, fixture.reportedTranscript.standardizedFileURL.path)
        let requests = try requestObjects(at: fixture.requests)
        let types = requests.compactMap { $0["type"]?.stringValue }
        XCTAssertEqual(types, ["get_state", "set_session_name"])
        XCTAssertFalse(types.contains("switch_session"))
        XCTAssertFalse(types.contains("prompt"))
        let sessionFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.reportedTranscript.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(sessionFiles.map(\.standardizedFileURL.path), [
            fixture.reportedTranscript.standardizedFileURL.path
        ])
    }

    func testPiIdleCreationLeavesItsEmptyReservationAfterLaunchFailure() async throws {
        let fixture = try makePiIdleAgent(
            sessionID: "019f0000-0000-7000-8000-000000000011",
            switchBehavior: .exitBeforeWrite
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .pi, cwd: directory, name: nil)
            XCTFail("expected the failed launch")
        } catch {}

        let selected = try selectedPiTranscript(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(try Data(contentsOf: selected).count, 0)
    }

    func testPiIdleCreationRecoversTheReservedHeaderWhenSwitchAcknowledgementIsLost() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000012"
        let fixture = try makePiIdleAgent(
            sessionID: sessionID, switchBehavior: .validThenDropAcknowledgement
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        let thread = try await service.createIdle(agent: .pi, cwd: directory, name: nil)

        XCTAssertEqual(thread.id, sessionID)
        XCTAssertEqual(thread.path, try selectedPiTranscript(fixture).path)
        let types = try requestObjects(at: fixture.requests).compactMap { $0["type"]?.stringValue }
        XCTAssertEqual(types.filter { $0 == "switch_session" }.count, 1)
        XCTAssertFalse(types.contains("prompt"))
    }

    func testPiIdleCreationPreservesMalformedNonemptyReservationWhenAcknowledgementIsLost() async throws {
        let fixture = try makePiIdleAgent(
            sessionID: "019f0000-0000-7000-8000-000000000013",
            switchBehavior: .malformedThenDropAcknowledgement
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .pi, cwd: directory, name: nil)
            XCTFail("expected an unknown materialization outcome")
        } catch let ThreadCreationError.outcomeUnknown(agent, reference) {
            XCTAssertEqual(agent, .pi)
            XCTAssertEqual(reference, try selectedPiTranscript(fixture).path)
        }
        let selected = try selectedPiTranscript(fixture)
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "not-json\n")
    }

    func testPiIdleCreationNeverRecoversOrRemovesAReplacementInode() async throws {
        let fixture = try makePiIdleAgent(
            sessionID: "019f0000-0000-7000-8000-000000000014",
            switchBehavior: .replaceThenDropAcknowledgement
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .pi, cwd: directory, name: nil)
            XCTFail("expected an unknown materialization outcome")
        } catch let ThreadCreationError.outcomeUnknown(agent, reference) {
            XCTAssertEqual(agent, .pi)
            XCTAssertEqual(reference, try selectedPiTranscript(fixture).path)
        }
        let selected = try selectedPiTranscript(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertGreaterThan(try Data(contentsOf: selected).count, 0)
        let detached = URL(fileURLWithPath: selected.path + ".detached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: detached.path))
        XCTAssertEqual(try Data(contentsOf: detached).count, 0)
    }

    func testPiIdleCreationResolvesRelativeReportedPathsAgainstTheWorkingDirectory() async throws {
        let fixture = try makePiIdleAgent(
            sessionID: "019f0000-0000-7000-8000-000000000015",
            relativeReportedPath: true
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        let thread = try await service.createIdle(agent: .pi, cwd: directory, name: nil)
        let selected = try selectedPiTranscript(fixture)
        XCTAssertEqual(thread.path, selected.path)
        XCTAssertEqual(
            selected.deletingLastPathComponent().path,
            directory.appendingPathComponent("settings-selected", isDirectory: true).path
        )
        let switchRequest = try XCTUnwrap(
            requestObjects(at: fixture.requests).first { $0["type"]?.stringValue == "switch_session" }
        )
        let switchPath = try XCTUnwrap(switchRequest["sessionPath"]?.stringValue)
        XCTAssertEqual(switchPath, selected.path)
        XCTAssertTrue((switchPath as NSString).isAbsolutePath)
    }

    func testPiIdleCreationNeverDeletesPreexistingTaggedReservations() async throws {
        let parent = directory.appendingPathComponent("settings-selected", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let prefix = ThreadCreationService.piReservationFilenamePrefix
        let oldEmpty = parent.appendingPathComponent("\(prefix)old-empty.jsonl")
        let freshEmpty = parent.appendingPathComponent("\(prefix)fresh-empty.jsonl")
        let oldNonempty = parent.appendingPathComponent("\(prefix)old-nonempty.jsonl")
        let oldUntagged = parent.appendingPathComponent("old-empty.jsonl")
        try Data().write(to: oldEmpty)
        try Data().write(to: freshEmpty)
        try Data("preserve".utf8).write(to: oldNonempty)
        try Data().write(to: oldUntagged)
        let oldDate = Date().addingTimeInterval(-(6 * 60))
        for url in [oldEmpty, oldNonempty, oldUntagged] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate], ofItemAtPath: url.path
            )
        }
        let fixture = try makePiIdleAgent(
            sessionID: "019f0000-0000-7000-8000-000000000016"
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        _ = try await service.createIdle(agent: .pi, cwd: directory, name: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldEmpty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshEmpty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldNonempty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldUntagged.path))
    }

    func testPiIdleCreationDoesNotChangeAgentOwnedDirectoryPermissions() async throws {
        let fixture = try makePiIdleAgent(
            sessionID: "019f0000-0000-7000-8000-000000000017"
        )
        let parent = directory.appendingPathComponent("settings-selected", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: parent.path
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        _ = try await service.createIdle(agent: .pi, cwd: directory, name: nil)

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(permissions, 0o755)
    }

    func testPiIdleCreationDoesNotRecoverAHeaderWithTheWrongResolvedIdentity() async throws {
        let resolvedID = "019f0000-0000-7000-8000-000000000018"
        let persistedID = "019f0000-0000-7000-8000-000000000019"
        let fixture = try makePiIdleAgent(
            sessionID: resolvedID, persistedID: persistedID
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory),
            piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .pi, cwd: directory, name: nil)
            XCTFail("expected an unknown materialization outcome")
        } catch let ThreadCreationError.outcomeUnknown(agent, reference) {
            XCTAssertEqual(agent, .pi)
            XCTAssertEqual(reference, resolvedID)
        }
        let selected = try selectedPiTranscript(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(
            try String(contentsOf: selected, encoding: .utf8).contains(persistedID)
        )
    }

    func testNameBackedIdleCreationRejectsAFileForAnotherSession() async throws {
        let reportedID = "019f0000-0000-7000-8000-000000000002"
        let persistedID = "019f0000-0000-7000-8000-000000000003"
        let fixture = try makeNameBackedAgent(sessionID: reportedID, persistedID: persistedID)
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory), piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .codex, cwd: directory, name: "Review")
            XCTFail("expected the mismatched transcript to be rejected")
        } catch let RunnerError.processExited(message) {
            XCTAssertTrue(message.contains(reportedID), message)
            XCTAssertTrue(message.contains(persistedID), message)
        }
    }

    func testNameBackedIdleCreationDoesNotAcceptARejectedMaterializationCommand() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000004"
        let fixture = try makeNameBackedAgent(
            sessionID: sessionID, persistedID: sessionID, rejectName: true
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory), piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .codex, cwd: directory, name: nil)
            XCTFail("expected the materialization rejection")
        } catch let RunnerError.processExited(message) {
            XCTAssertTrue(message.contains("name rejected"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transcript.path))
    }

    func testNameBackedIdleCreationSalvagesAFileWhenTheMaterializationAckIsLost() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000005"
        let fixture = try makeNameBackedAgent(
            sessionID: sessionID, persistedID: sessionID, dropNameAcknowledgement: true
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory), piExecutableOverride: fixture.executable
        )

        let thread = try await service.createIdle(agent: .codex, cwd: directory, name: "Recovered")

        XCTAssertEqual(thread.id, sessionID)
        XCTAssertEqual(thread.path, fixture.transcript.standardizedFileURL.path)
        XCTAssertEqual(thread.name, "Recovered")
        let methods = try requestObjects(at: fixture.requests).compactMap {
            $0["method"]?.stringValue
        }
        XCTAssertEqual(methods.filter { $0 == "thread/name/set" }.count, 1)
        XCTAssertFalse(methods.contains("turn/start"), "recovery must not send a provider prompt")
    }

    func testNameBackedIdleCreationReportsUnknownWhenTheAckAndFileAreBothMissing() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000006"
        let fixture = try makeNameBackedAgent(
            sessionID: sessionID, persistedID: sessionID,
            dropNameAcknowledgement: true, persistOnName: false
        )
        let service = ThreadCreationService(
            logger: TestSupport.logger(in: directory), piExecutableOverride: fixture.executable
        )

        do {
            _ = try await service.createIdle(agent: .codex, cwd: directory, name: nil)
            XCTFail("expected an ambiguous materialization outcome")
        } catch let ThreadCreationError.outcomeUnknown(agent, reportedID) {
            XCTAssertEqual(agent, .codex)
            XCTAssertEqual(reportedID, sessionID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transcript.path))
    }

    func testInitialNameBoundCountsUTF8BytesWithoutSplittingACharacter() throws {
        let name = "  " + String(repeating: "é", count: 200) + "  "
        let bounded = try XCTUnwrap(ThreadCreationService.boundedInitialName(name))

        XCTAssertEqual(bounded.lengthOfBytes(using: .utf8), ThreadCreationService.initialNameByteLimit)
        XCTAssertEqual(bounded, String(repeating: "é", count: 128))
    }

    func testIdleCreationCapabilitiesDescribeTheMaterializationMechanism() {
        XCTAssertEqual(AgentKind.pi.capabilities.idleThreadCreation, .processStart)
        XCTAssertEqual(AgentKind.codex.capabilities.idleThreadCreation, .sessionName)
        XCTAssertEqual(AgentKind.claude.capabilities.idleThreadCreation, .unavailable)
    }

    private struct Fixture {
        let executable: URL
        let transcript: URL
        let requests: URL
    }

    private struct PiFixture {
        let executable: URL
        let requests: URL
        let arguments: URL
        let selectedPath: URL
        let reportedTranscript: URL
    }

    private enum PiSwitchBehavior {
        case succeed
        case exitBeforeWrite
        case validThenDropAcknowledgement
        case malformedThenDropAcknowledgement
        case replaceThenDropAcknowledgement
    }

    private func makePiIdleAgent(
        sessionID: String,
        persistedID: String? = nil,
        switchBehavior: PiSwitchBehavior = .succeed,
        relativeReportedPath: Bool = false,
        preMaterializedProbe: Bool = false
    ) throws -> PiFixture {
        let executable = directory.appendingPathComponent("fake-pi-idle-agent")
        let reportedTranscript = directory
            .appendingPathComponent("settings-selected", isDirectory: true)
            .appendingPathComponent("probe-identity.jsonl")
        let requests = directory.appendingPathComponent("pi-requests.jsonl")
        let arguments = directory.appendingPathComponent("pi-arguments.txt")
        let selectedPath = directory.appendingPathComponent("pi-selected-path.txt")
        try FileManager.default.createDirectory(
            at: reportedTranscript.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try Data().write(to: requests)
        try Data().write(to: arguments)
        try Data().write(to: selectedPath)
        let reportedPath = relativeReportedPath
            ? "settings-selected/probe-identity.jsonl"
            : reportedTranscript.path
        if preMaterializedProbe {
            try (#"{"type":"session","id":"\#(sessionID)","cwd":"\#(directory.path)"}"# + "\n")
                .write(to: reportedTranscript, atomically: true, encoding: .utf8)
        }
        let writeValidHeader = """
        printf '%s\n' '{"type":"session","id":"\(persistedID ?? sessionID)","cwd":"\(directory.path)"}' > "$selected_path"
        """
        let switchAction: String
        switch switchBehavior {
        case .succeed:
            switchAction = """
            \(writeValidHeader)
            switched=1
            printf '{"type":"response","id":"%s","command":"switch_session","success":true,"data":{"cancelled":false}}\n' "$request_id"
            """
        case .exitBeforeWrite:
            switchAction = "exit 33"
        case .validThenDropAcknowledgement:
            switchAction = """
            \(writeValidHeader)
            exit 33
            """
        case .malformedThenDropAcknowledgement:
            switchAction = """
            printf '%s\n' 'not-json' > "$selected_path"
            exit 33
            """
        case .replaceThenDropAcknowledgement:
            switchAction = """
            mv "$selected_path" "$selected_path.detached"
            \(writeValidHeader)
            exit 33
            """
        }
        let script = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          printf '%s\n' "$1" >> '\(arguments.path)'
          shift
        done
        switched=0
        while IFS= read -r line; do
          printf '%s\n' "$line" >> '\(requests.path)'
          request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
          case "$line" in
            *'"type":"get_state"'*)
              if [ "$switched" -eq 0 ]; then
                state_id='\(preMaterializedProbe ? sessionID : "probe-discarded")'
                state_file='\(reportedPath)'
                \(preMaterializedProbe ? "selected_path='\(reportedTranscript.path)'" : ":")
              else
                state_id='\(sessionID)'
                \(relativeReportedPath ? "state_file=\"settings-selected/$(basename \"$selected_path\")\"" : "state_file=\"$selected_path\"")
              fi
              printf '{"type":"response","id":"%s","command":"get_state","success":true,"data":{"sessionId":"%s","sessionFile":"%s"}}\n' "$request_id" "$state_id" "$state_file"
              ;;
            *'"type":"switch_session"'*)
              selected_path=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"sessionPath":"([^"]+)".*/\\1/' | /usr/bin/sed 's#\\\\/#/#g')
              printf '%s\n' "$selected_path" > '\(selectedPath.path)'
              [ -f "$selected_path" ] || exit 31
              [ ! -s "$selected_path" ] || exit 32
              \(switchAction)
              ;;
            *'"type":"set_session_name"'*)
              printf '%s\n' '{"type":"session_info","id":"name","name":"Reserved idle"}' >> "$selected_path"
              printf '{"type":"response","id":"%s","command":"set_session_name","success":true,"data":{}}\n' "$request_id"
              ;;
            *'"type":"prompt"'*)
              exit 40
              ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        return PiFixture(
            executable: executable, requests: requests,
            arguments: arguments, selectedPath: selectedPath,
            reportedTranscript: reportedTranscript
        )
    }

    private func selectedPiTranscript(_ fixture: PiFixture) throws -> URL {
        let path = try String(contentsOf: fixture.selectedPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func makeNameBackedAgent(
        sessionID: String, persistedID: String, rejectName: Bool = false,
        dropNameAcknowledgement: Bool = false, persistOnName: Bool = true
    ) throws -> Fixture {
        let executable = directory.appendingPathComponent("fake-name-backed-agent")
        let transcript = directory.appendingPathComponent("rollout-\(sessionID).jsonl")
        let requests = directory.appendingPathComponent("requests.jsonl")
        try Data().write(to: requests)
        let sessionRecord = """
        {"timestamp":"2026-08-01T00:00:00.000Z","type":"session_meta","payload":{"session_id":"\(persistedID)","cwd":"\(directory.path)","timestamp":"2026-08-01T00:00:00.000Z","thread_source":"user"}}
        """
        let materialize: String
        if rejectName {
            materialize = #"printf '{"id":%s,"error":{"code":-1,"message":"name rejected"}}\n' "$request_id""#
        } else if dropNameAcknowledgement {
            materialize = """
            \(persistOnName ? "printf '%s\\n' '\(sessionRecord)' > '\(transcript.path)'" : ":")
            exit 1
            """
        } else {
            materialize = """
            printf '%s\n' '\(sessionRecord)' > '\(transcript.path)'
            printf '{"id":%s,"result":{}}\n' "$request_id"
            """
        }
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\n' "$line" >> '\(requests.path)'
          request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":%s,"result":{}}\n' "$request_id"
              ;;
            *'"method":"thread/start"'*)
              printf '{"id":%s,"result":{"thread":{"id":"\(sessionID)","path":"\(transcript.path)","cwd":"\(directory.path)","name":null}}}\n' "$request_id"
              ;;
            *'"method":"model/list"'*)
              printf '{"id":%s,"result":{"data":[]}}\n' "$request_id"
              ;;
            *'"method":"thread/name/set"'*)
              \(materialize)
              ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        return Fixture(executable: executable, transcript: transcript, requests: requests)
    }

    private func requestObjects(at url: URL) throws -> [[String: PiJSONValue]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try PiJSONValue.decode(Data($0.utf8)).objectValue }
    }
}
