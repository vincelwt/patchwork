import SwiftUI

/// The one Settings pane so far: whether Pi Desktop.app manages `pi-deskd` itself, and its
/// current state. Deliberately plain — this is the only place `DaemonSupervisor`'s state needs a
/// window, so it doesn't need the sidebar/tab chrome a bigger settings surface would.
struct DaemonSettingsView: View {
    @EnvironmentObject private var supervisor: DaemonSupervisor

    var body: some View {
        VStack(alignment: .leading, spacing: PiTheme.space16) {
            Text("Background Service").font(PiFont.title)

            Toggle("Automatically run the background service with this app", isOn: $supervisor.autoManageEnabled)
                .toggleStyle(.switch)

            HStack(spacing: PiTheme.space8) {
                StatusDot(color: statusColor)
                Text(statusLine).font(PiFont.caption).foregroundStyle(.secondary)
            }

            if let detail = statusDetail {
                Text(detail).font(PiFont.caption).foregroundStyle(.tertiary)
            }

            if showsRetry {
                Button("Try Again") { Task { await supervisor.retry() } }
            }

            Divider()

            Text("Automations (Cron/scheduled prompts) need this service running. Turning it off "
                + "stops it if this app started it; a background service you installed with "
                + "`pidesk daemon install` is never touched here.")
                .font(PiFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(PiTheme.space24)
        .frame(width: 420)
    }

    private var statusColor: Color {
        switch supervisor.state {
        case .running, .deferringToLaunchAgent, .deferringToExternalProcess: .piGreen
        case .starting, .restarting: .yellow
        case .crashLooped, .unavailable: .red
        case .idle, .disabledByUser, .stopped: .secondary
        }
    }

    private var statusLine: String {
        switch supervisor.state {
        case .idle: "Checking…"
        case .disabledByUser: "Off"
        case .deferringToLaunchAgent: "Running (installed as a login item)"
        case .deferringToExternalProcess: "Running (started outside this app)"
        case .starting: "Starting…"
        case .running: "Running"
        case let .restarting(attempt): "Restarting… (attempt \(attempt))"
        case .crashLooped: "Not responding"
        case .unavailable: "Unavailable"
        case .stopped: "Off"
        }
    }

    private var statusDetail: String? {
        switch supervisor.state {
        case let .crashLooped(detail), let .unavailable(detail): detail
        case .deferringToLaunchAgent: "Managed by launchd, not this app; `pidesk daemon uninstall` removes it."
        default: nil
        }
    }

    private var showsRetry: Bool {
        switch supervisor.state {
        case .crashLooped, .unavailable: true
        default: false
        }
    }
}
