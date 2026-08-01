import Foundation
import XCTest
@testable import Patchwork

/// `PiModelScope` reads `~/.pi/agent/settings.json`'s `enabledModels`/`defaultProvider`/
/// `defaultModel`; `PiModelScope.scoped` is what the model picker actually filters through.
/// Every test here constructs its input explicitly — none of it touches the real settings file.
final class PiModelScopeParsingTests: XCTestCase {
    func testParsesWildcardAndExactEntries() {
        let json = JSONValue.object([
            "enabledModels": .array([.string("openai-codex/*"), .string("anthropic/claude-opus-5")]),
            "defaultProvider": .string("openai-codex"),
            "defaultModel": .string("gpt-5.6-sol")
        ])
        let scope = try! XCTUnwrap(PiModelScope.parse(json))
        XCTAssertEqual(scope.enabledModels, ["openai-codex/*", "anthropic/claude-opus-5"])
        XCTAssertEqual(scope.defaultProvider, "openai-codex")
        XCTAssertEqual(scope.defaultModel, "gpt-5.6-sol")
    }

    func testMissingRelevantFieldsParsesToNil() {
        XCTAssertNil(PiModelScope.parse(.object(["theme": .string("dark")])))
        XCTAssertNil(PiModelScope.parse(.string("not an object")))
    }

    func testLoadRoundTripsThroughATemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{"enabledModels": ["openai-codex/*"], "defaultProvider": "openai-codex", "defaultModel": "m"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let scope = try XCTUnwrap(PiModelScope.load(settingsURL: url))
        XCTAssertEqual(scope.enabledModels, ["openai-codex/*"])
    }

    func testLoadFromAMissingFileIsNilNotACrash() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertNil(PiModelScope.load(settingsURL: url))
    }
}

final class PiModelScopeAllowsTests: XCTestCase {
    func testWildcardEnablesEveryModelForThatProvider() {
        let scope = PiModelScope(enabledModels: ["openai-codex/*"], defaultProvider: nil, defaultModel: nil)
        XCTAssertTrue(scope.allows(provider: "openai-codex", modelID: "gpt-5.6-sol"))
        XCTAssertTrue(scope.allows(provider: "openai-codex", modelID: "anything-else"))
        XCTAssertFalse(scope.allows(provider: "anthropic", modelID: "claude-opus-5"))
    }

    func testExactEntryEnablesOnlyThatModel() {
        let scope = PiModelScope(enabledModels: ["anthropic/claude-opus-5"], defaultProvider: nil, defaultModel: nil)
        XCTAssertTrue(scope.allows(provider: "anthropic", modelID: "claude-opus-5"))
        XCTAssertFalse(scope.allows(provider: "anthropic", modelID: "claude-fable-5"))
    }

    func testBareProviderWithNoSlashEnablesThatWholeProvider() {
        let scope = PiModelScope(enabledModels: ["openai-codex"], defaultProvider: nil, defaultModel: nil)
        XCTAssertTrue(scope.allows(provider: "openai-codex", modelID: "gpt-5.6-sol"))
    }
}

final class ModelScopingFilterTests: XCTestCase {
    private let models = [
        AvailableModel(provider: "openai-codex", modelID: "gpt-5.6-sol", name: "GPT-5.6 Sol"),
        AvailableModel(provider: "anthropic", modelID: "claude-fable-5", name: "Claude Fable 5"),
        AvailableModel(provider: "anthropic", modelID: "claude-opus-5", name: "Claude Opus 5"),
        AvailableModel(provider: "openai", modelID: "o5", name: "O5")
    ]

    func testNilScopeReturnsTheFullListUnfiltered() {
        let result = PiModelScope.scoped(models, by: nil, currentProvider: nil, currentModelID: nil)
        XCTAssertEqual(result.count, models.count)
    }

    func testEmptyScopeReturnsTheFullListUnfiltered() {
        let scope = PiModelScope(enabledModels: [], defaultProvider: nil, defaultModel: nil)
        let result = PiModelScope.scoped(models, by: scope, currentProvider: nil, currentModelID: nil)
        XCTAssertEqual(result.count, models.count)
    }

    func testScopeNarrowsToEnabledModelsOnly() {
        let scope = PiModelScope(enabledModels: ["openai-codex/*", "anthropic/claude-opus-5"], defaultProvider: nil, defaultModel: nil)
        let result = PiModelScope.scoped(models, by: scope, currentProvider: nil, currentModelID: nil)
        XCTAssertEqual(Set(result.map(\.id)), ["openai-codex/gpt-5.6-sol", "anthropic/claude-opus-5"])
    }

    /// A session already running a model that fell out of scope (or was never in it) must keep
    /// that entry visible in the menu — losing your own current selection would be worse than
    /// showing one extra item.
    func testCurrentSelectionStaysVisibleEvenWhenOutOfScope() {
        let scope = PiModelScope(enabledModels: ["anthropic/claude-opus-5"], defaultProvider: nil, defaultModel: nil)
        let result = PiModelScope.scoped(models, by: scope, currentProvider: "openai", currentModelID: "o5")
        XCTAssertTrue(result.contains { $0.provider == "openai" && $0.modelID == "o5" })
        XCTAssertTrue(result.contains { $0.provider == "anthropic" && $0.modelID == "claude-opus-5" })
        XCTAssertEqual(result.count, 2)
    }

    func testCurrentSelectionNotDuplicatedWhenAlreadyInScope() {
        let scope = PiModelScope(enabledModels: ["openai-codex/*"], defaultProvider: nil, defaultModel: nil)
        let result = PiModelScope.scoped(models, by: scope, currentProvider: "openai-codex", currentModelID: "gpt-5.6-sol")
        XCTAssertEqual(result.count, 1)
    }
}

/// `PiModelScopeCache` must never let a developer's own `~/.pi/agent/settings.json` leak into
/// the test suite: the default-URL guard is exercised implicitly by every other test in this
/// file running under `swift test` without touching real scoping, and explicitly here.
final class PiModelScopeCacheTests: XCTestCase {
    func testCustomURLCachesUntilTheFileChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try #"{"enabledModels": ["openai-codex/*"]}"#.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)

        let cache = PiModelScopeCache(url: url)
        let first = try XCTUnwrap(cache.current())
        XCTAssertEqual(first.enabledModels, ["openai-codex/*"])

        // Two writes issued back to back can land within the same filesystem timestamp tick, so
        // the mtime is set explicitly here rather than relied on to have naturally advanced.
        try #"{"enabledModels": ["anthropic/*"]}"#.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: url.path)
        let second = try XCTUnwrap(cache.current())
        XCTAssertEqual(second.enabledModels, ["anthropic/*"])
    }

    /// The real, ambient settings file must never drive the picker inside the test process —
    /// this is what protects every unrelated fixture model elsewhere in the suite.
    func testSharedCacheIsInertUnderTests() {
        XCTAssertNil(PiModelScopeCache.shared.current())
    }
}

final class ModelNamingTests: XCTestCase {
    func testRawIdentifiersReadLikeTheirProductNames() {
        XCTAssertEqual(ModelNaming.pretty("gpt-5.6-sol"), "GPT 5.6 Sol")
        XCTAssertEqual(ModelNaming.pretty("openai-codex/gpt-5.6-terra"), "GPT 5.6 Terra")
        XCTAssertEqual(ModelNaming.pretty("anthropic/claude-opus-5"), "Claude Opus 5")
        XCTAssertEqual(ModelNaming.pretty(""), "")
    }
}
