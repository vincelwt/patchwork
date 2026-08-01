import Foundation

/// A leaf command's `--help` content (e.g. `patchwork threads list --help`).
struct CommandHelp {
    var usage: String
    var summary: String
    var flags: [FlagSpec]
    var examples: [String]
}

/// A group's `--help` content (e.g. `patchwork threads --help`), listing its subcommands.
struct GroupHelp {
    var name: String
    var usage: String
    var summary: String
    var subcommands: [(name: String, summary: String)]
}

enum HelpPrinter {
    static func render(_ help: CommandHelp, includeGlobal: Bool = true) -> String {
        var lines = ["Usage: \(help.usage)", "", help.summary]
        let global = includeGlobal ? GlobalFlag.all : []
        let width = (help.flags + global).map(\.synopsis.count).max() ?? 0

        if !help.flags.isEmpty {
            lines.append("")
            lines.append("Options:")
            for flag in help.flags { lines.append(row(flag, width: width)) }
        }
        if includeGlobal {
            lines.append("")
            lines.append("Global options:")
            for flag in global { lines.append(row(flag, width: width)) }
        }
        if !help.examples.isEmpty {
            lines.append("")
            lines.append("Examples:")
            for example in help.examples { lines.append("  \(example)") }
        }
        return lines.joined(separator: "\n")
    }

    static func render(_ help: GroupHelp) -> String {
        var lines = ["Usage: \(help.usage)", "", help.summary, "", "Subcommands:"]
        let width = help.subcommands.map(\.name.count).max() ?? 0
        for sub in help.subcommands {
            lines.append("  \(sub.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(sub.summary)")
        }
        lines.append("")
        lines.append("Run `patchwork \(help.name) <subcommand> --help` for details on a subcommand.")
        return lines.joined(separator: "\n")
    }

    private static func row(_ flag: FlagSpec, width: Int) -> String {
        "  \(flag.synopsis.padding(toLength: width, withPad: " ", startingAt: 0))  \(flag.help)"
    }
}
