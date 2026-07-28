import CryptoKit
import Foundation
import PiDeskKit

private let relayProtocolVersion = 2

private struct StoredRelayDevice: Codable {
    var name: String
    var ecdhPublicKey: String
    var pairedAt: Int64
    var highestMutationCounter: UInt64

    init(name: String, ecdhPublicKey: String, pairedAt: Int64, highestMutationCounter: UInt64 = 0) {
        self.name = name
        self.ecdhPublicKey = ecdhPublicKey
        self.pairedAt = pairedAt
        self.highestMutationCounter = highestMutationCounter
    }

    private enum CodingKeys: String, CodingKey { case name, ecdhPublicKey, pairedAt, highestMutationCounter }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        ecdhPublicKey = try container.decode(String.self, forKey: .ecdhPublicKey)
        pairedAt = try container.decode(Int64.self, forKey: .pairedAt)
        highestMutationCounter = try container.decodeIfPresent(UInt64.self, forKey: .highestMutationCounter) ?? 0
    }
}

private struct StoredRelayIdentity: Codable {
    let installationID: String
    let hostToken: String
    let privateKey: String
    var protocolVersion: Int
    var devices: [String: StoredRelayDevice]

    init(installationID: String, hostToken: String, privateKey: String, protocolVersion: Int = relayProtocolVersion, devices: [String: StoredRelayDevice] = [:]) {
        self.installationID = installationID
        self.hostToken = hostToken
        self.privateKey = privateKey
        self.protocolVersion = protocolVersion
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey { case installationID, hostToken, privateKey, protocolVersion, devices }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try container.decode(String.self, forKey: .installationID)
        hostToken = try container.decode(String.self, forKey: .hostToken)
        privateKey = try container.decode(String.self, forKey: .privateKey)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        let decoded = try container.decodeIfPresent([String: StoredRelayDevice].self, forKey: .devices) ?? [:]
        devices = Dictionary(uniqueKeysWithValues: decoded.prefix(32).map { ($0.key, $0.value) })
    }

    static func loadOrCreate(at url: URL) throws -> StoredRelayIdentity {
        if var stored = PiDeskFile.readIfPresent(StoredRelayIdentity.self, from: url),
           (try? stored.agreementKey) != nil,
           stored.installationID.utf8.count == 32,
           !stored.hostToken.isEmpty {
            if stored.protocolVersion != relayProtocolVersion {
                stored.protocolVersion = relayProtocolVersion
                stored.devices.removeAll()
                try PiDeskFile.writeAtomic(stored, to: url)
            }
            return stored
        }
        let identity = StoredRelayIdentity(
            installationID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            hostToken: DaemonToken.generate(),
            privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation.base64URLEncoded
        )
        try PiDeskFile.writeAtomic(identity, to: url)
        return identity
    }

    var agreementKey: P256.KeyAgreement.PrivateKey {
        get throws {
            guard let data = Data(base64URL: privateKey) else { throw RelayServiceError.invalidIdentity }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
    }
}

private struct RelayCipherPayload: Codable, Sendable {
    let nonce: String
    let data: String
}

private struct RelayPublicJWK: Codable, Sendable {
    let kty: String
    let crv: String
    let x: String
    let y: String
}

private struct RelayWireDevice: Codable, Sendable {
    let id: String
    let name: String
    let ecdhPublicKey: String
    let pairedAt: Int64
    let lastSeenAt: Int64?
    let connected: Bool?
}

private struct RelayWirePairing: Codable, Sendable {
    let id: String
    let deviceId: String
    let name: String
    let requestedAt: Int64
    let expiresAt: Int64
    let authPublicKey: RelayPublicJWK
    let ecdhPublicKey: String
    let proof: String
}

private struct PendingRelayPairing: Sendable {
    let id: String
    let deviceId: String
    let name: String
    let verificationCode: String
    let requestedAt: Int64
    let expiresAt: Int64
    let ecdhPublicKey: String
}

private struct ActivePairingOffer: Sendable {
    let ticket: String
    let expiresAt: Int64
}

private struct RelayWireMessage: Codable, Sendable {
    var type: String
    var id: String?
    var ok: Bool?
    var error: String?
    var ticketHash: String?
    var expiresAt: Int64?
    var hostPublicKey: String?
    var pairingId: String?
    var approved: Bool?
    var deviceId: String?
    var connectionId: String?
    var ecdhPublicKey: String?
    var payload: RelayCipherPayload?
    var devices: [RelayWireDevice]?
    var device: RelayWireDevice?
    var pairing: RelayWirePairing?

    init(type: String) { self.type = type }
}

private struct RemoteRPCRequest: Decodable {
    let id: String
    let counter: UInt64
    let method: String
    let path: String
    let body: String?
}

private struct RemoteRPCResponse: Encodable {
    let type = "response"
    let id: String
    let status: Int
    let body: String
}

private struct RemoteEventEnvelope: Encodable {
    let type = "event"
    let name: String
    let data: String
}

private struct QueuedRelayEvent: Sendable {
    let name: String
    let payload: Data
}

private struct RelayAck: Sendable {
    let ok: Bool
    let error: String?
}

enum RelayPairingProof {
    static func transcript(
        installationID: String,
        deviceID: String,
        name: String,
        ecdhPublicKey: String,
        authX: String,
        authY: String
    ) -> Data {
        Data(["pi-remote-pair-v1", installationID, deviceID, name, ecdhPublicKey, authX, authY].joined(separator: "\0").utf8)
    }

    static func authenticationCode(
        ticket: String,
        installationID: String,
        deviceID: String,
        name: String,
        ecdhPublicKey: String,
        authX: String,
        authY: String
    ) throws -> Data {
        guard let ticketData = Data(base64URL: ticket), ticketData.count == 32 else {
            throw RelayServiceError.invalidPairing
        }
        let transcript = transcript(
            installationID: installationID,
            deviceID: deviceID,
            name: name,
            ecdhPublicKey: ecdhPublicKey,
            authX: authX,
            authY: authY
        )
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: ticketData)))
    }

    static func isValid(
        _ proof: Data,
        ticket: String,
        installationID: String,
        deviceID: String,
        name: String,
        ecdhPublicKey: String,
        authX: String,
        authY: String
    ) -> Bool {
        guard let ticketData = Data(base64URL: ticket), ticketData.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript(
                installationID: installationID,
                deviceID: deviceID,
                name: name,
                ecdhPublicKey: ecdhPublicKey,
                authX: authX,
                authY: authY
            ),
            using: SymmetricKey(data: ticketData)
        )
    }

    static func verificationCode(for proof: Data) throws -> String {
        guard proof.count == 32 else { throw RelayServiceError.invalidPairing }
        let bytes = Array(proof.prefix(4))
        let value = ((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])) % 1_000_000
        return String(format: "%06d", value)
    }
}

enum RelayMutationCounter {
    static func accept(_ counter: UInt64, highest: inout UInt64) -> Bool {
        guard counter > highest else { return false }
        highest = counter
        return true
    }
}

enum RelayServiceError: Error, LocalizedError {
    case offline
    case invalidIdentity
    case invalidDeviceKey
    case invalidPairing
    case relayRejected(String)

    var errorDescription: String? {
        switch self {
        case .offline: "The hosted remote is still connecting. Try again in a moment."
        case .invalidIdentity: "The hosted remote identity is invalid."
        case .invalidDeviceKey: "The paired device supplied an invalid encryption key."
        case .invalidPairing: "The pairing request could not be verified. Scan a new code."
        case let .relayRejected(message): "The hosted remote rejected the request: \(message)"
        }
    }
}

/// One outbound, auto-reconnecting connection from the daemon to the hosted relay. API payloads
/// are encrypted device-to-daemon; Cloudflare only routes bounded ciphertext and pairing metadata.
actor RelayService {
    static let webOrigin = "https://remote.ai.gloom.sh"
    static let websocketOrigin = "wss://remote.ai.gloom.sh"
    static let pairingLifetime: TimeInterval = 5 * 60
    static let maxRPCBodyBytes = 2 * 1_024 * 1_024
    private static let maxEncryptedPlaintextBytes = 1_500_000
    private static let deviceToHost = Data("pi-remote-v1:device-to-host".utf8)
    private static let hostToDevice = Data("pi-remote-v1:host-to-device".utf8)

    private let identityFileURL: URL
    private let logger: DaemonLogger
    private let bus: EventBus
    private let websocketOrigin: String

    private var identity: StoredRelayIdentity?
    private var connection: RemoteRelayConnection = .offline
    private var devices: [String: RelayWireDevice] = [:]
    private var connectedDeviceIDs: Set<String> = []
    private var pendingPairings: [String: PendingRelayPairing] = [:]
    private var activePairingOffer: ActivePairingOffer?
    private var deviceKeys: [String: SymmetricKey] = [:]
    private var revokingDeviceIDs: Set<String> = []
    private var waitingAckIDs: Set<String> = []
    private var acknowledgements: [String: RelayAck] = [:]
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var loopTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<QueuedRelayEvent>.Continuation?
    private var busSubscription: UUID?
    private var router: DaemonRouter?

    init(
        identityFileURL: URL = PiDeskPaths.relayIdentity,
        websocketOrigin: String = RelayService.websocketOrigin,
        logger: DaemonLogger,
        bus: EventBus
    ) {
        self.identityFileURL = identityFileURL
        self.websocketOrigin = websocketOrigin
        self.logger = logger
        self.bus = bus
    }

    func start(router: DaemonRouter) {
        guard loopTask == nil else { return }
        self.router = router
        var continuation: AsyncStream<QueuedRelayEvent>.Continuation?
        let stream = AsyncStream<QueuedRelayEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        eventContinuation = continuation
        busSubscription = bus.subscribe { name, payload in
            continuation?.yield(QueuedRelayEvent(name: name, payload: payload))
        }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.broadcastEvent(name: event.name, payload: event.payload)
            }
        }
        connection = .connecting
        loopTask = Task { [weak self] in await self?.connectionLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if let busSubscription { bus.unsubscribe(busSubscription) }
        busSubscription = nil
        connection = .offline
        markAllDevicesDisconnected()
    }

    func status() -> RemoteAccessStatus {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        pendingPairings = pendingPairings.filter { $0.value.expiresAt > now }
        return RemoteAccessStatus(
            relayURL: Self.webOrigin,
            connection: connection,
            devices: devices.values
                .map {
                    RemoteDevice(
                        id: $0.id,
                        name: $0.name,
                        pairedAt: Self.date(milliseconds: $0.pairedAt),
                        lastSeenAt: $0.lastSeenAt.map(Self.date(milliseconds:)),
                        connected: $0.connected ?? false
                    )
                }
                .sorted { $0.pairedAt < $1.pairedAt },
            pendingPairings: pendingPairings.values
                .map {
                    RemotePendingPairing(
                        id: $0.id,
                        deviceId: $0.deviceId,
                        name: $0.name,
                        verificationCode: $0.verificationCode,
                        requestedAt: Self.date(milliseconds: $0.requestedAt)
                    )
                }
                .sorted { $0.requestedAt < $1.requestedAt }
        )
    }

    func createPairingOffer() async throws -> RemotePairingOffer {
        guard connection == .connected else { throw RelayServiceError.offline }
        let identity = try currentIdentity()
        let ticket = DaemonToken.generate()
        let expiresAt = Date().addingTimeInterval(Self.pairingLifetime)
        let expiresAtMilliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        var message = RelayWireMessage(type: "pairOffer")
        let offerID = UUID().uuidString
        message.id = offerID
        message.ticketHash = Data(SHA256.hash(data: Data(ticket.utf8))).base64URLEncoded
        message.expiresAt = expiresAtMilliseconds
        message.hostPublicKey = try identity.agreementKey.publicKey.x963Representation.base64URLEncoded
        try await sendAndAwaitAck(message)
        activePairingOffer = ActivePairingOffer(ticket: ticket, expiresAt: expiresAtMilliseconds)

        return RemotePairingOffer(
            url: Self.pairingURL(
                installationID: identity.installationID,
                offerID: offerID,
                ticket: ticket,
                hostPublicKey: message.hostPublicKey!
            ),
            expiresAt: expiresAt
        )
    }

    /// The query is deliberately non-secret but unique per QR. Safari treats a new fragment on
    /// the same `/pair/<installation>` URL as in-page navigation and can reuse a stale tab without
    /// running the pairing bootstrap. A changing query forces a real document load while the
    /// ticket and host key remain fragment-only and therefore never reach Cloudflare.
    static func pairingURL(installationID: String, offerID: String, ticket: String, hostPublicKey: String) -> String {
        "\(webOrigin)/pair/\(installationID)?offer=\(offerID)#ticket=\(ticket)&host=\(hostPublicKey)"
    }

    func decidePairing(id: String, approved: Bool) async throws -> RemoteAccessStatus {
        guard connection == .connected, let pairing = pendingPairings[id] else { throw RelayServiceError.offline }
        guard pairing.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000) else {
            pendingPairings.removeValue(forKey: id)
            throw RelayServiceError.invalidPairing
        }

        if approved { try authorize(pairing) }
        var message = RelayWireMessage(type: "pairDecision")
        message.id = UUID().uuidString
        message.pairingId = id
        message.approved = approved
        do {
            try await sendAndAwaitAck(message)
        } catch {
            if case RelayServiceError.relayRejected = error {
                if approved { try? deauthorize(deviceID: pairing.deviceId) }
                pendingPairings.removeValue(forKey: id)
            }
            throw error
        }
        pendingPairings.removeValue(forKey: id)
        return status()
    }

    func revokeDevice(id: String) async throws {
        guard connection == .connected else { throw RelayServiceError.offline }
        revokingDeviceIDs.insert(id)
        defer { revokingDeviceIDs.remove(id) }
        var message = RelayWireMessage(type: "revokeDevice")
        message.id = UUID().uuidString
        message.deviceId = id
        try await sendAndAwaitAck(message)
        try deauthorize(deviceID: id)
        devices.removeValue(forKey: id)
        connectedDeviceIDs.remove(id)
        deviceKeys.removeValue(forKey: id)
    }

    // MARK: - Connection

    private func currentIdentity() throws -> StoredRelayIdentity {
        if let identity { return identity }
        let loaded = try StoredRelayIdentity.loadOrCreate(at: identityFileURL)
        identity = loaded
        return loaded
    }

    private func saveIdentity(_ value: StoredRelayIdentity) throws {
        try PiDeskFile.writeAtomic(value, to: identityFileURL)
        identity = value
    }

    private func connectionLoop() async {
        var retry: UInt64 = 1
        while !Task.isCancelled {
            do {
                connection = .connecting
                try await connectAndReceive()
                retry = 1
            } catch is CancellationError {
                break
            } catch {
                logger.error("Hosted remote disconnected: \(error.localizedDescription)")
            }
            if connection == .connected { retry = 1 }
            socket = nil
            session?.invalidateAndCancel()
            session = nil
            connection = .offline
            markAllDevicesDisconnected()
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: retry * 1_000_000_000)
            retry = min(retry * 2, 30)
        }
    }

    private func connectAndReceive() async throws {
        let identity = try currentIdentity()
        guard let url = URL(string: "\(websocketOrigin)/relay/host/\(identity.installationID)?v=\(relayProtocolVersion)") else {
            throw RelayServiceError.invalidIdentity
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(identity.hostToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = Self.maxRPCBodyBytes
        self.session = session
        self.socket = socket
        socket.resume()

        while !Task.isCancelled {
            let frame = try await socket.receive()
            let data: Data
            switch frame {
            case let .data(value): data = value
            case let .string(value): data = Data(value.utf8)
            @unknown default: continue
            }
            guard data.count <= Self.maxRPCBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }
            let message = try PiDeskJSON.decoder.decode(RelayWireMessage.self, from: data)
            try await handle(message)
        }
        throw CancellationError()
    }

    private func send(_ message: RelayWireMessage) async throws {
        guard let socket else { throw RelayServiceError.offline }
        let data = try PiDeskJSON.encoder.encode(message)
        guard data.count <= Self.maxRPCBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func sendAndAwaitAck(_ message: RelayWireMessage) async throws {
        guard let id = message.id else { throw RelayServiceError.invalidIdentity }
        waitingAckIDs.insert(id)
        acknowledgements.removeValue(forKey: id)
        defer {
            waitingAckIDs.remove(id)
            acknowledgements.removeValue(forKey: id)
        }
        try await send(message)
        for _ in 0..<100 {
            if let ack = acknowledgements.removeValue(forKey: id) {
                guard ack.ok else { throw RelayServiceError.relayRejected(ack.error ?? "unknown error") }
                return
            }
            guard connection == .connected else { throw RelayServiceError.offline }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw URLError(.timedOut)
    }

    // MARK: - Relay messages

    private func handle(_ message: RelayWireMessage) async throws {
        switch message.type {
        case "hostReady":
            connection = .connected
            try updateDevices(message.devices ?? [], resetConnections: true)
            logger.info("Hosted remote connected")
        case "devicesSnapshot":
            try updateDevices(message.devices ?? [], resetConnections: false)
        case "ack":
            if let id = message.id, waitingAckIDs.contains(id) {
                acknowledgements[id] = RelayAck(ok: message.ok == true, error: message.error)
            }
        case "pairRequest":
            guard let pairing = message.pairing else { return }
            do {
                let pending = try validate(pairing)
                pendingPairings[pending.id] = pending
                activePairingOffer = nil
            } catch {
                var denial = RelayWireMessage(type: "pairDecision")
                denial.id = UUID().uuidString
                denial.pairingId = pairing.id
                denial.approved = false
                try? await send(denial)
                logger.error("Hosted remote rejected an unverifiable pairing request")
            }
        case "pairExpired":
            if let id = message.pairingId { pendingPairings.removeValue(forKey: id) }
        case "deviceConnected":
            if let device = message.device { try connectDevice(device) }
        case "deviceDisconnected":
            if let id = message.deviceId {
                connectedDeviceIDs.remove(id)
                deviceKeys.removeValue(forKey: id)
                if let device = devices[id] { devices[id] = wireDevice(device, connected: false) }
            }
        case "fromDevice":
            guard let deviceID = message.deviceId,
                  !revokingDeviceIDs.contains(deviceID),
                  let payload = message.payload,
                  let stored = try currentIdentity().devices[deviceID],
                  message.ecdhPublicKey == nil || message.ecdhPublicKey == stored.ecdhPublicKey else { return }
            if deviceKeys[deviceID] == nil { try deriveDeviceKey(deviceID: deviceID, stored: stored) }
            connectedDeviceIDs.insert(deviceID)
            if let existing = devices[deviceID] { devices[deviceID] = wireDevice(existing, connected: true) }
            await handleRPC(deviceID: deviceID, connectionID: message.connectionId, payload: payload)
        default:
            break // additive protocol messages are intentionally ignored
        }
    }

    private func validate(_ pairing: RelayWirePairing) throws -> PendingRelayPairing {
        guard let offer = activePairingOffer,
              offer.expiresAt > Int64(Date().timeIntervalSince1970 * 1_000),
              pairing.id.utf8.count <= 128,
              pairing.deviceId.utf8.count == 32,
              !pairing.name.isEmpty,
              pairing.name.utf8.count <= 256,
              pairing.authPublicKey.kty == "EC",
              pairing.authPublicKey.crv == "P-256",
              Data(base64URL: pairing.authPublicKey.x)?.count == 32,
              Data(base64URL: pairing.authPublicKey.y)?.count == 32,
              let ecdhData = Data(base64URL: pairing.ecdhPublicKey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: ecdhData)) != nil,
              let proof = Data(base64URL: pairing.proof), proof.count == 32 else {
            throw RelayServiceError.invalidPairing
        }
        let expected = try RelayPairingProof.authenticationCode(
            ticket: offer.ticket,
            installationID: try currentIdentity().installationID,
            deviceID: pairing.deviceId,
            name: pairing.name,
            ecdhPublicKey: pairing.ecdhPublicKey,
            authX: pairing.authPublicKey.x,
            authY: pairing.authPublicKey.y
        )
        guard RelayPairingProof.isValid(
            proof,
            ticket: offer.ticket,
            installationID: try currentIdentity().installationID,
            deviceID: pairing.deviceId,
            name: pairing.name,
            ecdhPublicKey: pairing.ecdhPublicKey,
            authX: pairing.authPublicKey.x,
            authY: pairing.authPublicKey.y
        ) else {
            throw RelayServiceError.invalidPairing
        }
        return PendingRelayPairing(
            id: pairing.id,
            deviceId: pairing.deviceId,
            name: pairing.name,
            verificationCode: try RelayPairingProof.verificationCode(for: expected),
            requestedAt: Int64(Date().timeIntervalSince1970 * 1_000),
            expiresAt: offer.expiresAt,
            ecdhPublicKey: pairing.ecdhPublicKey
        )
    }

    private func authorize(_ pairing: PendingRelayPairing) throws {
        var identity = try currentIdentity()
        guard identity.devices[pairing.deviceId] != nil || identity.devices.count < 32 else {
            throw RelayServiceError.relayRejected("device limit reached")
        }
        identity.devices[pairing.deviceId] = StoredRelayDevice(
            name: pairing.name,
            ecdhPublicKey: pairing.ecdhPublicKey,
            pairedAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try saveIdentity(identity)
    }

    private func deauthorize(deviceID: String) throws {
        var identity = try currentIdentity()
        identity.devices.removeValue(forKey: deviceID)
        try saveIdentity(identity)
    }

    private func updateDevices(_ incoming: [RelayWireDevice], resetConnections: Bool) throws {
        let authorized = try currentIdentity().devices
        if resetConnections {
            connectedDeviceIDs.removeAll()
            deviceKeys.removeAll()
        }
        var relayDevices: [String: RelayWireDevice] = [:]
        for device in incoming.prefix(32) { relayDevices[device.id] = device }
        var updated: [String: RelayWireDevice] = [:]
        for (deviceID, stored) in authorized.prefix(32) {
            let relayDevice = relayDevices[deviceID]
            let matchesRelay = relayDevice?.ecdhPublicKey == stored.ecdhPublicKey
            let connected = matchesRelay && connectedDeviceIDs.contains(deviceID)
            updated[deviceID] = RelayWireDevice(
                id: deviceID,
                name: stored.name,
                ecdhPublicKey: stored.ecdhPublicKey,
                pairedAt: stored.pairedAt,
                lastSeenAt: matchesRelay ? relayDevice?.lastSeenAt : nil,
                connected: connected
            )
            if connected { try? deriveDeviceKey(deviceID: deviceID, stored: stored) }
        }
        devices = updated
    }

    private func connectDevice(_ device: RelayWireDevice) throws {
        guard let stored = try currentIdentity().devices[device.id], stored.ecdhPublicKey == device.ecdhPublicKey else { return }
        connectedDeviceIDs.insert(device.id)
        devices[device.id] = RelayWireDevice(
            id: device.id,
            name: stored.name,
            ecdhPublicKey: stored.ecdhPublicKey,
            pairedAt: stored.pairedAt,
            lastSeenAt: device.lastSeenAt,
            connected: true
        )
        try deriveDeviceKey(deviceID: device.id, stored: stored)
    }

    private func wireDevice(_ device: RelayWireDevice, connected: Bool) -> RelayWireDevice {
        RelayWireDevice(
            id: device.id,
            name: device.name,
            ecdhPublicKey: device.ecdhPublicKey,
            pairedAt: device.pairedAt,
            lastSeenAt: device.lastSeenAt,
            connected: connected
        )
    }

    private func markAllDevicesDisconnected() {
        connectedDeviceIDs.removeAll()
        deviceKeys.removeAll()
        devices = devices.mapValues { wireDevice($0, connected: false) }
    }

    private func deriveDeviceKey(deviceID: String, stored: StoredRelayDevice) throws {
        let identity = try currentIdentity()
        guard let raw = Data(base64URL: stored.ecdhPublicKey) else { throw RelayServiceError.invalidDeviceKey }
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try identity.agreementKey.sharedSecretFromKeyAgreement(with: publicKey)
        deviceKeys[deviceID] = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(identity.installationID.utf8),
            sharedInfo: Data("pi-remote-v1:\(deviceID)".utf8),
            outputByteCount: 32
        )
    }

    private func handleRPC(deviceID: String, connectionID: String?, payload: RelayCipherPayload) async {
        guard let key = deviceKeys[deviceID], let router else { return }
        do {
            let plaintext = try decrypt(payload, using: key, authenticating: Self.deviceToHost)
            let rpc = try PiDeskJSON.decoder.decode(RemoteRPCRequest.self, from: plaintext)
            let response: RemoteRPCResponse
            if isAllowed(rpc), rpc.method.uppercased() != "GET", try !markMutation(counter: rpc.counter, deviceID: deviceID) {
                response = rpcError(id: rpc.id, status: 409, code: "replayed_request", message: "This remote mutation was already processed.")
            } else {
                response = await route(rpc, through: router)
            }
            var responseData = try PiDeskJSON.encoder.encode(response)
            if responseData.count > Self.maxEncryptedPlaintextBytes {
                responseData = try PiDeskJSON.encoder.encode(
                    rpcError(id: rpc.id, status: 413, code: "payload_too_large", message: "The remote response is too large.")
                )
            }
            let encrypted = try encrypt(responseData, using: key, authenticating: Self.hostToDevice)
            var outgoing = RelayWireMessage(type: "toDevice")
            outgoing.deviceId = deviceID
            outgoing.connectionId = connectionID
            outgoing.payload = encrypted
            try await send(outgoing)
        } catch {
            logger.error("Hosted remote rejected an invalid encrypted request")
        }
    }

    private func markMutation(counter: UInt64, deviceID: String) throws -> Bool {
        var identity = try currentIdentity()
        guard var device = identity.devices[deviceID] else { throw RelayServiceError.invalidDeviceKey }
        guard RelayMutationCounter.accept(counter, highest: &device.highestMutationCounter) else { return false }
        identity.devices[deviceID] = device
        try saveIdentity(identity)
        return true
    }

    private func isAllowed(_ rpc: RemoteRPCRequest) -> Bool {
        !rpc.id.isEmpty && rpc.id.utf8.count <= 128 && rpc.counter > 0 &&
            rpc.path.utf8.count <= 4_096 &&
            rpc.path.hasPrefix("/v1/") &&
            !rpc.path.hasPrefix("/v1/remote") &&
            ["GET", "POST", "PATCH", "DELETE"].contains(rpc.method.uppercased())
    }

    private func route(_ rpc: RemoteRPCRequest, through router: DaemonRouter) async -> RemoteRPCResponse {
        guard isAllowed(rpc) else {
            return rpcError(id: rpc.id, status: 400, code: "invalid_request", message: "The remote request is not allowed.")
        }
        let body = Data((rpc.body ?? "").utf8)
        guard body.count <= Self.maxEncryptedPlaintextBytes else {
            return rpcError(id: rpc.id, status: 413, code: "payload_too_large", message: "The remote request body is too large.")
        }
        let (path, query) = HTTPServer.splitTarget(rpc.path)
        let request = HTTPRequest(
            method: rpc.method.uppercased(),
            path: path,
            query: query,
            headers: body.isEmpty ? [:] : ["content-type": "application/json"],
            body: body,
            origin: .relay
        )
        let response = await router.handle(request)
        return RemoteRPCResponse(
            id: rpc.id,
            status: response.status,
            body: String(decoding: response.body, as: UTF8.self)
        )
    }

    private func rpcError(id: String, status: Int, code: String, message: String) -> RemoteRPCResponse {
        let body = HTTPResponse.error(status, code: code, message: message).body
        return RemoteRPCResponse(id: id, status: status, body: String(decoding: body, as: UTF8.self))
    }

    private func broadcastEvent(name: String, payload: Data) async {
        guard connection == .connected, !deviceKeys.isEmpty else { return }
        let event = RemoteEventEnvelope(name: name, data: String(decoding: payload, as: UTF8.self))
        guard let plaintext = try? PiDeskJSON.encoder.encode(event), plaintext.count <= Self.maxEncryptedPlaintextBytes else { return }
        for deviceID in connectedDeviceIDs {
            guard let key = deviceKeys[deviceID],
                  let payload = try? encrypt(plaintext, using: key, authenticating: Self.hostToDevice) else { continue }
            var message = RelayWireMessage(type: "toDevice")
            message.deviceId = deviceID
            message.payload = payload
            try? await send(message)
        }
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private func encrypt(_ plaintext: Data, using key: SymmetricKey, authenticating data: Data) throws -> RelayCipherPayload {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: data)
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        return RelayCipherPayload(
            nonce: sealed.nonce.withUnsafeBytes { Data($0).base64URLEncoded },
            data: ciphertext.base64URLEncoded
        )
    }

    private func decrypt(_ payload: RelayCipherPayload, using key: SymmetricKey, authenticating data: Data) throws -> Data {
        guard let nonceData = Data(base64URL: payload.nonce), nonceData.count == 12,
              let combined = Data(base64URL: payload.data), combined.count >= 16 else {
            throw RelayServiceError.invalidDeviceKey
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ciphertext = combined.dropLast(16)
        let tag = combined.suffix(16)
        return try AES.GCM.open(
            AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
            using: key,
            authenticating: data
        )
    }
}

private extension Data {
    init?(base64URL value: String) {
        var raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        self.init(base64Encoded: raw)
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
