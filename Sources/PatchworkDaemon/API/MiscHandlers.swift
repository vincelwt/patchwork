import Foundation
import PatchworkKit

enum HealthHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [Route("GET", "/v1/health") { _, _ in .json(await core.health()) }]
    }
}

enum ActivityHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [Route("GET", "/v1/activity") { _, _ in .json(await core.activityService.snapshot()) }]
    }
}

enum LimitsHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [Route("GET", "/v1/limits") { _, _ in .json(await core.limitsCache.snapshot()) }]
    }
}

/// Assembles every endpoint in `docs/daemon-api.md` (`GET /v1/events` is handled specially by
/// `HTTPServer` itself, not routed here).
enum Routes {
    static func all(_ core: DaemonCore) -> [Route] {
        HealthHandlers.routes(core)
            + ThreadHandlers.routes(core)
            + ActivityHandlers.routes(core)
            + ScheduleHandlers.routes(core)
            + RunHandlers.routes(core)
            + LimitsHandlers.routes(core)
            + InteractionHandlers.routes(core)
            + RemoteHandlers.routes(core)
    }
}
