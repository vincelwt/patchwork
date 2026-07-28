import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PiDeskKit
import SwiftUI

@MainActor
final class RemoteAccessViewModel: ObservableObject {
    @Published private(set) var status = RemoteAccessStatus(
        relayURL: "https://remote.ai.gloom.sh",
        connection: .connecting
    )
    @Published private(set) var offer: RemotePairingOffer?
    @Published private(set) var isWorking = false
    @Published var error: String?

    private let client: PiDeskClient
    private var pollTask: Task<Void, Never>?

    init(client: PiDeskClient = .unixSocket()) { self.client = client }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await refresh(createOffer: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await refresh(createOffer: offer == nil || offer?.expiresAt ?? .distantPast <= Date())
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func newCode() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            offer = try await client.createRemotePairing()
            error = nil
        } catch {
            self.error = surfaced(error)
        }
    }

    func decide(_ pairing: RemotePendingPairing, approved: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await client.decideRemotePairing(id: pairing.id, approved: approved)
            error = nil
        } catch {
            self.error = surfaced(error)
        }
    }

    func revoke(_ device: RemoteDevice) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await client.revokeRemoteDevice(id: device.id)
            await refresh(createOffer: false)
        } catch {
            self.error = surfaced(error)
        }
    }

    private func refresh(createOffer: Bool) async {
        do {
            status = try await client.remoteAccessStatus()
            error = nil
            if createOffer, status.connection == .connected { await newCode() }
        } catch {
            self.error = surfaced(error)
            status.connection = .offline
        }
    }

    private func surfaced(_ error: Error) -> String {
        if case PiDeskClientError.daemonUnreachable = error {
            return "The background service is not running yet."
        }
        return error.localizedDescription
    }
}

struct RemoteAccessView: View {
    @StateObject private var model = RemoteAccessViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PiTheme.space8) {
                Text("Remote Access").font(PiFont.title)
                StatusDot(color: statusColor)
                Text(statusText).font(PiFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(PiTheme.space20)

            PiHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: PiTheme.space20) {
                    pairingSection
                    if let pairing = model.status.pendingPairings.first {
                        approvalSection(pairing)
                    }
                    devicesSection
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(PiFont.caption)
                            .foregroundStyle(Color.piRed)
                            .accessibilityLabel("Remote access error: \(error)")
                    }
                }
                .padding(PiTheme.space20)
            }
        }
        .frame(width: PiTheme.remoteAccessWidth, height: PiTheme.remoteAccessHeight)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var pairingSection: some View {
        HStack(alignment: .top, spacing: PiTheme.space20) {
            Group {
                if let offer = model.offer, offer.expiresAt > Date(), let image = QRCode.image(for: offer.url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: PiTheme.remoteQRCodeSize, height: PiTheme.remoteQRCodeSize)
                        .accessibilityLabel("Pairing QR code")
                        .accessibilityHint("Scan with your phone to pair this Pi Desktop")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: PiTheme.remoteQRCodeSize, height: PiTheme.remoteQRCodeSize)
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: PiTheme.radiusMedium))

            VStack(alignment: .leading, spacing: PiTheme.space12) {
                Text("Scan with your phone").font(PiFont.sectionTitle)
                Text("Open the camera, scan this code, then approve the device here. Pairing is needed only once.")
                    .font(PiFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.status.relayURL.replacingOccurrences(of: "https://", with: ""))
                    .font(PiFont.code)
                    .foregroundStyle(.tertiary)

                HStack(spacing: PiTheme.space8) {
                    Button("Copy Link") { copyPairingLink() }
                        .disabled(model.offer == nil)
                    Button("New Code") { Task { await model.newCode() } }
                        .disabled(model.isWorking || model.status.connection != .connected)
                }
            }
        }
    }

    private func approvalSection(_ pairing: RemotePendingPairing) -> some View {
        VStack(alignment: .leading, spacing: PiTheme.space12) {
            HStack {
                Label("Pair \(pairing.name)?", systemImage: "iphone")
                    .font(PiFont.sectionTitle)
                Spacer()
                Text(pairing.verificationCode)
                    .font(PiFont.code)
                    .textSelection(.enabled)
                    .accessibilityLabel("Verification code \(pairing.verificationCode)")
            }
            Text("Confirm that this code matches the one on your phone.")
                .font(PiFont.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Deny", role: .destructive) {
                    Task { await model.decide(pairing, approved: false) }
                }
                Button("Allow") {
                    Task { await model.decide(pairing, approved: true) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PiTheme.space16)
        .background(Color.piInset)
        .clipShape(RoundedRectangle(cornerRadius: PiTheme.panelRadius))
    }

    @ViewBuilder
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: PiTheme.space8) {
            Text("Paired Devices").font(PiFont.sectionTitle)
            if model.status.devices.isEmpty {
                Text("No devices paired yet.")
                    .font(PiFont.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.status.devices) { device in
                    HStack(spacing: PiTheme.space8) {
                        StatusDot(color: device.connected ? .piGreen : .secondary)
                        VStack(alignment: .leading, spacing: PiTheme.space2) {
                            Text(device.name).font(PiFont.row)
                            Text(device.connected ? "Connected" : "Last seen \(device.lastSeenAt?.relativeShort ?? "earlier")")
                                .font(PiFont.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) {
                            Task { await model.revoke(device) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isWorking)
                        .accessibilityLabel("Revoke \(device.name)")
                    }
                    .frame(minHeight: PiTheme.rowHeight)
                    if device.id != model.status.devices.last?.id { PiHairline() }
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.status.connection {
        case .connected: .piGreen
        case .connecting: .yellow
        case .offline: .piRed
        }
    }

    private var statusText: String {
        switch model.status.connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .offline: "Offline"
        }
    }

    private func copyPairingLink() {
        guard let url = model.offer?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
