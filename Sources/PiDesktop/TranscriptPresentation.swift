import Foundation

/// Human-readable categories shared by the transcript rollup and live activity surfaces.
enum ToolActivityKind: String, CaseIterable, Hashable, Sendable {
    case commands = "Ran commands"
    case filesRead = "Read files"
    case filesEdited = "Edited files"
    case web = "Searched web"
    case browser = "Used browser"
    case computer = "Used computer"
    case agents = "Ran agents"
    case processes = "Managed processes"
    case image = "Generated image"
    case question = "Asked question"
    case tool = "Used tool"

    var symbol: String {
        switch self {
        case .commands: "terminal"
        case .filesRead: "doc.text.magnifyingglass"
        case .filesEdited: "pencil"
        case .web: "globe"
        case .browser: "safari"
        case .computer: "display"
        case .agents: "person.2"
        case .processes: "gearshape.2"
        case .image: "photo"
        case .question: "questionmark.bubble"
        case .tool: "wrench.and.screwdriver"
        }
    }

    static func classify(toolName: String) -> ToolActivityKind {
        let name = toolName.lowercased()
        if name == "bash" { return .commands }
        if ["read", "grep", "find", "ls"].contains(name) { return .filesRead }
        if ["edit", "write"].contains(name) { return .filesEdited }
        if ["web_search", "fetch_content", "get_search_content", "source_check"].contains(name) { return .web }
        if name == "chrome_js" || name.hasPrefix("chrome_") { return .browser }
        if ["computer_js", "observe_ui", "act_ui", "find_roots"].contains(name) { return .computer }
        if name == "agent" || name == "get_subagent_result" || name == "steer_subagent" || name.hasPrefix("subagent") {
            return .agents
        }
        if name == "process" { return .processes }
        if name == "imagegen" { return .image }
        if name == "ask_user_question" { return .question }
        return .tool
    }
}

struct TranscriptActivityStep: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ToolActivityKind
    let arguments: JSONValue
    var result: ChatMessage?

    var failed: Bool { result?.isError == true }
    var complete: Bool { result != nil }

    /// Tool detail stays textual; visual results are rendered once at the turn level.
    var resultTextBlocks: [MessageBlock] {
        result?.blocks.filter {
            guard case let .text(text) = $0.kind else { return false }
            return !text.isEmpty
        } ?? []
    }

    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord
    }
}

/// One reasoning block inside a turn's work log.
struct TranscriptThinking: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let streaming: Bool
}

/// Everything Pi did inside one turn before its answer, in the order it happened.
enum TranscriptWorkEntry: Identifiable, Hashable, Sendable {
    case thinking(TranscriptThinking)
    case activity(TranscriptActivityGroup)
    /// Narration Pi produced mid-turn, plus system/custom/unknown entries that belong to the log.
    case note(ChatMessage)

    var id: String {
        switch self {
        case let .thinking(value): "thinking:\(value.id)"
        case let .activity(group): "activity:\(group.id)"
        // Block-derived so narration split around a tool call keeps two distinct identities.
        case let .note(message): "note:\(message.blocks.first?.id ?? message.id)"
        }
    }
}

/// A turn's work log: details collapse once Pi answers, while prominent outputs remain visible.
struct TranscriptWorkBlock: Identifiable, Hashable, Sendable {
    let id: String
    var entries: [TranscriptWorkEntry]
    var isActive: Bool
    var startedAt: Date?
    var endedAt: Date?
    /// True only when the turn's own answer failed (an error/aborted assistant message) — never
    /// merely because some tool call inside the log failed. A failed grep or a retried command
    /// is routine mid-turn noise; the collapsed header should only alarm the user when the
    /// response itself did not come back.
    var answerFailed = false

    var activities: [TranscriptActivityGroup] {
        entries.compactMap { if case let .activity(group) = $0 { return group } else { return nil } }
    }

    /// Steps with turn-level output: images stay visible, and live questionnaires are actionable.
    var prominentSteps: [TranscriptActivityStep] {
        activities.flatMap(\.steps).filter { $0.kind == .question || !($0.result?.images.isEmpty ?? true) }
    }

    var stepCount: Int { activities.reduce(0) { $0 + $1.steps.count } }
    /// At least one tool step failed somewhere in the log. Individual steps still show red where
    /// they are, but this alone must never drive the collapsed header's "· failed" label.
    var hasFailure: Bool { activities.contains(where: \.hasFailure) }

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        let value = endedAt.timeIntervalSince(startedAt)
        return value > 0 ? value : nil
    }

    /// The settled headline. A missing or nonsensical timestamp pair falls back to step counts
    /// rather than printing a bogus duration.
    var title: String {
        if let duration { return "Worked for \(NumberFormatting.duration(duration))" }
        if stepCount > 0 { return "Worked · \(stepCount) step\(stepCount == 1 ? "" : "s")" }
        return "Worked"
    }
}

/// Compaction and branch summaries are session-level events: always visible, never buried.
struct TranscriptCompaction: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let timestamp: Date?

    /// Pi writes these as system entries whose first block is the title; matching on that keeps
    /// the parser's shape untouched.
    static let titles: Set<String> = ["Context compacted", "Branch summary"]

    init?(message: ChatMessage) {
        guard message.role == .system else { return nil }
        let texts = message.blocks.compactMap { block -> String? in
            guard case let .text(value) = block.kind else { return nil }
            return value
        }
        guard let title = texts.first, Self.titles.contains(title) else { return nil }
        id = message.id
        self.title = title
        summary = texts.dropFirst().joined(separator: "\n")
        timestamp = message.timestamp
    }
}

struct TranscriptActivityGroup: Identifiable, Hashable, Sendable {
    let id: String
    var steps: [TranscriptActivityStep]
    var isActive: Bool

    var hasFailure: Bool { steps.contains(where: \.failed) }
    /// Tool details are always opt-in. Failures stay unmistakable in the red summary, but one
    /// failed step must never explode a long high-level activity group into dozens of rows.
    var shouldStartExpanded: Bool { false }
    var completedCount: Int { steps.filter(\.complete).count }
    var currentStep: TranscriptActivityStep? { steps.last(where: { !$0.complete }) ?? steps.last }

    var kinds: [ToolActivityKind] {
        var seen: Set<ToolActivityKind> = []
        return steps.compactMap { seen.insert($0.kind).inserted ? $0.kind : nil }
    }

    var summary: String {
        let labels = kinds.map(\.rawValue)
        guard !labels.isEmpty else { return ToolActivityKind.tool.rawValue }
        if labels.count == 1 { return labels[0] }
        if labels.count == 2 { return labels.joined(separator: " and ") }
        return labels.dropLast().joined(separator: ", ") + ", and " + labels.last!
    }

    var progressText: String? {
        guard isActive else { return "\(steps.count) step\(steps.count == 1 ? "" : "s")" }
        let index = max(1, steps.firstIndex(where: { !$0.complete }).map { $0 + 1 } ?? steps.count)
        return "Step \(index) of \(steps.count)"
    }
}

enum TranscriptItem: Identifiable, Hashable, Sendable {
    case message(ChatMessage, streaming: Bool)
    case work(TranscriptWorkBlock)
    case compaction(TranscriptCompaction)

    var sourceMessageID: String? {
        switch self {
        case let .message(message, _): message.id
        case let .compaction(note): note.id
        case .work: nil
        }
    }

    var id: String {
        switch self {
        // Identity is the durable source message plus the block it starts at (one assistant
        // message can split into narration and an answer). The streaming flag is deliberately
        // absent: an answer that settles must keep the row it was streaming into, not be torn
        // down and re-laid-out under a new identity.
        case let .message(message, _):
            "message:\(message.id):\(message.blocks.first?.id ?? "")"
        case let .work(block): block.id
        case let .compaction(note): "compaction:\(note.id)"
        }
    }
}

/// Projects raw Pi messages into Codex-style turns: one user message, one collapsible work log
/// (reasoning, tool activity, mid-turn narration), then the answer. Nothing in the retained
/// session data is changed; this is presentation only.
enum TranscriptPresenter {
    static func items(messages: [ChatMessage], streaming: ChatMessage?, isRunning: Bool = false) -> [TranscriptItem] {
        var builder = TurnBuilder(isLive: isRunning || streaming != nil)
        for message in messages { builder.consume(message, streaming: false) }
        // A settled message and its still-held streaming copy now share one identity, so the
        // live copy is dropped once the settled one has landed rather than rendering twice.
        if let streaming, !messages.contains(where: { $0.id == streaming.id }) {
            builder.consume(streaming, streaming: true)
        }
        return builder.finish()
    }
}

/// Single pass over the message list. The work log accumulates until Pi's answer closes the
/// turn, so trailing prose has to be held back until we know no more tools follow it.
private struct TurnBuilder {
    let isLive: Bool

    private var result: [TranscriptItem] = []
    private var entries: [TranscriptWorkEntry] = []
    private var pending: TranscriptActivityGroup?
    /// Prose that is the answer unless more work arrives after it.
    private var trailing: [TranscriptItem] = []
    /// True once the held prose was produced *after* this turn's reasoning/tool calls: that is
    /// the turn's answer, and anything arriving later opens a new turn instead of burying it.
    private var trailingIsAnswer = false
    private var turnStart: Date?
    private var lastTimestamp: Date?
    /// The last assistant message's error state seen so far this turn — overwritten, not OR'd,
    /// so a transient error Pi auto-retried past does not leave the settled turn flagged failed.
    private var turnAnswerFailed = false

    init(isLive: Bool) { self.isLive = isLive }

    mutating func consume(_ message: ChatMessage, streaming: Bool) {
        if let timestamp = message.timestamp { lastTimestamp = timestamp }

        switch message.role {
        case .user:
            closeTurn(active: false)
            turnStart = message.timestamp
            result.append(.message(message, streaming: streaming))
        case .assistant:
            consumeAssistant(message, streaming: streaming)
        case .tool, .bash:
            attachResult(message)
        case .system:
            if let note = TranscriptCompaction(message: message) {
                closeTurn(active: false)
                result.append(.compaction(note))
            } else {
                log(message, streaming: streaming)
            }
        case .custom, .unknown:
            log(message, streaming: streaming)
        }
    }

    mutating func finish() -> [TranscriptItem] {
        closeTurn(active: isLive && trailing.isEmpty)
        return result
    }

    // MARK: - Message kinds

    private mutating func consumeAssistant(_ message: ChatMessage, streaming: Bool) {
        // Blocks are handled in order, so narration that precedes a tool call stays above it in
        // the work log instead of being reordered after it.
        var prose: [MessageBlock] = []

        func proseMessage() -> ChatMessage? {
            let hasContent = prose.contains { block in
                if case let .text(text) = block.kind {
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true
            }
            defer { prose.removeAll(keepingCapacity: true) }
            guard hasContent else { return nil }
            var visible = message
            visible.blocks = prose
            return visible
        }

        for block in message.blocks {
            switch block.kind {
            case let .thinking(text):
                // Narration that precedes reasoning or a tool call is log, not the answer, and
                // belongs at this exact position in the work block.
                if let narration = proseMessage() { demoteTrailing(); entries.append(.note(narration)) }
                demoteTrailing()
                closeActivity()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries.append(.thinking(TranscriptThinking(id: block.id, text: text, streaming: streaming)))
                }
            case let .toolCall(call):
                if let narration = proseMessage() { demoteTrailing(); entries.append(.note(narration)) }
                demoteTrailing()
                appendCall(call)
            default:
                prose.append(block)
            }
        }
        // Recorded after the blocks, not before them: a `demoteTrailing()` inside the loop can
        // close the previous turn, whose header must report *that* turn's answer, not this one.
        turnAnswerFailed = message.isError
        if let answer = proseMessage() {
            // Prose that follows this turn's own work or carries a terminal stop reason is the
            // answer, not narration. Later custom/system updates must never bury a plain final.
            if !entries.isEmpty || pending != nil
                || SessionParser.terminalAssistantStopReasons.contains(message.stopReason ?? "") {
                trailingIsAnswer = true
            }
            trailing.append(.message(answer, streaming: streaming))
        }
    }

    /// System, custom, and unknown entries join the work log when a turn is in flight and stand
    /// on their own otherwise, so an extension message is never silently swallowed.
    private mutating func log(_ message: ChatMessage, streaming: Bool) {
        demoteTrailing()
        if entries.isEmpty, pending == nil, trailing.isEmpty {
            result.append(.message(message, streaming: streaming))
        } else {
            entries.append(.note(message))
        }
    }

    // MARK: - Tool activity

    private mutating func appendCall(_ call: ToolCallPayload) {
        if pending == nil { pending = TranscriptActivityGroup(id: call.id, steps: [], isActive: true) }
        pending?.steps.append(TranscriptActivityStep(
            id: call.id,
            name: call.name,
            kind: ToolActivityKind.classify(toolName: call.name),
            arguments: call.arguments,
            result: nil
        ))
    }

    private mutating func attachResult(_ message: ChatMessage) {
        let callID = message.toolCallID ?? message.id
        if let index = pending?.steps.lastIndex(where: { $0.id == callID }) {
            pending?.steps[index].result = message
            return
        }
        // A result can land after reasoning already closed its group.
        for entryIndex in entries.indices.reversed() {
            guard case var .activity(group) = entries[entryIndex],
                  let stepIndex = group.steps.lastIndex(where: { $0.id == callID && $0.result == nil }) else { continue }
            group.steps[stepIndex].result = message
            entries[entryIndex] = .activity(group)
            return
        }

        // An orphan result (resumed session, tool call outside the loaded branch) still shows.
        let name = message.toolName ?? (message.role == .bash ? "bash" : "tool")
        demoteTrailing()
        if pending == nil { pending = TranscriptActivityGroup(id: callID, steps: [], isActive: true) }
        pending?.steps.append(TranscriptActivityStep(
            id: callID,
            name: name,
            kind: ToolActivityKind.classify(toolName: name),
            arguments: .object([:]),
            result: message
        ))
    }

    // MARK: - Turn assembly

    /// Prose followed by more work was narration, not the answer — but only when it also came
    /// *before* that work. Prose Pi wrote after its tool calls is the turn's answer: a late tool
    /// result, a process update, or a follow-on tool call opens a new turn under it rather than
    /// collapsing the answer the user is reading into the work log.
    private mutating func demoteTrailing() {
        guard !trailing.isEmpty else { return }
        if trailingIsAnswer {
            closeTurn(active: false)
            return
        }
        closeActivity()
        for item in trailing {
            if case let .message(message, _) = item { entries.append(.note(message)) }
        }
        trailing.removeAll(keepingCapacity: true)
    }

    private mutating func closeActivity(active: Bool = false) {
        guard var group = pending, !group.steps.isEmpty else {
            pending = nil
            return
        }
        group.isActive = active
        entries.append(.activity(group))
        pending = nil
    }

    private mutating func closeTurn(active: Bool) {
        closeActivity(active: active)
        if !entries.isEmpty {
            // Identity comes from the first entry's own durable id (a block, tool call, or
            // message id), never a turn counter: prepending earlier history must not renumber
            // every work block below it.
            result.append(.work(TranscriptWorkBlock(
                id: "work:\(entries.first?.id ?? "")",
                entries: entries,
                isActive: active,
                startedAt: turnStart,
                endedAt: lastTimestamp,
                answerFailed: turnAnswerFailed
            )))
        }
        result.append(contentsOf: trailing)
        entries.removeAll(keepingCapacity: true)
        trailing.removeAll(keepingCapacity: true)
        trailingIsAnswer = false
        turnAnswerFailed = false
        // Work that follows a settled answer starts its own clock instead of inheriting the
        // finished turn's start and reporting a duration that spans both.
        turnStart = lastTimestamp
    }
}
