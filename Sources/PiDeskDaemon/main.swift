import Darwin
import Foundation
import PiDeskKit

// Writing to a client that already closed its connection must raise EPIPE on the write() call,
// never terminate the daemon with SIGPIPE \u2014 a single dropped CLI connection is routine.
signal(SIGPIPE, SIG_IGN)

let settings = DaemonSettings.load()
let logger = DaemonLogger()
logger.info("pi-deskd starting (concurrency=\(settings.concurrency), remoteEnabled=\(settings.remoteEnabled), port=\(settings.port))")

let piVersion = PiVersion.detect()
let executor = PiProcessRunExecutor(logger: logger)
let core = DaemonCore(settings: settings, logger: logger, executor: executor, piVersion: piVersion)
let router = DaemonRouter(routes: Routes.all(core))
let server = HTTPServer(router: router, logger: logger, bus: core.bus, tokenProvider: {
    settings.remoteEnabled ? (try? DaemonToken.loadOrCreate()) : nil
})

do {
    try server.start(unixSocketPath: PiDeskPaths.controlSocket, tcpPort: settings.remoteEnabled ? settings.port : nil)
} catch {
    logger.error("Failed to start listeners: \(error)")
    FileHandle.standardError.write(Data("pi-deskd: \(error)\n".utf8))
    exit(1)
}

Task {
    await core.start()
    await core.startRelay(router: router)
}

// GCD signal sources (not the raw libc handler) so shutdown runs real Swift code \u2014 stopping the
// scheduler and flushing the log \u2014 instead of being restricted to async-signal-safe calls only.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

// A second SIGTERM/SIGINT while already shutting down (an impatient `kill`, or both signals
// arriving together) must not race two overlapping `core.stop()`/`exit(0)` calls.
var isShuttingDown = false

func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    logger.info("pi-deskd shutting down")
    server.stop()
    Task {
        await core.stop()
        logger.flush()
        exit(0)
    }
}

sigtermSource.setEventHandler(handler: shutdown)
sigintSource.setEventHandler(handler: shutdown)
sigtermSource.resume()
sigintSource.resume()

logger.info("pi-deskd ready")
dispatchMain()
