import Foundation

/// A Pi session, as exposed by the control API. Named `PiThread` rather than the doc's bare
/// "Thread" because `Foundation.Thread` is in scope everywhere this package is imported; an
/// unqualified `Thread` in a client file would be ambiguous at best and silently wrong at worst.
///
/// `id` is the session's stable id; `path` is its JSONL path. Every endpoint that takes `{id}`
/// accepts either, so a caller can use whichever one it already has.
public struct PiThread: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var cwd: String
    public var folder: String
    public var createdAt: Date
    public var updatedAt: Date
    public var running: Bool
    public var unread: Bool
    public var archived: Bool
    public var preview: String
    public var cost: Double?
    public var contextPercent: Double?

    public init(
        id: String,
        path: String,
        name: String,
        cwd: String,
        folder: String,
        createdAt: Date,
        updatedAt: Date,
        running: Bool = false,
        unread: Bool = false,
        archived: Bool = false,
        preview: String = "",
        cost: Double? = nil,
        contextPercent: Double? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.cwd = cwd
        self.folder = folder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.running = running
        self.unread = unread
        self.archived = archived
        self.preview = preview
        self.cost = cost
        self.contextPercent = contextPercent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled conversation"
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        contextPercent = try container.decodeIfPresent(Double.self, forKey: .contextPercent)
    }
}

/// `user|assistant|toolResult|system`, tolerant of a role a future Pi version introduces.
public struct MessageRole: TolerantRawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let user = MessageRole(rawValue: "user")
    public static let assistant = MessageRole(rawValue: "assistant")
    public static let toolResult = MessageRole(rawValue: "toolResult")
    public static let system = MessageRole(rawValue: "system")

    public static var knownCases: [MessageRole] { [.user, .assistant, .toolResult, .system] }
    public static func other(_ rawValue: String) -> MessageRole { MessageRole(rawValue: rawValue) }
}

/// `{ "id":"…", "role":"user|assistant|toolResult|system", "text":"…", "at":"…", "isError":false }`
public struct Message: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var role: MessageRole
    public var text: String
    public var at: Date
    public var isError: Bool

    public init(id: String, role: MessageRole, text: String, at: Date, isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.isError = isError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(MessageRole.self, forKey: .role) ?? .other("unknown")
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try container.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

/// `auto|steer|followUp`. A request-side field: a bad value here is the caller's mistake, so the
/// server rejects it outright rather than guessing — see `PiDeskKit`'s HTTP layer.
public enum DeliveryMode: String, Codable, Hashable, Sendable {
    case auto
    case steer
    case followUp
}

/// One inline image on an outgoing message, mirroring the shape Pi's own RPC `images` payload
/// expects. Unrecognised `type`s are dropped by the sender rather than rejected, so an older
/// client attaching something new degrades instead of failing the whole send.
public struct MessageAttachment: Codable, Hashable, Sendable {
    public var type: String
    public var data: String
    public var mimeType: String
    public var fileName: String?

    public init(type: String = "image", data: String, mimeType: String, fileName: String? = nil) {
        self.type = type
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }
}

// MARK: - Request/response wrappers

public struct ThreadListResponse: Codable, Sendable {
    public var threads: [PiThread]
    public var nextCursor: String?
    public init(threads: [PiThread], nextCursor: String? = nil) {
        self.threads = threads
        self.nextCursor = nextCursor
    }
}

public struct ThreadDetailResponse: Codable, Sendable {
    public var thread: PiThread
    public var messages: [Message]
    public init(thread: PiThread, messages: [Message]) {
        self.thread = thread
        self.messages = messages
    }
}

public struct CreateThreadRequest: Codable, Sendable {
    public var cwd: String
    public var name: String?
    public var message: String?
    public var mode: String?
    public init(cwd: String, name: String? = nil, message: String? = nil, mode: String? = nil) {
        self.cwd = cwd
        self.name = name
        self.message = message
        self.mode = mode
    }
}

public struct CreateThreadResponse: Codable, Sendable {
    public var thread: PiThread
    public var runId: String?
    public init(thread: PiThread, runId: String? = nil) {
        self.thread = thread
        self.runId = runId
    }
}

public struct SendMessageRequest: Codable, Sendable {
    public var text: String
    public var delivery: DeliveryMode?
    public var attachments: [MessageAttachment]?
    public init(text: String, delivery: DeliveryMode? = nil, attachments: [MessageAttachment]? = nil) {
        self.text = text
        self.delivery = delivery
        self.attachments = attachments
    }
}

public struct SendMessageResponse: Codable, Sendable {
    public var runId: String?
    public var queued: Bool
    public init(runId: String?, queued: Bool) {
        self.runId = runId
        self.queued = queued
    }
}

public struct AbortResponse: Codable, Sendable {
    public var aborted: Bool
    public init(aborted: Bool) { self.aborted = aborted }
}

public struct ArchiveRequest: Codable, Sendable {
    public var archived: Bool
    public init(archived: Bool) { self.archived = archived }
}

public struct NameRequest: Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct ReadRequest: Codable, Sendable {
    public var unread: Bool
    public init(unread: Bool) { self.unread = unread }
}

public struct ThreadResponse: Codable, Sendable {
    public var thread: PiThread
    public init(thread: PiThread) { self.thread = thread }
}

/// `POST /v1/threads/{id}/lease` — the app announcing it owns a thread's runtime so the daemon
/// never races it with a scheduled run. The contract prose does not pin an exact body/response
/// shape, so this package defines the minimal one: a named owner and an optional TTL after which
/// the lease lapses on its own even if the holder never releases it (e.g. the app crashes).
public struct LeaseRequest: Codable, Sendable {
    public var owner: String
    public var ttlSeconds: Int?
    public var release: Bool?
    public init(owner: String, ttlSeconds: Int? = nil, release: Bool? = nil) {
        self.owner = owner
        self.ttlSeconds = ttlSeconds
        self.release = release
    }
}

public struct LeaseResponse: Codable, Sendable {
    public var leased: Bool
    public var owner: String?
    public var expiresAt: Date?
    public init(leased: Bool, owner: String? = nil, expiresAt: Date? = nil) {
        self.leased = leased
        self.owner = owner
        self.expiresAt = expiresAt
    }
}
