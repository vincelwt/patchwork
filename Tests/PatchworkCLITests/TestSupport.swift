import Foundation
@testable import PatchworkCLI

/// Records every `launchctl`-style invocation instead of running one, so daemon lifecycle tests
/// never touch the real system.
final class RecordingShellRunner: ShellRunning, @unchecked Sendable {
    struct Invocation: Equatable { var executable: String; var arguments: [String] }
    private(set) var invocations: [Invocation] = []
    var resultProvider: (String, [String]) -> ShellResult = { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") }

    func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        return resultProvider(executable, arguments)
    }
}

/// Accumulates what a run wrote. Sequential by construction (one command runs top to bottom on
/// one Task), so a plain unchecked-Sendable buffer is enough.
final class OutputCapture: @unchecked Sendable {
    private(set) var stdout = ""
    private(set) var stderr = ""
    func out(_ text: String) { stdout += text }
    func err(_ text: String) { stderr += text }
}

struct CLIResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Runs the whole CLI (argument parsing through output) against a fake control plane and shell
/// runner. This is the seam the task requires: nothing here opens a socket.
@discardableResult
func runCLI(
    _ args: [String],
    environment: [String: String] = [:],
    controlPlane: ControlPlane = FakeControlPlane(),
    shellRunner: RecordingShellRunner = RecordingShellRunner(),
    fileManager: FileManager = .default,
    isTTY: Bool = false,
    stdin: Data = Data(),
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    // Default expressions are re-evaluated per call, so every test gets its own fresh temp
    // path here unless it overrides one explicitly — real user state is never touched.
    daemonSettingsPath: URL = makeTempDirectory().appendingPathComponent("daemon.json"),
    tokenFilePath: URL = makeTempDirectory().appendingPathComponent("daemon-token"),
    logFilePath: URL = makeTempDirectory().appendingPathComponent("daemon.log"),
    daemonOwnerFilePath: URL = makeTempDirectory().appendingPathComponent("daemon-owner.json")
) async -> CLIResult {
    let capture = OutputCapture()
    let host = CLIHost(
        environment: environment,
        writeOut: { capture.out($0) },
        writeErr: { capture.err($0) },
        isTTY: isTTY,
        makeControlPlane: { _ in controlPlane },
        shellRunner: shellRunner,
        fileManager: fileManager,
        now: { now },
        readStdin: { max in Data(stdin.prefix(max)) },
        daemonSettingsPath: daemonSettingsPath,
        tokenFilePath: tokenFilePath,
        logFilePath: logFilePath,
        daemonOwnerFilePath: daemonOwnerFilePath
    )
    let code = await CLIRunner.run(args, host: host)
    return CLIResult(exitCode: code, stdout: capture.stdout, stderr: capture.stderr)
}


func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("patchwork-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
