import AppKit
import Foundation
import ImageIO

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

    /// Full-resolution decode for the image viewer. Transcript rows must use
    /// `ImageThumbnailer` instead: decoding a 5K screenshot to draw a 460 pt row is what made
    /// scrolling image-heavy conversations drop frames.
    var nsImage: NSImage? {
        let key = "message-\(id)-\(data.count)" as NSString
        if let cached = DecodedImageCache.shared.values.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        DecodedImageCache.shared.values.setObject(image, forKey: key, cost: DecodedImageCache.decodedCost(of: image))
        return image
    }
}

/// Downsampled transcript bitmaps. `CGImageSource` reads the header without decoding, and its
/// thumbnailing decodes straight to the bounded pixel size — never the full bitmap.
enum ImageThumbnailer {
    /// Retina-density pixel budget for the largest transcript display bound.
    static var transcriptMaxPixel: CGFloat {
        2 * max(PiTheme.transcriptImageMaxWidth, PiTheme.transcriptImageMaxHeight)
    }

    /// The size the image lays out at in points (from header DPI metadata, matching how
    /// `NSImage` reports it), plus its pixel dimensions. No decode happens here, so a
    /// transcript row can reserve its exact final frame before the thumbnail exists.
    static func layoutPointSize(of payload: ImagePayload) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let dpiWidth = properties[kCGImagePropertyDPIWidth] as? CGFloat
        let dpiHeight = properties[kCGImagePropertyDPIHeight] as? CGFloat
        let scaleX = (dpiWidth ?? 0) > 0 ? 72 / dpiWidth! : 1
        let scaleY = (dpiHeight ?? 0) > 0 ? 72 / dpiHeight! : 1
        return CGSize(width: pixelWidth * scaleX, height: pixelHeight * scaleY)
    }

    static func cachedThumbnail(for payload: ImagePayload) -> NSImage? {
        DecodedImageCache.shared.values.object(forKey: cacheKey(payload))
    }

    /// Bounded decode, safe to call off the main thread; repeat calls are cache hits. Falls back
    /// to the full decode only when thumbnailing fails outright, so exotic-but-valid images
    /// still render.
    static func thumbnail(for payload: ImagePayload) -> NSImage? {
        let key = cacheKey(payload)
        if let cached = DecodedImageCache.shared.values.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: transcriptMaxPixel
        ]
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return payload.nsImage
        }
        // Keeping the original's point size preserves the exact layout the full decode had:
        // AppKit scales the smaller bitmap into the same frame.
        let pointSize = layoutPointSize(of: payload) ?? CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: pointSize)
        // Cost from the real backing bitmap: the snapshot rep NSImage wraps a CGImage in reports
        // point size × screen scale as its pixel dimensions, which would overcharge the cache
        // several times over and thrash it.
        let cost = max(1, cgImage.width * cgImage.height * 4)
        DecodedImageCache.shared.values.setObject(image, forKey: key, cost: cost)
        return image
    }

    private static func cacheKey(_ payload: ImagePayload) -> NSString {
        "thumb-\(payload.id)-\(payload.data.count)" as NSString
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
    var modelName: String?
    var stopReason: String?
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
    static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pi Desktop Images", isDirectory: true)

    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String
    let fileURL: URL

    init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String, fileURL: URL) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.fileURL = fileURL.standardizedFileURL
    }

    var image: NSImage? {
        let key = "attachment-\(id.uuidString)-\(data.count)" as NSString
        if let cached = DecodedImageCache.shared.values.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        DecodedImageCache.shared.values.setObject(image, forKey: key, cost: DecodedImageCache.decodedCost(of: image))
        return image
    }

    static let promptFooterHeader = "Attached image file paths:"

    var rpcValue: JSONValue {
        .object([
            "type": .string("image"),
            "data": .string(data.base64EncodedString()),
            "mimeType": .string(mimeType)
        ])
    }

    static func prompt(text: String, attachments: [ImageAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        for attachment in attachments
            where attachment.fileURL.deletingLastPathComponent().path == temporaryDirectory.path
                && !FileManager.default.fileExists(atPath: attachment.fileURL.path) {
            try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try? attachment.data.write(to: attachment.fileURL, options: .atomic)
        }
        let paths = attachments.map { "- \($0.fileURL.path)" }.joined(separator: "\n")
        return [text, "\(promptFooterHeader)\n\(paths)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func visibleText(from prompt: String) -> String {
        let footer = "\n\n\(promptFooterHeader)\n"
        if let range = prompt.range(of: footer, options: .backwards) {
            return String(prompt[..<range.lowerBound])
        }
        return prompt.hasPrefix("\(promptFooterHeader)\n") ? "" : prompt
    }
}

enum RuntimePhase: Hashable, Sendable {
    case idle
    case startingPi
    case openingConversation
    case waitingForModel
    case working

    var label: String? {
        switch self {
        case .idle: nil
        case .startingPi: "Starting Pi…"
        case .openingConversation: "Opening conversation…"
        case .waitingForModel: "Waiting for model…"
        case .working: "Working"
        }
    }
}

struct RuntimeState: Hashable, Sendable {
    var phase: RuntimePhase = .idle
    var isConnected = false
    var isStreaming = false
    var isCompacting = false
    var isRetrying = false
    var isWaitingForNetwork = false
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
    var isBusy: Bool { isStreaming || isCompacting || isRetrying || isWaitingForNetwork }
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
    var agentID: String?
    var agentType: String?
    var modelName: String?
    var toolCallCount: Int?
    var duration: TimeInterval?
}

/// Saved conversations are routed by standardized JSONL path; Pi IDs are not globally unique.
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

/// The image opened in the viewer plus the sibling images of the same message, so Left/Right can
/// step through that one group. Never empty: a group that does not contain the clicked image
/// falls back to that image alone.
struct ViewedImage: Identifiable {
    let id = UUID()
    let images: [ImagePayload]
    private(set) var index: Int

    init(image: ImagePayload, group: [ImagePayload]) {
        if let start = group.firstIndex(where: { $0.id == image.id }) {
            images = group
            index = start
        } else {
            images = [image]
            index = 0
        }
    }

    var image: ImagePayload { images[index] }
    // ponytail: clamped, not wrapping — the first/last image is the end of the group.
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < images.count }
    mutating func goToPrevious() { if hasPrevious { index -= 1 } }
    mutating func goToNext() { if hasNext { index += 1 } }
}

struct ManagedTurnRecovery: Codable, Equatable {
    static let dispatching = "dispatching"
    static let accepted = "accepted"
    static let recovering = "recovering"
    static let needsReview = "needsReview"

    var id: UUID
    var sessionPath: String
    var phase: String
    var baselineCompletionID: String?
    var activeToolCallIDs: Set<String>
    /// Recovery is automatic only when this app observed the activity extension for the session.
    /// Without that ownership signal, a plain terminal process may be invisible and wins safety.
    var heartbeatObserved: Bool? = nil
    var startedAt: Date
}

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
    /// Completion/read state is keyed by session-file path so duplicate/migrated session IDs
    /// cannot collide. `lastReadAt` is decode-only migration input from pre-completion-ID builds.
    var latestCompletedEntryIDBySessionPath: [String: String] = [:]
    var lastSeenCompletedEntryIDBySessionPath: [String: String] = [:]
    var lastReadAt: [String: Date] = [:]
    var manuallyUnreadSessionPaths: Set<String> = []
    /// Per-conversation composer text, keyed by standardized session-file path plus one sentinel
    /// key for the new-chat route. Bounded and LRU-evicted by `DraftStore`; image attachments
    /// never appear here.
    var drafts: [String: String] = [:]
    /// App-owned turns that had not settled when the process last wrote state. External terminal
    /// sessions never appear here, so relaunch recovery cannot take over work it does not own.
    var managedTurnRecoveries: [String: ManagedTurnRecovery] = [:]

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
        latestCompletedEntryIDBySessionPath = try container.decodeIfPresent(
            [String: String].self, forKey: .latestCompletedEntryIDBySessionPath
        ) ?? [:]
        lastSeenCompletedEntryIDBySessionPath = try container.decodeIfPresent(
            [String: String].self, forKey: .lastSeenCompletedEntryIDBySessionPath
        ) ?? [:]
        lastReadAt = try container.decodeIfPresent([String: Date].self, forKey: .lastReadAt) ?? [:]
        manuallyUnreadSessionPaths = try container.decodeIfPresent(Set<String>.self, forKey: .manuallyUnreadSessionPaths) ?? []
        drafts = try container.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
        let recoveries = try container.decodeIfPresent(
            [String: ManagedTurnRecovery].self, forKey: .managedTurnRecoveries
        ) ?? [:]
        managedTurnRecoveries = Dictionary(uniqueKeysWithValues: recoveries.values
            .sorted { $0.startedAt < $1.startedAt }
            .suffix(Self.maxManagedTurnRecoveries)
            .map { ($0.sessionPath, $0) })
    }

    static let maxRetainedCompletionSessions = 2_000
    static let maxManagedTurnRecoveries = 32

    /// Keeps completion metadata bounded even for hand-edited state, and optionally drops paths
    /// no longer discovered. `preferredPath` is the just-observed session and is never evicted.
    mutating func setManagedTurnRecovery(_ recovery: ManagedTurnRecovery) {
        managedTurnRecoveries[recovery.sessionPath] = recovery
        if managedTurnRecoveries.count > Self.maxManagedTurnRecoveries {
            let stale = managedTurnRecoveries.values.min { $0.startedAt < $1.startedAt }
            if let stale { managedTurnRecoveries.removeValue(forKey: stale.sessionPath) }
        }
    }

    mutating func removeManagedTurnRecovery(path: String) {
        managedTurnRecoveries.removeValue(forKey: path)
    }

    mutating func pruneCompletionState(retaining paths: Set<String>? = nil, preferredPath: String? = nil) {
        if let paths {
            latestCompletedEntryIDBySessionPath = latestCompletedEntryIDBySessionPath.filter { paths.contains($0.key) }
            lastSeenCompletedEntryIDBySessionPath = lastSeenCompletedEntryIDBySessionPath.filter { paths.contains($0.key) }
            lastReadAt = lastReadAt.filter { paths.contains($0.key) }
            manuallyUnreadSessionPaths.formIntersection(paths)
            managedTurnRecoveries = managedTurnRecoveries.filter { paths.contains($0.key) }
        }
        var keys = Set(latestCompletedEntryIDBySessionPath.keys)
            .union(lastSeenCompletedEntryIDBySessionPath.keys)
            .union(lastReadAt.keys)
            .union(manuallyUnreadSessionPaths)
        guard keys.count > Self.maxRetainedCompletionSessions else { return }
        if let preferredPath { keys.remove(preferredPath) }
        var retained = Set(keys.sorted().prefix(Self.maxRetainedCompletionSessions - (preferredPath == nil ? 0 : 1)))
        if let preferredPath { retained.insert(preferredPath) }
        latestCompletedEntryIDBySessionPath = latestCompletedEntryIDBySessionPath.filter { retained.contains($0.key) }
        lastSeenCompletedEntryIDBySessionPath = lastSeenCompletedEntryIDBySessionPath.filter { retained.contains($0.key) }
        lastReadAt = lastReadAt.filter { retained.contains($0.key) }
        manuallyUnreadSessionPaths.formIntersection(retained)
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
