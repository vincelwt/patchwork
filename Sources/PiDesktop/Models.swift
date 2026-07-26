import AppKit
import Foundation

struct TokenMetrics: Hashable, Codable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0
    var contextTokens: Int?
    var contextWindow: Int?
    var contextPercent: Double?
    var latestCacheHitPercent: Double?

    var total: Int { input + output + cacheRead + cacheWrite }

    mutating func addUsage(_ usage: JSONValue?) {
        guard let usage else { return }
        input += usage["input"]?.intValue ?? 0
        output += usage["output"]?.intValue ?? 0
        cacheRead += usage["cacheRead"]?.intValue ?? 0
        cacheWrite += usage["cacheWrite"]?.intValue ?? 0
        cost += usage["cost"]?["total"]?.doubleValue ?? 0
        if let percent = TokenMetrics.cacheHitPercent(
            input: usage["input"]?.intValue ?? 0,
            cacheRead: usage["cacheRead"]?.intValue ?? 0,
            cacheWrite: usage["cacheWrite"]?.intValue ?? 0
        ) {
            latestCacheHitPercent = percent
        }
    }

    /// Cache hit share of everything the provider had to look at for the latest turn:
    /// fresh input plus cache reads plus cache writes.
    static func cacheHitPercent(input: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        let denominator = input + cacheRead + cacheWrite
        guard denominator > 0 else { return nil }
        return Double(cacheRead) / Double(denominator) * 100
    }
}

struct SessionSummary: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let fileURL: URL
    let cwd: URL
    let createdAt: Date
    let modifiedAt: Date
    var name: String
    var preview: String
    var messageCount: Int
    var model: String?
    var provider: String?
    var thinkingLevel: String?
    var metrics: TokenMetrics
    var isArchived = false
    var searchKey = ""

    var folderName: String {
        let value = cwd.lastPathComponent
        return value.isEmpty ? cwd.path : value
    }

    var displayName: String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Untitled conversation" : clean
    }

    /// Folded once during summary projection/cache hydration, not per sidebar render.
    mutating func prepareSearchKey() {
        searchKey = "\(displayName)\n\(preview)\n\(cwd.path)".lowercased().prefixString(2_000)
    }
}

struct SessionConversation: Sendable {
    let messages: [ChatMessage]
    let leafID: String?
    let rawEntryCount: Int
}

enum MessageRole: String, Hashable, Sendable {
    case user
    case assistant
    case tool = "toolResult"
    case bash = "bashExecution"
    case custom
    case system
    case unknown
}

/// Decoded bitmaps are far larger than their encoded bytes, so the cache is costed by
/// decoded pixels and purged when the active conversation changes.
final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache()
    let values = NSCache<NSString, NSImage>()

    private init() {
        values.countLimit = PiTheme.decodedImageCountLimit
        values.totalCostLimit = PiTheme.decodedImageByteLimit
    }

    /// Approximate resident bitmap size: pixels × 4 bytes, not the encoded byte count.
    static func decodedCost(of image: NSImage) -> Int {
        if let representation = image.representations.first, representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width.rounded()) * Int(image.size.height.rounded()) * 4)
    }

    static func purge() {
        shared.values.removeAllObjects()
    }
}

struct ImagePayload: Identifiable, Hashable, Sendable {
    let id: String
    let data: Data
    let mimeType: String
    let fileName: String?

    var nsImage: NSImage? {
        let key = "message-\(id)-\(data.count)" as NSString
        if let cached = DecodedImageCache.shared.values.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        DecodedImageCache.shared.values.setObject(image, forKey: key, cost: DecodedImageCache.decodedCost(of: image))
        return image
    }
}

struct ToolCallPayload: Hashable, Sendable {
    let id: String
    let name: String
    /// The sole retained projected tool payload. The containing raw message is discarded.
    let arguments: JSONValue
}

struct MessageBlock: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case text(String)
        case image(ImagePayload)
        case thinking(String)
        case toolCall(ToolCallPayload)
        case unknown(type: String, raw: JSONValue)
    }

    let id: String
    let kind: Kind
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    let role: MessageRole
    var blocks: [MessageBlock]
    let timestamp: Date?
    var toolCallID: String?
    var toolName: String?
    var isError = false
    var customType: String?
    var details: JSONValue?
    var usage: JSONValue?
    /// Known messages set this to `.null`; only bounded unknown fallbacks retain content.
    let raw: JSONValue

    var textContent: String {
        blocks.compactMap { block in
            switch block.kind {
            case let .text(text): text
            case let .thinking(text): text
            default: nil
            }
        }.joined(separator: "\n")
    }

    var images: [ImagePayload] {
        blocks.compactMap { block in
            guard case let .image(image) = block.kind else { return nil }
            return image
        }
    }
}

struct ImageAttachment: Identifiable, Hashable {
    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String

    init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

    var image: NSImage? {
        let key = "attachment-\(id.uuidString)-\(data.count)" as NSString
        if let cached = DecodedImageCache.shared.values.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        DecodedImageCache.shared.values.setObject(image, forKey: key, cost: DecodedImageCache.decodedCost(of: image))
        return image
    }

    var rpcValue: JSONValue {
        .object([
            "type": .string("image"),
            "data": .string(data.base64EncodedString()),
            "mimeType": .string(mimeType)
        ])
    }
}

struct RuntimeState: Hashable, Sendable {
    var isConnected = false
    var isStreaming = false
    var isCompacting = false
    var isRetrying = false
    var retryAttempt: Int?
    var steeringQueue: [String] = []
    var followUpQueue: [String] = []
    var steeringMode = "one-at-a-time"
    var followUpMode = "one-at-a-time"
    var modelID: String?
    var modelName: String?
    var provider: String?
    var thinkingLevel: String?
    var sessionFile: String?
    var sessionID: String?
    var sessionName: String?
    var lastError: String?

    var queuedSteering: Int { steeringQueue.count }
    var queuedFollowUp: Int { followUpQueue.count }
    var queueCount: Int { steeringQueue.count + followUpQueue.count }
    var isBusy: Bool { isStreaming || isCompacting || isRetrying }
}

struct GitFileChange: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isUntracked: Bool
    /// True for text files whose line count was deliberately not counted (very large files).
    /// Distinct from `isBinary`, which means the content is not text at all.
    var linesUnavailable = false
}

struct GitSnapshot: Hashable, Sendable {
    var isRepository = false
    var branch: String?
    var isDetached = false
    var files: [GitFileChange] = []
    var statusHint: String?
    var error: String?

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    var isDirty: Bool { !files.isEmpty }

    static let none = GitSnapshot()
}

enum ActivityKind: String, Hashable, Sendable { case subagent, process, tool }
enum ActivityStatus: String, Hashable, Sendable { case queued, running, succeeded, failed, waiting, stopped, unknown }

struct ActivityItem: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: String?
    let kind: ActivityKind
    var title: String
    var subtitle: String?
    var detail: String?
    var status: ActivityStatus
    var startedAt: Date?
    var endedAt: Date?
    var raw: JSONValue
}

enum AppRoute: Hashable { case newChat, session(String) }
enum DeliveryMode: String { case automatic, steer, followUp }

struct ExtensionDialogRequest: Identifiable, Hashable {
    enum Method: String, Hashable { case select, confirm, input, editor }
    let id: String
    let method: Method
    let title: String
    var message: String?
    var options: [String] = []
    var placeholder: String?
    var prefill: String?
    var timeoutMilliseconds: Int?
    let raw: JSONValue
}

struct ExtensionWidget: Identifiable, Hashable {
    var id: String { key }
    let key: String
    var lines: [String]
    var placement: String
}

struct ToastMessage: Identifiable, Hashable {
    enum Style: String, Hashable { case info, warning, error }
    let id = UUID()
    let text: String
    let style: Style
    let sessionPath: String?
}

struct ViewedImage: Identifiable { let id = UUID(); let image: ImagePayload }

struct PersistedAppState: Codable {
    var archivedSessionIDs: Set<String> = []
    var recentFolders: [String] = []
    /// Sidebar folders the user explicitly opened or closed. Anything absent falls back to the
    /// recency/running default, so a fresh install still opens the folders that matter.
    var expandedFolders: Set<String> = []
    var collapsedFolders: Set<String> = []
    /// Last known extension statuses (already ANSI-stripped) so the footer is populated before
    /// any runtime attaches.
    var cachedExtensionStatuses: [String: String] = [:]
    /// App-only organization. Keys are standardized session-file paths, never Pi JSONL IDs.
    var virtualFolders: [VirtualFolder] = []
    var virtualFolderAssignments: [String: String] = [:]
    /// Unread state is also keyed by session-file path so duplicate/migrated IDs cannot collide.
    var lastReadAt: [String: Date] = [:]
    var manuallyUnreadSessionPaths: Set<String> = []
    /// Per-conversation composer text, keyed by standardized session-file path plus one sentinel
    /// key for the new-chat route. Bounded and LRU-evicted by `DraftStore`; image attachments
    /// never appear here.
    var drafts: [String: String] = [:]

    init() {}

    /// Hand-written decoding with `decodeIfPresent` so adding a field never discards an
    /// existing `state.json` (and with it the user's archive flags).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archivedSessionIDs = try container.decodeIfPresent(Set<String>.self, forKey: .archivedSessionIDs) ?? []
        recentFolders = try container.decodeIfPresent([String].self, forKey: .recentFolders) ?? []
        expandedFolders = try container.decodeIfPresent(Set<String>.self, forKey: .expandedFolders) ?? []
        collapsedFolders = try container.decodeIfPresent(Set<String>.self, forKey: .collapsedFolders) ?? []
        cachedExtensionStatuses = try container.decodeIfPresent([String: String].self, forKey: .cachedExtensionStatuses) ?? [:]
        virtualFolders = try container.decodeIfPresent([VirtualFolder].self, forKey: .virtualFolders) ?? []
        virtualFolderAssignments = try container.decodeIfPresent([String: String].self, forKey: .virtualFolderAssignments) ?? [:]
        lastReadAt = try container.decodeIfPresent([String: Date].self, forKey: .lastReadAt) ?? [:]
        manuallyUnreadSessionPaths = try container.decodeIfPresent(Set<String>.self, forKey: .manuallyUnreadSessionPaths) ?? []
        drafts = try container.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
    }
}

extension Date {
    static func piDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter.piShared.date(from: value)
    }
}

extension ISO8601DateFormatter {
    static let piShared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension String {
    func prefixString(_ length: Int) -> String {
        count <= length ? self : String(prefix(length))
    }
}
