import Foundation

protocol ActivityPresenting {
    func activities(from messages: [ChatMessage]) -> [ActivityItem]
}

struct ActivityPresenter: ActivityPresenting {
    func activities(from messages: [ChatMessage]) -> [ActivityItem] {
        var items: [String: ActivityItem] = [:]
        var ordering: [String] = []
        var sourceAliases: [String: String] = [:]

        for message in messages {
            for block in message.blocks {
                guard case let .toolCall(call) = block.kind,
                      let item = Self.activityForToolCall(call, timestamp: message.timestamp)
                else { continue }
                items[item.id] = item
                sourceAliases[call.id] = item.id
                ordering.append(item.id)
            }

            if message.role == .tool, let callID = message.toolCallID,
               let itemID = sourceAliases[callID] ?? (items[callID] != nil ? callID : nil),
               var item = items[itemID] {
                item.status = message.isError ? .failed : .succeeded
                item.endedAt = message.timestamp
                item.detail = message.textContent.condensedPrefix(600)
                items[itemID] = item
            }

            if let customItem = Self.activityForCustomMessage(message) {
                if var existing = items[customItem.id] {
                    existing.status = customItem.status
                    existing.subtitle = customItem.subtitle ?? existing.subtitle
                    existing.detail = customItem.detail ?? existing.detail
                    existing.endedAt = customItem.endedAt ?? existing.endedAt
                    items[customItem.id] = existing
                } else {
                    items[customItem.id] = customItem
                    ordering.append(customItem.id)
                }
            }
        }

        var seen: Set<String> = []
        return ordering.reversed().compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return items[id]
        }
    }

    static func activityForToolStart(event: JSONValue) -> ActivityItem? {
        guard let callID = event["toolCallId"]?.stringValue,
              let name = event["toolName"]?.stringValue
        else { return nil }
        let call = ToolCallPayload(id: callID, name: name, arguments: event["args"] ?? .object([:]))
        return activityForToolCall(call, timestamp: Date())
    }

    static func activityForToolCall(_ call: ToolCallPayload, timestamp: Date?) -> ActivityItem? {
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
            let agent = call.arguments["agent"]?.stringValue
                ?? call.arguments["tasks"]?.arrayValue?.first?["agent"]?.stringValue
            if normalized.contains("wait") || normalized == "get_subagent_result" {
                title = "Waiting for agents"
                status = .waiting
            } else {
                title = agent.map { "\($0.capitalized) agent" } ?? readableKind.rawValue
            }
            subtitle = action ?? call.arguments["task"]?.stringValue?.condensedPrefix(110)
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
            raw: call.arguments.boundedProjection()
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
                raw: event.boundedProjection()
            )
        }

        if customType == "subagent-notify" {
            return ActivityItem(
                id: message.id,
                sourceID: message.toolCallID,
                kind: .subagent,
                title: "Subagent update",
                subtitle: message.textContent.condensedPrefix(140),
                status: .succeeded,
                startedAt: message.timestamp,
                endedAt: message.timestamp,
                raw: message.raw.boundedFallback(maxLength: 2_500)
            )
        }
        return nil
    }

    static func mapStatus(_ value: String, success: Bool? = nil) -> ActivityStatus {
        if success == true { return .succeeded }
        if success == false { return .failed }
        switch value.lowercased() {
        case "queued", "pending": return .queued
        case "running", "active", "started": return .running
        case "waiting", "needs_attention", "paused": return .waiting
        case "complete", "completed", "success", "succeeded", "ok": return .succeeded
        case "failed", "error": return .failed
        case "stopped", "cancelled", "aborted": return .stopped
        default: return .unknown
        }
    }
}

private extension String {
    func condensedPrefix(_ length: Int) -> String {
        let clean = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > length else { return clean }
        return String(clean.prefix(length - 1)) + "…"
    }
}
