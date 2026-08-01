import SwiftUI

struct DaemonSettingsView: View {
    @EnvironmentObject private var supervisor: DaemonSupervisor
    @State private var toolState = CommandLineToolInstaller.state()
    @State private var toolError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space16) {
            Text("Control Service").font(PatchworkFont.title)

            HStack(spacing: PatchworkTheme.space8) {
                StatusDot(color: statusColor)
                Text(statusLine).font(PatchworkFont.caption).foregroundStyle(.secondary)
            }

            if let detail = statusDetail {
                Text(detail).font(PatchworkFont.caption).foregroundStyle(.tertiary)
            }

            if case .unavailable = supervisor.state {
                Button("Try Again") { Task { await supervisor.retry() } }
            }

            Divider()

            commandLineTool

            Divider()

            Text("Patchwork hosts threads, automations, CLI access, and remote access inside the app process. "
                + "They stop when the app quits. An explicitly installed `patchworkd` login item remains independent.")
                .font(PatchworkFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(PatchworkTheme.space24)
        .frame(width: 420)
    }

    /// The CLI lives inside the bundle, so it needs a link on `PATH` to be usable at all.
    @ViewBuilder
    private var commandLineTool: some View {
        VStack(alignment: .leading, spacing: PatchworkTheme.space6) {
            Text("Command Line Tool").font(PatchworkFont.bodyEmphasis)
            switch toolState {
            case let .installed(path):
                Text("`patchwork` is installed at \(path).")
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.secondary)
            case .notInstalled:
                HStack(spacing: PatchworkTheme.space8) {
                    Button("Install “patchwork”") { install() }
                    Text("Links it into ~/.local/bin, next to Pi itself.")
                        .font(PatchworkFont.caption)
                        .foregroundStyle(.tertiary)
                }
            case let .conflicting(path):
                Text("Something else already exists at \(path); leaving it alone.")
                    .font(PatchworkFont.caption)
                    .foregroundStyle(Color.patchworkOrange)
            case .unavailable:
                Text("Available from the packaged app.")
                    .font(PatchworkFont.caption)
                    .foregroundStyle(.tertiary)
            }
            if let toolError {
                Text(toolError).font(PatchworkFont.caption).foregroundStyle(Color.patchworkRed)
            }
        }
    }

    private func install() {
        do {
            _ = try CommandLineToolInstaller.install()
            toolError = nil
        } catch {
            toolError = error.localizedDescription
        }
        toolState = CommandLineToolInstaller.state()
    }

    private var statusColor: Color {
        switch supervisor.state {
        case .running, .deferringToLaunchAgent, .deferringToExternalProcess: .patchworkGreen
        case .starting: .yellow
        case .unavailable: .red
        case .idle, .stopped: .secondary
        }
    }

    private var statusLine: String {
        switch supervisor.state {
        case .idle: "Checking…"
        case .deferringToLaunchAgent: "Running as a login item"
        case .deferringToExternalProcess: "Running outside this app"
        case .starting: "Starting inside Patchwork…"
        case .running: "Running inside Patchwork"
        case .unavailable: "Unavailable"
        case .stopped: "Off"
        }
    }

    private var statusDetail: String? {
        switch supervisor.state {
        case let .unavailable(detail): detail
        case .deferringToLaunchAgent: "Managed by launchd; `patchwork daemon uninstall` returns hosting to Patchwork."
        case .deferringToExternalProcess: "Quit the standalone service before restarting Patchwork to return to app-hosted mode."
        default: nil
        }
    }
}
