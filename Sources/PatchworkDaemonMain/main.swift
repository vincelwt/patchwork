import Darwin
import Foundation
import PatchworkDaemon
import PatchworkKit

PatchworkBrandMigration.run()
let service = PatchworkControlService()
let startup = Task { () -> Bool in
    do {
        try await service.start()
        return true
    } catch {
        FileHandle.standardError.write(Data("patchworkd: \(error.localizedDescription)\n".utf8))
        return false
    }
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
var isShuttingDown = false

func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    Task {
        _ = await startup.value
        await service.stop()
        exit(0)
    }
}

sigtermSource.setEventHandler(handler: shutdown)
sigintSource.setEventHandler(handler: shutdown)
sigtermSource.resume()
sigintSource.resume()

Task {
    if await !startup.value { exit(1) }
}

dispatchMain()
