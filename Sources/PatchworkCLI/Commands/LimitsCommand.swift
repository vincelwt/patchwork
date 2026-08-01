import Foundation

/// The one leaf command with no subgroup: `patchwork limits [--json]`.
enum LimitsCommand {
    private static let help = CommandHelp(
        usage: "patchwork limits [--json]",
        summary: "Show the daemon's last parsed /limits usage report.",
        flags: [],
        examples: ["patchwork limits", "patchwork limits --json | jq .report"]
    )

    static func run(_ args: [String], context: CommandContext) async -> Int32 {
        await runLeaf(args, context: context, help: help) { _, global in
            let response = try await context.makeControlPlane(global).limits()
            if global.jsonOutput {
                context.out.json(response)
                return
            }
            if let stale = response.stale, stale { context.out.info("(stale — generated \(FlexibleDate.displayLocal(response.generatedAt)))") }
            context.out.line(response.report.renderedHuman())
        }
    }
}
