import Foundation
import PatchworkKit

enum RunHandlers {
    static func routes(_ core: DaemonCore) -> [Route] {
        [
            Route("GET", "/v1/runs") { request, _ in
                let limit = max(1, min(request.query["limit"].flatMap(Int.init) ?? 50, 500))
                let runs = await core.runHistoryStore.query(
                    scheduleId: request.query["scheduleId"],
                    threadId: request.query["threadId"],
                    limit: limit
                )
                return .json(RunListResponse(runs: runs))
            },
            Route("GET", "/v1/runs/:id") { _, params in
                guard let id = params["id"], let run = await core.runHistoryStore.get(id: id) else {
                    throw DaemonHTTPError.notFound("Run \(params["id"] ?? "")")
                }
                return .json(RunResponse(run: run))
            }
        ]
    }
}
