import Foundation
import PatchworkKit

/// `pi --version`: not a provider call, not an RPC session, just a version flag \u2014 safe to run
/// unconditionally at startup and cache, unlike anything that goes through `RunExecuting`.
enum PiVersion {
    static func detect(piExecutable: URL? = nil, timeout: TimeInterval = 3) -> String? {
        guard let piURL = piExecutable ?? PiLocator.resolve() else { return nil }
        let process = Process()
        process.executableURL = piURL
        process.arguments = ["--version"]
        process.environment = PiLocator.augmentedEnvironment(piURL: piURL)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
