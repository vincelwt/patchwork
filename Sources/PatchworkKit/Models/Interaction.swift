import Foundation

/// Pi's `extension_ui_request` method. Tolerant, because a future Pi can introduce a dialog kind
/// this build has never seen and a remote client must still show *something* rather than
/// silently stranding a run that is blocked waiting for an answer.
public struct InteractionMethod: TolerantRawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let select = InteractionMethod(rawValue: "select")
    public static let confirm = InteractionMethod(rawValue: "confirm")
    public static let input = InteractionMethod(rawValue: "input")
    public static let editor = InteractionMethod(rawValue: "editor")

    public static var knownCases: [InteractionMethod] { [.select, .confirm, .input, .editor] }
    public static func other(_ rawValue: String) -> InteractionMethod { InteractionMethod(rawValue: rawValue) }

    /// A remote client can render an answer UI for these. Anything else must degrade to a
    /// visible "answer this on the Mac" card whose only safe action is Cancel.
    public var isAnswerable: Bool { Self.knownCases.contains(self) }
}

/// One option of a matched `ask_user_question` question. The raw string a response must carry
/// (`value`) is kept separate from the human label so a client never has to reconstruct Pi's own
/// option encoding.
public struct InteractionOption: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var value: String
    public var label: String
    public var description: String?
    public var preview: String?

    public init(id: Int, value: String, label: String, description: String? = nil, preview: String? = nil) {
        self.id = id
        self.value = value
        self.label = label
        self.description = description
        self.preview = preview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? value
        description = try container.decodeIfPresent(String.self, forKey: .description)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
    }
}

/// A dialog a daemon-owned Pi run is *currently blocked on*. It exists only while the run waits:
/// once answered, cancelled, or expired it is published one last time with `resolvedAt` set and
/// then forgotten. Nothing is ever answered automatically — an expiry sends Pi an explicit
/// cancellation so the run can unwind instead of burning its whole timeout.
public struct PendingInteraction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runId: String
    public var threadId: String?
    public var method: InteractionMethod
    public var title: String
    public var message: String?
    /// The exact strings Pi offered, in order; a `select` response must be one of these.
    public var options: [String]
    public var placeholder: String?
    public var prefill: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var resolvedAt: Date?

    // Enrichment from a matched `ask_user_question` tool call in the same run. Absent for a
    // plain approval/permission dialog, and absent whenever the match is not certain.
    public var header: String?
    public var multiSelect: Bool
    public var choices: [InteractionOption]
    public var questionIndex: Int?
    public var questionCount: Int?

    public init(
        id: String,
        runId: String,
        threadId: String? = nil,
        method: InteractionMethod,
        title: String,
        message: String? = nil,
        options: [String] = [],
        placeholder: String? = nil,
        prefill: String? = nil,
        createdAt: Date = Date(),
        expiresAt: Date,
        resolvedAt: Date? = nil,
        header: String? = nil,
        multiSelect: Bool = false,
        choices: [InteractionOption] = [],
        questionIndex: Int? = nil,
        questionCount: Int? = nil
    ) {
        self.id = id
        self.runId = runId
        self.threadId = threadId
        self.method = method
        self.title = title
        self.message = message
        self.options = options
        self.placeholder = placeholder
        self.prefill = prefill
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.resolvedAt = resolvedAt
        self.header = header
        self.multiSelect = multiSelect
        self.choices = choices
        self.questionIndex = questionIndex
        self.questionCount = questionCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        runId = try container.decodeIfPresent(String.self, forKey: .runId) ?? ""
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        method = try container.decodeIfPresent(InteractionMethod.self, forKey: .method) ?? .other("unknown")
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Pi"
        message = try container.decodeIfPresent(String.self, forKey: .message)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        prefill = try container.decodeIfPresent(String.self, forKey: .prefill)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt) ?? .distantFuture
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        choices = try container.decodeIfPresent([InteractionOption].self, forKey: .choices) ?? []
        questionIndex = try container.decodeIfPresent(Int.self, forKey: .questionIndex)
        questionCount = try container.decodeIfPresent(Int.self, forKey: .questionCount)
    }
}

public struct InteractionListResponse: Codable, Sendable {
    public var interactions: [PendingInteraction]
    public init(interactions: [PendingInteraction]) { self.interactions = interactions }
}

/// Exactly one of `value`, `confirmed`, or `cancelled` decides the answer, matching the app's own
/// `extension_ui_response` shape. An empty body is a cancellation, never a blank answer.
public struct InteractionRespondRequest: Codable, Sendable {
    public var value: String?
    public var confirmed: Bool?
    public var cancelled: Bool?

    public init(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) {
        self.value = value
        self.confirmed = confirmed
        self.cancelled = cancelled
    }
}

public struct InteractionRespondResponse: Codable, Sendable {
    public var accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}
