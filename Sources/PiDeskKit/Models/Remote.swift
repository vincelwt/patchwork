import Foundation

public enum RemoteRelayConnection: String, Codable, Hashable, Sendable {
    case connecting
    case connected
    case offline
}

public struct RemoteDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var connected: Bool

    public init(id: String, name: String, pairedAt: Date, lastSeenAt: Date? = nil, connected: Bool = false) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.connected = connected
    }
}

public struct RemotePendingPairing: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var verificationCode: String
    public var requestedAt: Date

    public init(id: String, deviceId: String, name: String, verificationCode: String, requestedAt: Date) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.verificationCode = verificationCode
        self.requestedAt = requestedAt
    }
}

public struct RemoteAccessStatus: Codable, Hashable, Sendable {
    public var relayURL: String
    public var connection: RemoteRelayConnection
    public var devices: [RemoteDevice]
    public var pendingPairings: [RemotePendingPairing]

    public init(
        relayURL: String,
        connection: RemoteRelayConnection,
        devices: [RemoteDevice] = [],
        pendingPairings: [RemotePendingPairing] = []
    ) {
        self.relayURL = relayURL
        self.connection = connection
        self.devices = devices
        self.pendingPairings = pendingPairings
    }
}

public struct RemotePairingOffer: Codable, Hashable, Sendable {
    public var url: String
    public var expiresAt: Date

    public init(url: String, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

public struct RemotePairingDecisionRequest: Codable, Hashable, Sendable {
    public var approved: Bool

    public init(approved: Bool) { self.approved = approved }
}

public struct RemoteDeletedResponse: Codable, Hashable, Sendable {
    public var deleted: Bool

    public init(deleted: Bool) { self.deleted = deleted }
}
