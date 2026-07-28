import Foundation

/// The doc defines `daemon.json`'s fields ("port, concurrency, remote enabled") but no HTTP
/// endpoint to change them — every other schedule/thread mutation goes through `/v1/...`, but
/// remote on/off is host-startup configuration, not run state. `enable`/`disable` therefore
/// edit `daemon.json` directly and tell the caller to restart whichever host is active. This is
/// the one place this CLI writes control-service storage instead of calling the API.
enum RemoteCommand {
    static let groupHelp = GroupHelp(
        name: "remote",
        usage: "pidesk remote <subcommand> [args]",
        summary: "Manage the opt-in loopback TCP listener used by the web remote.",
        subcommands: [
            ("enable", "Turn on the loopback listener"),
            ("disable", "Turn off the loopback listener"),
            ("url", "Print the loopback URL"),
            ("token", "Print the bearer token (generated on first use)")
        ]
    )

    static func run(_ args: [String], context: CommandContext) async -> Int32 {
        await dispatchGroup(args, groupHelp: groupHelp, handlers: [
            "enable": enable, "disable": disable, "url": url, "token": token
        ], context: context)
    }

    private static let enableHelp = CommandHelp(
        usage: "pidesk remote enable [--port 7717] [--json]",
        summary: "Enable the loopback TCP listener. Restart the active host for this to take effect.",
        flags: [FlagSpec("--port", takesValue: true, placeholder: "PORT", help: "listener port (default 7717)")],
        examples: ["pidesk remote enable", "pidesk remote enable --port 7900"]
    )

    private static func enable(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: enableHelp) { parsed, global in
            let port = try resolvePort(parsed.value("--port"))
            let store = DaemonSettingsStore(path: context.daemonSettingsPath, fileManager: context.fileManager)
            try store.writeRemoteSettings(.init(enabled: true, port: port))
            let token = try TokenStore.ensureToken(at: context.tokenFilePath, fileManager: context.fileManager)
            report(context: context, global: global, enabled: true, port: port, token: token)
        }
    }

    private static let disableHelp = CommandHelp(
        usage: "pidesk remote disable [--json]",
        summary: "Disable the loopback TCP listener. Restart the active host for this to take effect.",
        flags: [],
        examples: ["pidesk remote disable"]
    )

    private static func disable(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: disableHelp) { _, global in
            let store = DaemonSettingsStore(path: context.daemonSettingsPath, fileManager: context.fileManager)
            var settings = store.readRemoteSettings()
            settings.enabled = false
            try store.writeRemoteSettings(settings)
            report(context: context, global: global, enabled: false, port: settings.port, token: nil)
        }
    }

    private static let urlHelp = CommandHelp(usage: "pidesk remote url [--json]", summary: "Print the loopback remote's URL.", flags: [], examples: ["pidesk remote url"])

    private static func url(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: urlHelp) { _, global in
            let settings = DaemonSettingsStore(path: context.daemonSettingsPath, fileManager: context.fileManager).readRemoteSettings()
            let urlString = "http://127.0.0.1:\(settings.port)"
            if global.jsonOutput {
                context.out.json(RemoteStatus(enabled: settings.enabled, port: settings.port, url: urlString))
            } else {
                context.out.line(urlString)
                if !settings.enabled { context.out.info("(disabled — run `pidesk remote enable`)") }
            }
        }
    }

    private static let tokenHelp = CommandHelp(usage: "pidesk remote token [--json]", summary: "Print the bearer token for the loopback remote, generating one on first use.", flags: [], examples: ["pidesk remote token"])

    private static func token(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: tokenHelp) { _, global in
            let token = try TokenStore.ensureToken(at: context.tokenFilePath, fileManager: context.fileManager)
            if global.jsonOutput { context.out.json(["token": token]) } else { context.out.line(token) }
        }
    }

    private static func report(context: CommandContext, global: GlobalOptions, enabled: Bool, port: Int, token: String?) {
        let urlString = "http://127.0.0.1:\(port)"
        if global.jsonOutput {
            context.out.json(RemoteStatus(enabled: enabled, port: port, url: urlString, token: token))
            return
        }
        context.out.line("Remote \(enabled ? "enabled" : "disabled"): \(urlString)")
        context.out.info("Restart the active host: reopen Pi Desktop, or run `pidesk daemon restart` for a LaunchAgent.")
    }

    private static func resolvePort(_ raw: String?) throws -> Int {
        guard let raw else { return 7717 }
        guard let port = Int(raw), (1...65535).contains(port) else {
            throw UsageError.invalidValue(flag: "--port", value: raw, reason: "expected a port number 1-65535")
        }
        return port
    }
}

struct RemoteStatus: Codable, Equatable {
    var enabled: Bool
    var port: Int
    var url: String
    var token: String?

    init(enabled: Bool, port: Int, url: String, token: String? = nil) {
        self.enabled = enabled
        self.port = port
        self.url = url
        self.token = token
    }
}
