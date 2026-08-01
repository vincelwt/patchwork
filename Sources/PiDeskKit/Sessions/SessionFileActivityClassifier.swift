import Foundation

public enum SessionFileRunState: String, Equatable, Sendable {
    case running
    case idle
    case unknown
}

public struct SessionFileTailEvidence: Equatable, Sendable {
    public let lastEntry: PiJSONValue?
    /// A newer record started but was not yet valid JSON. This is distinct from a complete
    /// metadata-only record: the former is evidence of a write in progress, while the latter
    /// says nothing about whether an agent turn is active.
    public let hasNewerIncompleteRecord: Bool

    public init(lastEntry: PiJSONValue?, hasNewerIncompleteRecord: Bool) {
        self.lastEntry = lastEntry
        self.hasNewerIncompleteRecord = hasNewerIncompleteRecord
    }
}

/// Shared bounded file-tail fallback for the native app and daemon. Agent records are projected
/// through the same transcoder before classification, so Pi, Codex, and Claude Code follow one
/// running-state contract when no authoritative heartbeat exists.
public enum SessionFileActivityClassifier {
    public static let recentWriteWindow: TimeInterval = 6
    public static let staleNonTerminalWindow: TimeInterval = 15
    public static let idleWindow: TimeInterval = 90
    public static let tailByteLimit = 256 * 1_024
    public static let lastEntryScanLines = 64
    /// Codex can emit long runs of bookkeeping after a lifecycle marker. This stays explicitly
    /// bounded while looking farther back for completion than ordinary renderable-entry scans.
    public static let codexLifecycleScanLines = 512
    public static let terminalStopReasons: Set<String> = [
        "stop", "length", "error", "aborted",
    ]

    public static func classify(
        lastEntry: PiJSONValue?, age: TimeInterval,
        hasNewerIncompleteRecord: Bool = false
    ) -> SessionFileRunState {
        if age > idleWindow { return .idle }
        // A JSONL append is briefly visible before its record is complete. It can also exceed
        // the bounded tail window, leaving only an undecodable suffix. In either case the fresh
        // write wins briefly over an older terminal entry, long enough to bridge the append race
        // without letting a malformed suffix hold a stopped thread open. A complete
        // metadata-only record does not set this flag and therefore cannot make an idle new
        // thread look busy.
        if hasNewerIncompleteRecord, age <= recentWriteWindow { return .running }
        if isTerminalStop(lastEntry) { return .idle }
        // A fresh complete metadata-only file is not evidence of an active turn. Authoritative
        // queue/heartbeat state and the app's pending submission cover the short creation window
        // without making idle new threads reject runtime controls.
        guard let entry = lastEntry else {
            return age > staleNonTerminalWindow ? .idle : .unknown
        }
        if age <= recentWriteWindow { return .running }
        guard age <= staleNonTerminalWindow else { return .idle }

        let type = entry["type"]?.stringValue
        if type == "bashExecution" { return .running }
        guard type == "message", let message = entry["message"] else { return .unknown }
        switch message["role"]?.stringValue {
        case "user", "toolResult", "bashExecution":
            return .running
        case "assistant":
            return message["stopReason"]?.stringValue == "toolUse" ? .running : .unknown
        default:
            return .unknown
        }
    }

    public static func lastEntry(
        inTail tail: Data, transcoder: AgentSessionTranscoder = .pi
    ) -> PiJSONValue? {
        tailEvidence(inTail: tail, transcoder: transcoder).lastEntry
    }

    public static func tailEvidence(
        inTail tail: Data, transcoder: AgentSessionTranscoder = .pi
    ) -> SessionFileTailEvidence {
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        var hasNewerIncompleteRecord = false
        var sawNewerValidRawRecord = false
        var codexProgressEntry: PiJSONValue?
        let scanLimit = transcoder.agent == .codex ? codexLifecycleScanLines : lastEntryScanLines
        for (index, line) in lines.reversed().prefix(scanLimit).enumerated() {
            var record = Data(line)
            if record.last == 0x0D { record.removeLast() }
            guard !record.isEmpty else { continue }
            guard let raw = try? PiJSONValue.decode(record) else {
                if !sawNewerValidRawRecord { hasNewerIncompleteRecord = true }
                continue
            }
            sawNewerValidRawRecord = true
            if transcoder.agent == .codex {
                if let marker = codexLifecycleMarker(raw) {
                    return SessionFileTailEvidence(
                        lastEntry: marker,
                        hasNewerIncompleteRecord: hasNewerIncompleteRecord
                    )
                }
                if codexProgressEntry == nil {
                    codexProgressEntry = codexProgressMarker(raw)
                }
            }
            // Renderable history keeps the tighter scan limit. Beyond it, Codex needs only the
            // cheap lifecycle/progress fallback above so opening a busy rollout stays bounded.
            guard index < lastEntryScanLines else { continue }
            guard let projected = transcoder.transcode(record),
                  let value = try? PiJSONValue.decode(projected),
                  ["message", "bashExecution"].contains(
                    value["type"]?.stringValue ?? ""
                  ) else { continue }
            return SessionFileTailEvidence(
                lastEntry: value,
                hasNewerIncompleteRecord: hasNewerIncompleteRecord
            )
        }
        return SessionFileTailEvidence(
            lastEntry: codexProgressEntry,
            hasNewerIncompleteRecord: hasNewerIncompleteRecord
        )
    }

    public static func readTail(at url: URL, limit: Int = tailByteLimit) -> Data? {
        guard limit >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let boundedLimit = UInt64(limit)
        let offset = end > boundedLimit ? end - boundedLimit : 0
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: limit)
    }

    public static func isRunning(
        sessionFile: URL,
        agent: AgentKind,
        modifiedAt: Date,
        now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(modifiedAt)
        if age > idleWindow { return false }
        let transcoder = AgentSessionTranscoder.make(for: agent)
        guard let tail = readTail(at: sessionFile) else { return false }
        let evidence = tailEvidence(inTail: tail, transcoder: transcoder)
        return classify(
            lastEntry: evidence.lastEntry,
            age: age,
            hasNewerIncompleteRecord: evidence.hasNewerIncompleteRecord
        ) == .running
    }

    private static func isTerminalStop(_ entry: PiJSONValue?) -> Bool {
        guard entry?["type"]?.stringValue == "message",
              let message = entry?["message"],
              message["role"]?.stringValue == "assistant",
              let reason = message["stopReason"]?.stringValue else { return false }
        return terminalStopReasons.contains(reason)
    }

    private static func codexLifecycleMarker(_ raw: PiJSONValue) -> PiJSONValue? {
        guard raw["type"]?.stringValue == "event_msg",
              let type = raw["payload"]?["type"]?.stringValue else { return nil }
        let id = raw["payload"]?["turn_id"]?.stringValue
            ?? raw["payload"]?["id"]?.stringValue
            ?? "codex-lifecycle"
        switch type {
        case "task_started", "turn_started":
            return .object([
                "type": .string("message"),
                "id": .string(id),
                "message": .object(["role": .string("user")]),
            ])
        case "task_complete", "turn_complete", "turn_completed":
            return .object([
                "type": .string("message"),
                "id": .string(id),
                "message": .object([
                    "role": .string("assistant"), "stopReason": .string("stop"),
                ]),
            ])
        case "turn_aborted", "task_aborted":
            return .object([
                "type": .string("message"),
                "id": .string(id),
                "message": .object([
                    "role": .string("assistant"), "stopReason": .string("aborted"),
                ]),
            ])
        default:
            return nil
        }
    }

    /// A fresh Codex event means the app reopened in the middle of a turn even when
    /// `task_started` has scrolled beyond the bounded tail. The caller keeps scanning before
    /// using this fallback, so a nearby complete/aborted marker or projected final answer wins.
    private static func codexProgressMarker(_ raw: PiJSONValue) -> PiJSONValue? {
        guard raw["type"]?.stringValue == "event_msg",
              let type = raw["payload"]?["type"]?.stringValue,
              !type.isEmpty else { return nil }
        let id = raw["payload"]?["turn_id"]?.stringValue
            ?? raw["payload"]?["id"]?.stringValue
            ?? "codex-progress"
        return .object([
            "type": .string("message"),
            "id": .string(id),
            "message": .object(["role": .string("user")]),
        ])
    }
}
