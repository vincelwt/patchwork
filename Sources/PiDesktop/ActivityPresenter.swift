import Foundation

protocol ActivityPresenting: Sendable {
    func activities(from messages: [ChatMessage]) -> [ActivityItem]
}

struct ActivityPresenter: ActivityPresenting {
    func activities(from messages: [ChatMessage]) -> [ActivityItem] {
        var items: [String: ActivityItem] = [:]
        var ordering: [String] = []
        var sourceAliases: [String: String] = [:]
        var unresolvedSubagents: [String: String] = [:]

        for message in messages {
            // A later assistant turn proves an earlier subagent tool call without a result was
            // interrupted. Background launches are unaffected because their immediate
            // `status: background` result removes them from this unresolved set.
            if message.role == .assistant {
                for itemID in unresolvedSubagents.values {
                    guard var item = items[itemID], [.running, .waiting, .queued].contains(item.status) else { continue }
                    item.status = .stopped
                    item.endedAt = message.timestamp
                    items[itemID] = item
                }
                unresolvedSubagents.removeAll(keepingCapacity: true)
            }

            for block in message.blocks {
                guard case let .toolCall(call) = block.kind,
                      let item = Self.activityForToolCall(call, timestamp: message.timestamp, modelName: message.modelName)
                else { continue }
                items[item.id] = item
                sourceAliases[call.id] = item.id
                if item.kind == .subagent { unresolvedSubagents[call.id] = item.id }
                ordering.append(item.id)
            }

            if message.role == .tool, let callID = message.toolCallID,
               let itemID = sourceAliases[callID] ?? (items[callID] != nil ? callID : nil),
               var item = items[itemID] {
                unresolvedSubagents.removeValue(forKey: callID)
                Self.applyResult(
                    text: message.textContent,
                    details: message.details,
                    endedAt: message.timestamp,
                    isError: message.isError,
                    to: &item
                )
                items[itemID] = item
            }

            if let customItem = Self.activityForCustomMessage(message) {
                if let existing = items[customItem.id] {
                    items[customItem.id] = Self.merged(customItem, with: existing)
                } else {
                    items[customItem.id] = customItem
                    ordering.append(customItem.id)
                }
            }
        }

        var seen: Set<String> = []
        let ordered = ordering.reversed().compactMap { id -> ActivityItem? in
            guard seen.insert(id).inserted else { return nil }
            return items[id]
        }
        return Self.collapsingAgentOperations(ordered)
    }

    static func activityForToolStart(event: JSONValue, modelName: String? = nil) -> ActivityItem? {
        guard let callID = event["toolCallId"]?.stringValue,
              let name = event["toolName"]?.stringValue
        else { return nil }
        let call = ToolCallPayload(id: callID, name: name, arguments: event["args"] ?? .object([:]))
        return activityForToolCall(call, timestamp: Date(), modelName: modelName)
    }

    static func activityForToolCall(_ call: ToolCallPayload, timestamp: Date?, modelName: String? = nil) -> ActivityItem? {
        let normalized = call.name.lowercased()
        let readableKind = ToolActivityKind.classify(toolName: call.name)
        let kind: ActivityKind
        if readableKind == .agents { kind = .subagent }
        else if readableKind == .processes { kind = .process }
        else { kind = .tool }

        let action = call.arguments["action"]?.stringValue
        var title: String
        var subtitle: String?
        var status: ActivityStatus = .running

        switch kind {
        case .subagent:
            let agent = call.arguments["subagent_type"]?.stringValue
                ?? call.arguments["agent"]?.stringValue
                ?? call.arguments["tasks"]?.arrayValue?.first?["subagent_type"]?.stringValue
                ?? call.arguments["tasks"]?.arrayValue?.first?["agent"]?.stringValue
            let description = call.arguments["description"]?.stringValue
                ?? call.arguments["task"]?.stringValue
            if normalized.contains("wait") || normalized == "get_subagent_result" {
                title = "Waiting for agents"
                status = .waiting
            } else {
                title = description?.condensedPrefix(110)
                    ?? agent.map { "\($0.capitalized) agent" }
                    ?? readableKind.rawValue
            }
            subtitle = action
        case .process:
            title = call.arguments["name"]?.stringValue
                ?? call.arguments["processName"]?.stringValue
                ?? readableKind.rawValue
            subtitle = action ?? call.arguments["command"]?.stringValue?.condensedPrefix(110)
        case .tool:
            title = readableKind.rawValue
            subtitle = action
                ?? call.arguments["title"]?.stringValue?.condensedPrefix(110)
                ?? call.arguments["command"]?.stringValue?.condensedPrefix(110)
                ?? call.arguments["path"]?.stringValue?.condensedPrefix(110)
        }

        let stableID = call.arguments["processId"]?.stringValue
            ?? call.arguments["runId"]?.stringValue
            ?? call.arguments["id"]?.stringValue
            ?? call.arguments["process"]?["id"]?.stringValue
            ?? call.arguments["run"]?["id"]?.stringValue
            ?? call.id

        return ActivityItem(
            id: stableID,
            sourceID: call.id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            status: status,
            startedAt: timestamp,
            raw: call.arguments.boundedProjection(),
            agentID: kind == .subagent ? call.arguments["agent_id"]?.stringValue : nil,
            agentType: kind == .subagent ? (
                call.arguments["subagent_type"]?.stringValue
                    ?? call.arguments["agent"]?.stringValue
                    ?? call.arguments["tasks"]?.arrayValue?.first?["subagent_type"]?.stringValue
                    ?? call.arguments["tasks"]?.arrayValue?.first?["agent"]?.stringValue
            ) : nil,
            modelName: kind == .subagent && !normalized.contains("wait") && normalized != "get_subagent_result"
                ? (call.arguments["model"]?.stringValue ?? modelName)
                : nil
        )
    }

    private static func activityForCustomMessage(_ message: ChatMessage) -> ActivityItem? {
        guard let customType = message.customType else { return nil }

        if customType == "ad-process:update", let details = message.details {
            let processID = details["processId"]?.stringValue ?? message.id
            let statusString = details["status"]?.stringValue ?? "unknown"
            let success = details["success"]?.boolValue
            return ActivityItem(
                id: processID,
                sourceID: message.toolCallID,
                kind: .process,
                title: details["processName"]?.stringValue ?? "Background process",
                subtitle: details["command"]?.stringValue,
                detail: details["runtime"]?.stringValue,
                status: mapStatus(statusString, success: success),
                startedAt: message.timestamp,
                endedAt: ["completed", "failed", "stopped"].contains(statusString) ? message.timestamp : nil,
                raw: details.boundedProjection()
            )
        }

        if customType == "subagent_control_notice", let event = message.details?["event"] {
            let runID = event["runId"]?.stringValue ?? message.id
            let eventType = event["type"]?.stringValue ?? "notice"
            return ActivityItem(
                id: runID,
                sourceID: message.toolCallID,
                kind: .subagent,
                title: event["agent"]?.stringValue.map { "\($0.capitalized) agent" } ?? "Subagent",
                subtitle: event["reason"]?.stringValue ?? eventType,
                detail: event["message"]?.stringValue,
                status: eventType.contains("attention") ? .waiting : .running,
                startedAt: message.timestamp,
                raw: event.boundedProjection(),
                agentID: runID,
                agentType: event["agent"]?.stringValue
            )
        }

        if customType == "subagent-notify" || customType == "subagent-notification" {
            let details = message.details
            let agentID = details?["id"]?.stringValue ?? message.id
            let duration = details?["durationMs"]?.doubleValue.map { $0 / 1_000 }
            let endedAt = message.timestamp
            return ActivityItem(
                id: agentID,
                sourceID: message.toolCallID,
                kind: .subagent,
                title: details?["description"]?.stringValue ?? "Subagent update",
                detail: details?["resultPreview"]?.stringValue ?? message.textContent.condensedPrefix(600),
                status: mapStatus(details?["status"]?.stringValue ?? "succeeded"),
                startedAt: endedAt.flatMap { end in duration.map { end.addingTimeInterval(-$0) } },
                endedAt: endedAt,
                raw: details?.boundedProjection() ?? .null,
                agentID: agentID,
                toolCallCount: details?["toolUses"]?.intValue,
                duration: duration
            )
        }
        return nil
    }

    static func applyResult(
        _ result: JSONValue?,
        finished: Bool,
        endedAt: Date? = nil,
        isError: Bool = false,
        to item: inout ActivityItem
    ) {
        let text = result?["content"]?.arrayValue?
            .compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            .joined(separator: "\n") ?? ""
        applyResult(
            text: text,
            details: result?["details"],
            finished: finished,
            endedAt: endedAt,
            isError: isError,
            to: &item
        )
    }

    private static func applyResult(
        text: String,
        details: JSONValue?,
        finished: Bool = true,
        endedAt: Date?,
        isError: Bool,
        to item: inout ActivityItem
    ) {
        if !text.isEmpty { item.detail = text.condensedPrefix(600) }

        if item.kind == .subagent {
            item.agentID = details?["agentId"]?.stringValue
                ?? field("Agent", in: text)
                ?? item.agentID
            item.agentType = details?["subagentType"]?.stringValue
                ?? field("Type", in: text)
                ?? item.agentType
            item.modelName = details?["modelName"]?.stringValue ?? item.modelName
            if let description = details?["description"]?.stringValue ?? field("Description", in: text) {
                item.title = description.condensedPrefix(110)
            }

            let reportedStatus = details?["status"]?.stringValue
            if let count = details?["toolUses"]?.intValue ?? parsedToolCalls(from: text),
               count > 0 || (finished && reportedStatus != "background") {
                item.toolCallCount = count
            }
            if let seconds = details?["durationMs"]?.doubleValue.map({ $0 / 1_000 })
                ?? parsedDuration(from: text), seconds > 0 {
                item.duration = seconds
            }

            if let reportedStatus {
                item.status = mapStatus(reportedStatus)
                item.endedAt = [.running, .waiting, .queued].contains(item.status) ? nil : endedAt
                return
            }
        }

        if finished {
            item.status = isError ? .failed : .succeeded
            item.endedAt = endedAt
        }
    }

    static func merged(_ preferred: ActivityItem, with fallback: ActivityItem) -> ActivityItem {
        var item = preferred
        if ["Ran agents", "Waiting for agents", "Subagent", "Subagent update"].contains(item.title),
           !["Ran agents", "Waiting for agents", "Subagent", "Subagent update"].contains(fallback.title) {
            item.title = fallback.title
        }
        item.subtitle = item.subtitle ?? fallback.subtitle
        item.detail = item.detail ?? fallback.detail
        item.agentID = item.agentID ?? fallback.agentID
        item.agentType = item.agentType ?? fallback.agentType
        item.modelName = item.modelName ?? fallback.modelName
        if item.toolCallCount == nil || item.toolCallCount == 0 {
            item.toolCallCount = fallback.toolCallCount ?? item.toolCallCount
        }
        item.duration = max(item.duration ?? 0, fallback.duration ?? 0).nonZero
        item.startedAt = [item.startedAt, fallback.startedAt].compactMap { $0 }.min()
        item.endedAt = [item.endedAt, fallback.endedAt].compactMap { $0 }.max()
        if item.status == .unknown { item.status = fallback.status }
        return item
    }

    private static func collapsingAgentOperations(_ items: [ActivityItem]) -> [ActivityItem] {
        var result: [ActivityItem] = []
        var positions: [String: Int] = [:]
        for item in items {
            guard item.kind == .subagent, let agentID = item.agentID else {
                result.append(item)
                continue
            }
            if let index = positions[agentID] {
                result[index] = merged(result[index], with: item)
            } else {
                positions[agentID] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func field(_ name: String, in text: String) -> String? {
        let prefix = "\(name):"
        return text.split(whereSeparator: { $0 == "\n" || $0 == "|" }).lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func parsedToolCalls(from text: String) -> Int? {
        if let value = field("Tool uses", in: text) { return Int(value) }
        guard let range = text.range(of: #"\d+\s+tool uses?"#, options: .regularExpression) else { return nil }
        return Int(text[range].prefix { $0.isNumber })
    }

    private static func parsedDuration(from text: String) -> TimeInterval? {
        let candidate: String?
        if let value = field("Duration", in: text) {
            candidate = value
        } else if let start = text.range(of: "Agent completed in ") {
            candidate = String(text[start.upperBound...].split(separator: "(", maxSplits: 1).first ?? "")
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }

        var total: TimeInterval = 0
        var found = false
        for token in candidate.split(whereSeparator: { $0.isWhitespace }) {
            let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ","))
            let unit: String
            let multiplier: TimeInterval
            if value.hasSuffix("ms") { unit = "ms"; multiplier = 0.001 }
            else if value.hasSuffix("s") { unit = "s"; multiplier = 1 }
            else if value.hasSuffix("m") { unit = "m"; multiplier = 60 }
            else if value.hasSuffix("h") { unit = "h"; multiplier = 3_600 }
            else if value.hasSuffix("d") { unit = "d"; multiplier = 86_400 }
            else { continue }
            guard let number = Double(value.dropLast(unit.count)) else { continue }
            total += number * multiplier
            found = true
        }
        return found ? total : nil
    }

    static func mapStatus(_ value: String, success: Bool? = nil) -> ActivityStatus {
        if success == true { return .succeeded }
        if success == false { return .failed }
        switch value.lowercased() {
        case "queued", "pending": return .queued
        case "running", "active", "started", "background": return .running
        case "waiting", "needs_attention", "paused": return .waiting
        case "complete", "completed", "success", "succeeded", "ok", "steered": return .succeeded
        case "failed", "error": return .failed
        case "stopped", "cancelled", "aborted": return .stopped
        default: return .unknown
        }
    }
}

extension ActivityItem {
    func agentSummary(now: Date = Date()) -> String? {
        guard kind == .subagent else { return nil }
        var parts: [String] = []
        if let agentType, !agentType.isEmpty { parts.append(agentType) }
        if let modelName, !modelName.isEmpty { parts.append(ModelNaming.pretty(modelName)) }
        if let toolCallCount { parts.append("\(toolCallCount) calls") }

        let runtime: TimeInterval?
        if [.running, .waiting, .queued].contains(status), let startedAt {
            runtime = now.timeIntervalSince(startedAt)
        } else {
            runtime = duration ?? endedAt.flatMap { end in startedAt.map { end.timeIntervalSince($0) } }
        }
        let facts = parts.joined(separator: " · ")
        guard let runtime else { return facts.isEmpty ? nil : facts }
        let time = NumberFormatting.compactDuration(runtime)
        return facts.isEmpty ? time : "\(facts) / \(time)"
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}

private extension String {
    func condensedPrefix(_ length: Int) -> String {
        let clean = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > length else { return clean }
        return String(clean.prefix(length - 1)) + "…"
    }
}
