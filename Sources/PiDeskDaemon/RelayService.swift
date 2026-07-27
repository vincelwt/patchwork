import CryptoKit
import Foundation
import PiDeskKit

private struct StoredRelayIdentity: Codable {
    let installationID: String
    let hostToken: String
    let privateKey: String

    static func loadOrCreate(at url: URL) throws -> StoredRelayIdentity {
        if let stored = PiDeskFile.readIfPresent(StoredRelayIdentity.self, from: url),
           Data(base64URL: stored.privateKey) != nil,
           !stored.installationID.isEmpty,
           !stored.hostToken.isEmpty {
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
    let verificationCode: String
    let requestedAt: Int64
    let ecdhPublicKey: String
}

private struct RelayWireMessage: Codable, Sendable {
    var type: String
    var id: String?
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

enum RelayServiceError: Error, LocalizedError {
    case offline
    case invalidIdentity
    case invalidDeviceKey

    var errorDescription: String? {
        switch self {
        case .offline: "The hosted remote is still connecting. Try again in a moment."
        case .invalidIdentity: "The hosted remote identity is invalid."
        case .invalidDeviceKey: "The paired device supplied an invalid encryption key."
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

    private let identityFileURL: URL
    private let logger: DaemonLogger
    private let bus: EventBus
    private let websocketOrigin: String

    private var identity: StoredRelayIdentity?
    private var connection: RemoteRelayConnection = .offline
    private var devices: [String: RelayWireDevice] = [:]
    private var pendingPairings: [String: RelayWirePairing] = [:]
    private var deviceKeys: [String: SymmetricKey] = [:]
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var loopTask: Task<Void, Never>?
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
        busSubscription = bus.subscribe { [weak self] name, payload in
            Task { await self?.broadcastEvent(name: name, payload: payload) }
        }
        connection = .connecting
        loopTask = Task { [weak self] in await self?.connectionLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if let busSubscription { bus.unsubscribe(busSubscription) }
        busSubscription = nil
        connection = .offline
        deviceKeys.removeAll()
    }

    func status() -> RemoteAccessStatus {
        RemoteAccessStatus(
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
        var message = RelayWireMessage(type: "pairOffer")
        message.id = UUID().uuidString
        message.ticketHash = Data(SHA256.hash(data: Data(ticket.utf8))).base64URLEncoded
        message.expiresAt = Int64(expiresAt.timeIntervalSince1970 * 1_000)
        message.hostPublicKey = try identity.agreementKey.publicKey.x963Representation.base64URLEncoded
        try await send(message)

        let url = "\(Self.webOrigin)/pair/\(identity.installationID)#ticket=\(ticket)&host=\(message.hostPublicKey!)"
        return RemotePairingOffer(url: url, expiresAt: expiresAt)
    }

    func decidePairing(id: String, approved: Bool) async throws -> RemoteAccessStatus {
        guard connection == .connected, pendingPairings[id] != nil else { throw RelayServiceError.offline }
        var message = RelayWireMessage(type: "pairDecision")
        message.id = UUID().uuidString
        message.pairingId = id
        message.approved = approved
        try await send(message)
        pendingPairings.removeValue(forKey: id)
        return status()
    }

    func revokeDevice(id: String) async throws {
        guard connection == .connected else { throw RelayServiceError.offline }
        var message = RelayWireMessage(type: "revokeDevice")
        message.id = UUID().uuidString
        message.deviceId = id
        try await send(message)
        devices.removeValue(forKey: id)
        deviceKeys.removeValue(forKey: id)
    }

    // MARK: - Connection

    private func currentIdentity() throws -> StoredRelayIdentity {
        if let identity { return identity }
        let loaded = try StoredRelayIdentity.loadOrCreate(at: identityFileURL)
        _ = try loaded.agreementKey
        identity = loaded
        return loaded
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
            socket = nil
            session?.invalidateAndCancel()
            session = nil
            connection = .offline
            deviceKeys.removeAll()
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: retry * 1_000_000_000)
            retry = min(retry * 2, 30)
        }
    }

    private func connectAndReceive() async throws {
        let identity = try currentIdentity()
        guard let url = URL(string: "\(websocketOrigin)/relay/host/\(identity.installationID)") else {
            throw RelayServiceError.invalidIdentity
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(identity.hostToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
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
            guard data.count <= Self.maxRPCBodyBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
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

    // MARK: - Relay messages

    private func handle(_ message: RelayWireMessage) async throws {
        switch message.type {
        case "hostReady":
            connection = .connected
            updateDevices(message.devices ?? [])
            logger.info("Hosted remote connected")
        case "devicesSnapshot":
            updateDevices(message.devices ?? [])
        case "pairRequest":
            if let pairing = message.pairing { pendingPairings[pairing.id] = pairing }
        case "deviceConnected":
            if let device = message.device {
                let connected = RelayWireDevice(
                    id: device.id,
                    name: device.name,
                    ecdhPublicKey: device.ecdhPublicKey,
                    pairedAt: device.pairedAt,
                    lastSeenAt: device.lastSeenAt,
                    connected: true
                )
                devices[device.id] = connected
                if (try? deriveDeviceKey(connected)) == nil {
                    logger.error("Hosted remote rejected an invalid device encryption key")
                }
            }
        case "deviceDisconnected":
            if let id = message.deviceId {
                if let device = devices[id] {
                    devices[id] = RelayWireDevice(
                        id: device.id,
                        name: device.name,
                        ecdhPublicKey: device.ecdhPublicKey,
                        pairedAt: device.pairedAt,
                        lastSeenAt: device.lastSeenAt,
                        connected: false
                    )
                }
                deviceKeys.removeValue(forKey: id)
            }
        case "fromDevice":
            guard let deviceID = message.deviceId,
                  let payload = message.payload else { return }
            if deviceKeys[deviceID] == nil, let publicKey = message.ecdhPublicKey {
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                let device = devices[deviceID] ?? RelayWireDevice(
                    id: deviceID,
                    name: "Remote device",
                    ecdhPublicKey: publicKey,
                    pairedAt: now,
                    lastSeenAt: now,
                    connected: true
                )
                do {
                    try deriveDeviceKey(RelayWireDevice(
                        id: device.id,
                        name: device.name,
                        ecdhPublicKey: publicKey,
                        pairedAt: device.pairedAt,
                        lastSeenAt: device.lastSeenAt,
                        connected: true
                    ))
                } catch {
                    logger.error("Hosted remote rejected an invalid device encryption key")
                    return
                }
            }
            await handleRPC(
                deviceID: deviceID,
                connectionID: message.connectionId,
                payload: payload
            )
        default:
            break // additive protocol messages are intentionally ignored
        }
    }

    private func updateDevices(_ incoming: [RelayWireDevice]) {
        devices = Dictionary(uniqueKeysWithValues: incoming.prefix(32).map { ($0.id, $0) })
        deviceKeys.removeAll()
        for device in devices.values where device.connected == true {
            try? deriveDeviceKey(device)
        }
    }

    private func deriveDeviceKey(_ device: RelayWireDevice) throws {
        let identity = try currentIdentity()
        guard let raw = Data(base64URL: device.ecdhPublicKey) else { throw RelayServiceError.invalidDeviceKey }
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try identity.agreementKey.sharedSecretFromKeyAgreement(with: publicKey)
        deviceKeys[device.id] = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(identity.installationID.utf8),
            sharedInfo: Data("pi-remote-v1:\(device.id)".utf8),
            outputByteCount: 32
        )
    }

    private func handleRPC(deviceID: String, connectionID: String?, payload: RelayCipherPayload) async {
        guard let key = deviceKeys[deviceID], let router else { return }
        do {
            let plaintext = try decrypt(payload, using: key)
            let rpc = try PiDeskJSON.decoder.decode(RemoteRPCRequest.self, from: plaintext)
            let response = await route(rpc, through: router)
            let encrypted = try encrypt(PiDeskJSON.encoder.encode(response), using: key)
            var outgoing = RelayWireMessage(type: "toDevice")
            outgoing.deviceId = deviceID
            outgoing.connectionId = connectionID
            outgoing.payload = encrypted
            try await send(outgoing)
        } catch {
            logger.error("Hosted remote rejected an invalid encrypted request")
        }
    }

    private func route(_ rpc: RemoteRPCRequest, through router: DaemonRouter) async -> RemoteRPCResponse {
        guard !rpc.id.isEmpty, rpc.id.utf8.count <= 128,
              rpc.path.utf8.count <= 4_096,
              rpc.path.hasPrefix("/v1/"),
              !rpc.path.hasPrefix("/v1/remote"),
              ["GET", "POST", "PATCH", "DELETE"].contains(rpc.method.uppercased()) else {
            return rpcError(id: rpc.id, status: 400, code: "invalid_request", message: "The remote request is not allowed.")
        }
        let body = Data((rpc.body ?? "").utf8)
        guard body.count <= Self.maxRPCBodyBytes else {
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
        guard let plaintext = try? PiDeskJSON.encoder.encode(event) else { return }
        for (deviceID, key) in deviceKeys {
            guard let payload = try? encrypt(plaintext, using: key) else { continue }
            var message = RelayWireMessage(type: "toDevice")
            message.deviceId = deviceID
            message.payload = payload
            try? await send(message)
        }
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> RelayCipherPayload {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        return RelayCipherPayload(
            nonce: sealed.nonce.withUnsafeBytes { Data($0).base64URLEncoded },
            data: ciphertext.base64URLEncoded
        )
    }

    private func decrypt(_ payload: RelayCipherPayload, using key: SymmetricKey) throws -> Data {
        guard let nonceData = Data(base64URL: payload.nonce), nonceData.count == 12,
              let combined = Data(base64URL: payload.data), combined.count >= 16 else {
            throw RelayServiceError.invalidDeviceKey
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ciphertext = combined.dropLast(16)
        let tag = combined.suffix(16)
        return try AES.GCM.open(AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag), using: key)
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
