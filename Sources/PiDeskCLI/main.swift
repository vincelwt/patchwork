import Foundation

// Thin entry point: all logic lives in CLIRunner so it can be driven identically from tests
// with a fake CLIHost. Top-level code in a `main.swift` is an implicit async context, so `await`
// works here directly (SE-0343).
let exitCode = await CLIRunner.run(Array(CommandLine.arguments.dropFirst()), host: .live())
exit(exitCode)
