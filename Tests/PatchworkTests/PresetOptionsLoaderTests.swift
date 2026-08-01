import PatchworkKit
import XCTest
@testable import Patchwork

private final class PresetOptionsRuntime: AgentRuntimeProtocol {
    var onEvent: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var isRunning = false
    private(set) var commands: [String] = []
    private(set) var startedCWD: URL?

    func start(cwd: URL, sessionPath: URL?) throws {
        startedCWD = cwd
        isRunning = true
    }
    func stop() { isRunning = false }
    func sendUncorrelated(_ value: JSONValue) {}

    func send(
        type: String,
        payload: [String: JSONValue],
        completion: ((Result<JSONValue, Error>) -> Void)?
    ) {
        commands.append(type)
        let data: JSONValue
        switch type {
        case "get_state":
            data = .object([
                "model": .object([
                    "provider": .string("provider"),
                    "id": .string("model"),
                    "name": .string("Model")
                ]),
                "thinkingLevel": .string("high")
            ])
        case "get_available_models":
            data = .object(["models": .array([
                .object([
                    "provider": .string("provider"),
                    "id": .string("model"),
                    "name": .string("Model")
                ])
            ])])
        case "get_available_thinking_levels":
            data = .object(["levels": .array([.string("off"), .string("high")])])
        default:
            return completion?(.failure(AgentRuntimeError.invalidCommand)) ?? ()
        }
        completion?(.success(.object(["success": .bool(true), "data": data])))
    }
}

@MainActor
final class PresetOptionsLoaderTests: XCTestCase {
    func testLoadsReadOnlyOptionsSequentiallyAndStopsItsRuntime() {
        let runtime = PresetOptionsRuntime()
        let loader = PresetOptionsLoader(runtimeFactory: { _ in runtime })

        loader.load(agent: .pi)

        XCTAssertEqual(runtime.commands, [
            "get_state",
            "get_available_models",
            "get_available_thinking_levels"
        ])
        XCTAssertEqual(loader.currentModel?.modelID, "model")
        XCTAssertEqual(loader.models.map(\.modelID), ["model"])
        XCTAssertEqual(loader.thinkingLevels, ["off", "high"])
        XCTAssertEqual(runtime.startedCWD?.standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertFalse(loader.isLoading)
        XCTAssertFalse(runtime.isRunning)
        XCTAssertNil(loader.error)
    }
}
