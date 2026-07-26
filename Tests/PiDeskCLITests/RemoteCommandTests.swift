import XCTest
@testable import PiDeskCLI

final class RemoteCommandTests: XCTestCase {
    func testEnableWritesSettingsAndGeneratesToken() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsPath = dir.appendingPathComponent("daemon.json")
        let tokenPath = dir.appendingPathComponent("daemon-token")

        let result = await runCLI(["remote", "enable", "--port", "7900"], daemonSettingsPath: settingsPath, tokenFilePath: tokenPath)
        XCTAssertEqual(result.exitCode, 0)

        let store = DaemonSettingsStore(path: settingsPath, fileManager: .default)
        let settings = store.readRemoteSettings()
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.port, 7900)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenPath.path))
        XCTAssertTrue(result.stderr.contains("daemon restart"))
    }

    func testEnableDefaultsPortTo7717() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsPath = dir.appendingPathComponent("daemon.json")
        _ = await runCLI(["remote", "enable"], daemonSettingsPath: settingsPath)
        let settings = DaemonSettingsStore(path: settingsPath, fileManager: .default).readRemoteSettings()
        XCTAssertEqual(settings.port, 7717)
    }

    func testEnableRejectsInvalidPort() async {
        let result = await runCLI(["remote", "enable", "--port", "99999"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testDisablePreservesPortButClearsEnabled() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsPath = dir.appendingPathComponent("daemon.json")
        _ = await runCLI(["remote", "enable", "--port", "8000"], daemonSettingsPath: settingsPath)
        _ = await runCLI(["remote", "disable"], daemonSettingsPath: settingsPath)
        let settings = DaemonSettingsStore(path: settingsPath, fileManager: .default).readRemoteSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.port, 8000)
    }

    func testUrlReflectsConfiguredPort() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsPath = dir.appendingPathComponent("daemon.json")
        _ = await runCLI(["remote", "enable", "--port", "7900"], daemonSettingsPath: settingsPath)
        let result = await runCLI(["remote", "url", "--json"], daemonSettingsPath: settingsPath)
        let decoded = try JSONDecoder().decode(RemoteStatus.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.url, "http://127.0.0.1:7900")
        XCTAssertTrue(decoded.enabled)
    }

    func testUrlDefaultsWhenNeverConfigured() async {
        let result = await runCLI(["remote", "url"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("7717"))
    }

    func testTokenIsStableAcrossCalls() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenPath = dir.appendingPathComponent("daemon-token")
        let first = await runCLI(["remote", "token"], tokenFilePath: tokenPath)
        let second = await runCLI(["remote", "token"], tokenFilePath: tokenPath)
        XCTAssertEqual(first.stdout, second.stdout)
        XCTAssertFalse(first.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testTokenFileIsPrivate() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenPath = dir.appendingPathComponent("daemon-token")
        _ = await runCLI(["remote", "token"], tokenFilePath: tokenPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath.path)
        let permissions = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }

    func testGroupHelp() async {
        let result = await runCLI(["remote", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("enable"))
    }
}
