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

    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ").capitalizedFirstWord
    }
}

struct TranscriptActivityGroup: Identifiable, Hashable, Sendable {
    let id: String
    var steps: [TranscriptActivityStep]
    var isActive: Bool

    var hasFailure: Bool { steps.contains(where: \.failed) }
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
    case activity(TranscriptActivityGroup)

    var id: String {
        switch self {
        case let .message(message, streaming): "message:\(streaming ? "stream:" : "")\(message.id)"
        case let .activity(group): "activity:\(group.id)"
        }
    }
}

/// Projects raw Pi messages into prose and compact tool groups without changing the retained
/// session data. A group ends when Pi produces prose (or a new user turn begins).
enum TranscriptPresenter {
    static func items(messages: [ChatMessage], streaming: ChatMessage?, isRunning: Bool = false) -> [TranscriptItem] {
        var result: [TranscriptItem] = []
        var pending: TranscriptActivityGroup?
        var deferredEntries: [TranscriptItem] = []

        func flush(active: Bool = false) {
            guard var group = pending, !group.steps.isEmpty else {
                pending = nil
                result.append(contentsOf: deferredEntries)
                deferredEntries.removeAll(keepingCapacity: true)
                return
            }
            group.isActive = active
            result.append(.activity(group))
            result.append(contentsOf: deferredEntries)
            deferredEntries.removeAll(keepingCapacity: true)
            pending = nil
        }

        func appendCalls(_ calls: [ToolCallPayload]) {
            guard !calls.isEmpty else { return }
            if pending == nil {
                pending = TranscriptActivityGroup(id: calls[0].id, steps: [], isActive: true)
            }
            pending?.steps.append(contentsOf: calls.map {
                TranscriptActivityStep(
                    id: $0.id,
                    name: $0.name,
                    kind: ToolActivityKind.classify(toolName: $0.name),
                    arguments: $0.arguments,
                    result: nil
                )
            })
        }

        func consume(_ message: ChatMessage, streaming isStreaming: Bool) {
            if message.role == .assistant {
                let calls = message.blocks.compactMap { block -> ToolCallPayload? in
                    guard case let .toolCall(call) = block.kind else { return nil }
                    return call
                }
                let visibleBlocks = message.blocks.filter {
                    if case .toolCall = $0.kind { return false }
                    return true
                }
                let hasProse = visibleBlocks.contains {
                    guard case let .text(text) = $0.kind else { return false }
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                if hasProse { flush() }
                if !visibleBlocks.isEmpty {
                    var visible = message
                    visible.blocks = visibleBlocks
                    result.append(.message(visible, streaming: isStreaming))
                }
                appendCalls(calls)
                return
            }

            if message.role == .tool || message.role == .bash {
                let callID = message.toolCallID ?? message.id
                if let index = pending?.steps.lastIndex(where: { $0.id == callID }) {
                    pending?.steps[index].result = message
                } else {
                    let name = message.toolName ?? (message.role == .bash ? "bash" : "tool")
                    if pending == nil {
                        pending = TranscriptActivityGroup(id: callID, steps: [], isActive: true)
                    }
                    pending?.steps.append(TranscriptActivityStep(
                        id: callID,
                        name: name,
                        kind: ToolActivityKind.classify(toolName: name),
                        arguments: .object([:]),
                        result: message
                    ))
                }
                return
            }

            if message.role == .user { flush() }
            let entry = TranscriptItem.message(message, streaming: isStreaming)
            if pending == nil { result.append(entry) }
            else { deferredEntries.append(entry) }
        }

        for message in messages { consume(message, streaming: false) }
        if let streaming { consume(streaming, streaming: true) }

        if let group = pending {
            let unfinished = group.steps.contains { !$0.complete }
            // During a run, a completed tool still waits for Pi's final prose. Historical groups
            // that ended without prose settle once every result is present.
            flush(active: isRunning || streaming != nil || unfinished)
        }
        return result
    }
}
