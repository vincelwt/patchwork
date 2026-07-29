import SwiftUI

struct DaemonSettingsView: View {
    @EnvironmentObject private var supervisor: DaemonSupervisor
    @State private var toolState = CommandLineToolInstaller.state()
    @State private var toolError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space16) {
            Text("Control Service").font(PiFont.title)

            HStack(spacing: PiTheme.space8) {
                StatusDot(color: statusColor)
                Text(statusLine).font(PiFont.caption).foregroundStyle(.secondary)
            }

            if let detail = statusDetail {
                Text(detail).font(PiFont.caption).foregroundStyle(.tertiary)
            }

            if case .unavailable = supervisor.state {
                Button("Try Again") { Task { await supervisor.retry() } }
            }

            Divider()

            commandLineTool

            Divider()

            Text("Pi Desktop hosts threads, automations, CLI access, and remote access inside the app process. "
                + "They stop when the app quits. An explicitly installed `pi-deskd` login item remains independent.")
                .font(PiFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(PiTheme.space24)
        .frame(width: 420)
    }

    /// The CLI lives inside the bundle, so it needs a link on `PATH` to be usable at all.
    @ViewBuilder
    private var commandLineTool: some View {
        VStack(alignment: .leading, spacing: PiTheme.space6) {
            Text("Command Line Tool").font(PiFont.bodyEmphasis)
            switch toolState {
            case let .installed(path):
                Text("`pidesk` is installed at \(path).")
                    .font(PiFont.caption)
                    .foregroundStyle(.secondary)
            case .notInstalled:
                HStack(spacing: PiTheme.space8) {
                    Button("Install “pidesk”") { install() }
                    Text("Links it into ~/.local/bin, next to Pi itself.")
                        .font(PiFont.caption)
                        .foregroundStyle(.tertiary)
                }
            case let .conflicting(path):
                Text("Something else already exists at \(path); leaving it alone.")
                    .font(PiFont.caption)
                    .foregroundStyle(Color.piOrange)
            case .unavailable:
                Text("Available from the packaged app.")
                    .font(PiFont.caption)
                    .foregroundStyle(.tertiary)
            }
            if let toolError {
                Text(toolError).font(PiFont.caption).foregroundStyle(Color.piRed)
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
        case .running, .deferringToLaunchAgent, .deferringToExternalProcess: .piGreen
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
        case .starting: "Starting inside Pi Desktop…"
        case .running: "Running inside Pi Desktop"
        case .unavailable: "Unavailable"
        case .stopped: "Off"
        }
    }

    private var statusDetail: String? {
        switch supervisor.state {
        case let .unavailable(detail): detail
        case .deferringToLaunchAgent: "Managed by launchd; `pidesk daemon uninstall` returns hosting to Pi Desktop."
        case .deferringToExternalProcess: "Quit the standalone service before restarting Pi Desktop to return to app-hosted mode."
        default: nil
        }
    }
}
