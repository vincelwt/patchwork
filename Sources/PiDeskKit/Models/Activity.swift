import Foundation

/// `daemon|app|terminal` — who is driving a running thread right now.
public struct ActivitySource: TolerantRawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let daemon = ActivitySource(rawValue: "daemon")
    public static let app = ActivitySource(rawValue: "app")
    public static let terminal = ActivitySource(rawValue: "terminal")

    public static var knownCases: [ActivitySource] { [.daemon, .app, .terminal] }
    public static func other(_ rawValue: String) -> ActivitySource { ActivitySource(rawValue: rawValue) }
}

public struct RunningThread: Codable, Hashable, Sendable {
    public var threadId: String
    public var since: Date
    public var source: ActivitySource

    public init(threadId: String, since: Date, source: ActivitySource) {
        self.threadId = threadId
        self.since = since
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try container.decode(String.self, forKey: .threadId)
        since = try container.decodeIfPresent(Date.self, forKey: .since) ?? .distantPast
        source = try container.decodeIfPresent(ActivitySource.self, forKey: .source) ?? .other("unknown")
    }
}

/// `GET /v1/activity`. Backed by the same heartbeat files the app reads, so every client agrees.
public struct ActivitySnapshot: Codable, Sendable {
    public var running: [RunningThread]
    public var unreadCount: Int
    public var observedAt: Date

    public init(running: [RunningThread], unreadCount: Int, observedAt: Date) {
        self.running = running
        self.unreadCount = unreadCount
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = try container.decodeIfPresent([RunningThread].self, forKey: .running) ?? []
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt) ?? Date()
    }
}
