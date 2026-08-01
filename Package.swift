// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Patchwork",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Keep the internal build artifact distinct from the lowercase `patchwork` CLI on
        // case-insensitive filesystems. Packaging still installs this as Patchwork.app/Patchwork.
        .executable(name: "PatchworkApp", targets: ["Patchwork"]),
        // Optional always-on host for the same control service embedded in Patchwork.
        .executable(name: "patchworkd", targets: ["PatchworkDaemonMain"]),
        .executable(name: "patchwork", targets: ["PatchworkCLI"]),
        .library(name: "PatchworkKit", targets: ["PatchworkKit"]),
        .library(name: "PatchworkWeb", targets: ["PatchworkWeb"])
    ],
    targets: [
        .target(
            name: "PatchworkKit",
            path: "Sources/PatchworkKit"
        ),
        .executableTarget(
            name: "Patchwork",
            dependencies: ["PatchworkKit", "PatchworkDaemon"],
            path: "Sources/Patchwork"
        ),
        .target(
            name: "PatchworkDaemon",
            dependencies: ["PatchworkKit", "PatchworkWeb"],
            path: "Sources/PatchworkDaemon"
        ),
        .executableTarget(
            name: "PatchworkDaemonMain",
            dependencies: ["PatchworkDaemon", "PatchworkKit"],
            path: "Sources/PatchworkDaemonMain"
        ),
        .executableTarget(
            name: "PatchworkCLI",
            dependencies: ["PatchworkKit"],
            path: "Sources/PatchworkCLI"
        ),
        // The remote web UI, embedded as resources so the daemon serves it without a build step.
        .target(
            name: "PatchworkWeb",
            dependencies: ["PatchworkKit"],
            path: "Sources/PatchworkWeb",
            resources: [.copy("Site")]
        ),
        .testTarget(
            name: "PatchworkTests",
            dependencies: ["Patchwork"],
            path: "Tests/PatchworkTests"
        ),
        .testTarget(
            name: "PatchworkKitTests",
            dependencies: ["PatchworkKit"],
            path: "Tests/PatchworkKitTests"
        ),
        .testTarget(
            name: "PatchworkDaemonTests",
            dependencies: ["PatchworkDaemon", "PatchworkKit"],
            path: "Tests/PatchworkDaemonTests"
        ),
        .testTarget(
            name: "PatchworkCLITests",
            dependencies: ["PatchworkCLI", "PatchworkKit"],
            path: "Tests/PatchworkCLITests"
        ),
        .testTarget(
            name: "PatchworkWebTests",
            dependencies: ["PatchworkWeb"],
            path: "Tests/PatchworkWebTests"
        )
    ]
)
