import Foundation
import PatchworkKit

/// One slash command or skill an agent reported through the query-only `get_commands` RPC.
///
/// All three agents answer in the same shape but fill it differently: Pi sends `source`
/// `"extension"` with a description, Codex sends `"skill"`, and Claude Code sends `"claude"`
/// with the name alone. Anything missing degrades to an empty string that the palette simply
/// does not draw; only a nameless entry is dropped, because there is nothing to run.
struct AgentCommand: Identifiable, Hashable {
    /// Without the leading slash: agents disagree on whether they include one.
    let name: String
    let detail: String
    /// The raw `source` string, kept verbatim so a source this build has never heard of is
    /// still shown rather than hidden.
    let source: String
    /// Pre-folded haystack for `QuickSwitchScoring`, which expects a lowercased key.
    let searchKey: String

    var id: String { "\(source)/\(name)" }
    /// What actually runs, through the ordinary prompt path.
    var prompt: String { "/\(name)" }

    init(name: String, detail: String = "", source: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = String(trimmed.drop(while: { $0 == "/" }))
        self.detail = String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PatchworkTheme.commandDetailLimit))
        self.source = source
        self.searchKey = (self.name + " " + self.detail).lowercased()
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.init(
            name: name,
            detail: json["description"]?.stringValue ?? "",
            source: json["source"]?.stringValue ?? ""
        )
        guard !self.name.isEmpty else { return nil }
    }

    /// Bounded and de-duplicated, in the order the agent reported.
    static func parse(_ value: JSONValue?) -> [AgentCommand] {
        var seen: Set<String> = []
        return (value?.arrayValue ?? [])
            .prefix(PatchworkTheme.commandListLimit)
            .compactMap(AgentCommand.init(json:))
            .filter { seen.insert($0.id).inserted }
    }

    /// The quiet trailing hint. Claude Code names no source worth showing, so it is attributed
    /// to the agent itself; an unknown source is shown as reported.
    func sourceLabel(agent: AgentKind) -> String {
        switch source {
        case "", "claude": return agent.displayName
        default: return source
        }
    }
}

/// The four keys the slash-command palette takes over while it is open. Every other key, and
/// any key at all while the palette is closed, stays on the composer's existing
/// send/newline/escape path.
enum ComposerPaletteKey: Equatable {
    case up
    case down
    case run
    case dismiss

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        // Return and the numeric keypad's Enter, the same pair `keyDown` already treats as send.
        case 36, 76: self = .run
        case 53: self = .dismiss
        default: return nil
        }
    }
}

/// Everything the composer's slash-command palette decides, kept out of the SwiftUI body so
/// opening, filtering, and key routing are testable without a window.
enum SlashCommandPalette {
    /// The palette owns the composer only while the draft is a bare `/token`. A space means the
    /// user is writing arguments or a sentence, so the palette steps aside and Return sends the
    /// line exactly as typed; an attachment means the draft is no longer a command at all.
    static func query(in content: ComposerContent) -> String? {
        guard content.attachments.isEmpty, content.text.hasPrefix("/") else { return nil }
        let query = content.text.dropFirst()
        guard !query.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(query)
    }

    /// Same ranking the ⌘K palette uses, over the command name with its source as the secondary
    /// key. Ties keep the agent's own order.
    static func filter(_ commands: [AgentCommand], query: String, limit: Int) -> [AgentCommand] {
        commands.enumerated()
            .compactMap { index, command -> (score: Int, index: Int, command: AgentCommand)? in
                guard let score = QuickSwitchScoring.score(
                    query: query,
                    title: command.name,
                    folder: command.source,
                    searchKey: command.searchKey
                ) else { return nil }
                return (score, index, command)
            }
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .prefix(limit)
            .map(\.command)
    }

    /// What an intercepted key means. `ignored` hands the key straight back to the composer, so
    /// an open-but-empty palette still lets Return send and the arrows move the caret.
    enum KeyOutcome: Equatable {
        case ignored
        case move(Int)
        case run(Int)
        case dismiss
    }

    static func outcome(for key: ComposerPaletteKey, selection: Int, matchCount: Int) -> KeyOutcome {
        switch key {
        case .up, .down:
            guard matchCount > 0 else { return .ignored }
            return .move(QuickSwitchNavigation.move(selection, by: key == .up ? -1 : 1, count: matchCount))
        case .run:
            guard selection >= 0, selection < matchCount else { return .ignored }
            return .run(selection)
        case .dismiss:
            return .dismiss
        }
    }
}
