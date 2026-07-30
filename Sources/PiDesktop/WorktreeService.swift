import Foundation
import PiDeskKit

/// Keep existing desktop call sites and tests on the shared implementation used by the daemon.
typealias WorktreeService = PiDeskKit.WorktreeService

/// Finds the pull/merge request a conversation opened, so the header can link straight to it.
enum PullRequestLink {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https://(?:github\.com|gitlab\.com)/[\w.\-]+/[\w.\-]+/(?:pull|merge_requests|-/merge_requests)/(\d+)"#
    )
    /// Bounds: a transcript can be enormous, and a PR is announced near the end of the work.
    private static let scannedMessageLimit = 200
    private static let scannedCharacterLimit = 20_000

    /// The most recently mentioned link wins, so a conversation that opens a second PR points at
    /// the second one.
    static func latest(in messages: [ChatMessage]) -> URL? {
        for message in messages.suffix(scannedMessageLimit).reversed() {
            guard let url = firstLink(in: String(message.textContent.prefix(scannedCharacterLimit))) else { continue }
            return url
        }
        return nil
    }

    static func invokesCreation(_ command: String) -> Bool {
        let needle = "gh pr create"
        var quote: Character?
        var escaped = false
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if command[index...].hasPrefix(needle) {
                let after = command.index(index, offsetBy: needle.count)
                let endsToken = after == command.endIndex || command[after].isWhitespace
                var before = index
                var startsCommand = true
                while before > command.startIndex {
                    let previous = command.index(before: before)
                    let value = command[previous]
                    if value == "\n" { break }
                    if value.isWhitespace { before = previous; continue }
                    if ";&|(".contains(value), endsToken { return true }
                    startsCommand = false
                    break
                }
                if startsCommand, endsToken { return true }
            }
            index = command.index(after: index)
        }
        return false
    }

    /// The last match in one blob: `gh pr create` prints the URL after any earlier context.
    static func firstLink(in text: String) -> URL? {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    /// `#482` for the toolbar chip.
    static func number(in url: URL) -> String? {
        url.pathComponents.last.flatMap { Int($0) }.map { "#\($0)" }
    }
}

enum PullRequestState: Equatable, Sendable {
    case open
    case openWithCodexReview
    case closed
    case unknown

    var isOpen: Bool { self == .open || self == .openWithCodexReview }
}

protocol PullRequestStateProviding {
    func states(for urls: [URL]) async -> [URL: PullRequestState]
}

/// One authenticated GraphQL request resolves every recent GitHub PR. Missing `gh`, GitLab URLs,
/// network failures, and inaccessible repositories stay unknown instead of being mistaken for
/// closed pull requests.
struct GitHubPullRequestStateService: PullRequestStateProviding {
    static let maximumURLCount = 100

    private struct Candidate {
        let url: URL
        let alias: String
        let owner: String
        let repository: String
        let number: Int
    }

    func states(for urls: [URL]) async -> [URL: PullRequestState] {
        let worker = Task.detached(priority: .utility) { Self.readStates(for: urls) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func decodedStates(from response: JSONValue, for urls: [URL]) -> [URL: PullRequestState] {
        let candidates = candidates(for: urls)
        var states = urls.reduce(into: [URL: PullRequestState]()) { $0[$1] = .unknown }
        for candidate in candidates {
            guard let pullRequest = response["data"]?[candidate.alias]?["pullRequest"] else { continue }
            switch pullRequest["state"]?.stringValue {
            case "OPEN":
                let reviewed = ["codexReviews", "codexBotReviews"].contains { field in
                    pullRequest[field]?["nodes"]?.arrayValue?.contains {
                        $0["submittedAt"]?.stringValue != nil
                    } == true
                }
                states[candidate.url] = reviewed ? .openWithCodexReview : .open
            case "CLOSED", "MERGED": states[candidate.url] = .closed
            default: break
            }
        }
        return states
    }

    private static func readStates(for urls: [URL]) -> [URL: PullRequestState] {
        var states = urls.reduce(into: [URL: PullRequestState]()) { $0[$1] = .unknown }
        let candidates = candidates(for: urls)
        guard !Task.isCancelled, !candidates.isEmpty,
              let executable = ghExecutable() else { return states }
        let result = run(executable, arguments: ["api", "graphql", "-f", "query=\(graphqlQuery(for: urls))"])
        guard !Task.isCancelled, result.status == 0,
              let response = try? JSONValue.decode(result.data) else { return states }
        states.merge(decodedStates(from: response, for: urls)) { _, resolved in resolved }
        return states
    }

    static func graphqlQuery(for urls: [URL]) -> String {
        let fields = candidates(for: urls).map {
            "\($0.alias): repository(owner: \"\($0.owner)\", name: \"\($0.repository)\") { pullRequest(number: \($0.number)) { state codexReviews: reviews(last: 1, author: \"chatgpt-codex-connector\") { nodes { submittedAt } } codexBotReviews: reviews(last: 1, author: \"chatgpt-codex-connector[bot]\") { nodes { submittedAt } } } }"
        }.joined(separator: " ")
        return "query { \(fields) }"
    }

    private static func candidates(for urls: [URL]) -> [Candidate] {
        var result: [Candidate] = []
        var seen: Set<URL> = []
        for url in urls where result.count < maximumURLCount && seen.insert(url).inserted {
            guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com" else { continue }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
                  [parts[0], parts[1]].allSatisfy({
                      $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                  }) else { continue }
            result.append(Candidate(
                url: url, alias: "pr\(result.count)", owner: parts[0], repository: parts[1], number: number
            ))
        }
        return result
    }

    private static func ghExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return (pathCandidates + [
            "\(home)/.local/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"
        ])
        .map { URL(fileURLWithPath: $0).standardizedFileURL }
        .first { manager.isExecutableFile(atPath: $0.path) }
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 15
    ) -> (status: Int32, data: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = PiLocator.augmentedEnvironment(piURL: executable)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, data.count <= 256 * 1_024 ? data : Data())
    }
}
