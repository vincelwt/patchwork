import Foundation

/// How a session file links its entries.
public enum AgentChainStyle: String, Sendable {
    /// Every entry names its parent, so the active branch is a walk backward from the leaf.
    case parentPointer
    /// The file is an append-only log with no branching; every entry is on the active path.
    case linear
}

/// Rewrites one foreign session record into the Pi session-record shape.
///
/// This is deliberately a `Data -> Data?` transform rather than a parallel parser hierarchy:
/// every existing consumer (the app's paging/tail/branch parser, the daemon's thread parser,
/// the summary cache, the backward reader) keeps working on Pi-shaped records and never learns
/// that another agent exists. `nil` drops the record.
///
/// ponytail: re-encoding each record costs one extra serialize/parse pass versus threading a
/// decoded value through both parsers. Only non-Pi agents pay it (Pi's transform is identity).
/// If a very large Codex or Claude transcript ever feels slow to open, the upgrade path is to
/// hand the parsers a decoded entry instead of bytes.
public struct AgentSessionTranscoder: Sendable {
    public let chain: AgentChainStyle
    public let transcode: @Sendable (Data) -> Data?

    public init(chain: AgentChainStyle, transcode: @escaping @Sendable (Data) -> Data?) {
        self.chain = chain
        self.transcode = transcode
    }

    /// Pi records are already in the target shape, so this is the identity transform and costs
    /// nothing beyond a closure call.
    public static let pi = AgentSessionTranscoder(chain: .parentPointer) { $0 }

    /// The transform for whichever agent owns a file, decided by the session root it lives
    /// under. Liveness detection reads raw file tails and only has a path to go on.
    public static func forSessionPath(_ path: String) -> AgentSessionTranscoder {
        make(for: AgentCatalog.agent(forSessionPath: path) ?? .pi)
    }

    public static func make(for kind: AgentKind) -> AgentSessionTranscoder {
        switch kind {
        case .pi: pi
        case .codex: AgentSessionTranscoder(chain: .linear, transcode: CodexSessionTranscoder.transcode)
        case .claude: AgentSessionTranscoder(chain: .linear, transcode: ClaudeSessionTranscoder.transcode)
        }
    }
}

// MARK: - Shared helpers

enum TranscodeSupport {
    /// FNV-1a over the record's own bytes. Codex rollout entries carry no usable identity for
    /// every record type, and a byte offset is not available to a backward reader and a forward
    /// reader alike. A content hash is stable, cheap, and identical from both directions; two
    /// records that hash equal are byte-identical and therefore interchangeable on screen.
    static func contentID(_ prefix: String, _ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return "\(prefix)-\(String(hash, radix: 36))"
    }

    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Bounds a string the way the downstream parsers already bound theirs, so a pathological
    /// record cannot become a pathological transcoded record.
    static func bounded(_ text: String, max: Int = 160_000) -> String {
        text.count <= max ? text : String(text.prefix(max)) + "\n… truncated"
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": bounded(text)]
    }

    static func thinkingBlock(_ text: String) -> [String: Any] {
        ["type": "thinking", "thinking": bounded(text)]
    }

    static func toolCallBlock(id: String, name: String, arguments: Any) -> [String: Any] {
        ["type": "toolCall", "id": id, "name": name, "arguments": arguments]
    }

    /// Tool arguments arrive as a JSON string from some agents and a real object from others.
    /// Both end up as an object so the inspector and capability presenter see uniform shapes.
    static func normalizedArguments(_ value: Any?) -> Any {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String {
            if let data = text.data(using: .utf8), let object = decode(data) { return object }
            return ["input": bounded(text, max: 20_000)]
        }
        return [String: Any]()
    }
}
