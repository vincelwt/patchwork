import SwiftUI

struct DaemonSettingsView: View {
    @EnvironmentObject private var supervisor: DaemonSupervisor

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

            Text("Pi Desktop hosts threads, automations, CLI access, and remote access inside the app process. "
                + "They stop when the app quits. An explicitly installed `pi-deskd` login item remains independent.")
                .font(PiFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(PiTheme.space24)
        .frame(width: 420)
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
