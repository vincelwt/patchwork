// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PiDesktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PiDesktop", targets: ["PiDesktop"]),
        // The headless half: a scheduler/runner daemon and its client CLI. See docs/daemon-api.md.
        .executable(name: "pi-deskd", targets: ["PiDeskDaemon"]),
        .executable(name: "pidesk", targets: ["PiDeskCLI"]),
        .library(name: "PiDeskKit", targets: ["PiDeskKit"]),
        .library(name: "PiDeskWeb", targets: ["PiDeskWeb"])
    ],
    targets: [
        .target(
            name: "PiDeskKit",
            path: "Sources/PiDeskKit"
        ),
        .executableTarget(
            name: "PiDesktop",
            dependencies: ["PiDeskKit"],
            path: "Sources/PiDesktop"
        ),
        .executableTarget(
            name: "PiDeskDaemon",
            dependencies: ["PiDeskKit"],
            path: "Sources/PiDeskDaemon"
        ),
        .executableTarget(
            name: "PiDeskCLI",
            dependencies: ["PiDeskKit"],
            path: "Sources/PiDeskCLI"
        ),
        // The remote web UI, embedded as resources so the daemon serves it without a build step.
        .target(
            name: "PiDeskWeb",
            dependencies: ["PiDeskKit"],
            path: "Sources/PiDeskWeb",
            resources: [.copy("Site")]
        ),
        .testTarget(
            name: "PiDesktopTests",
            dependencies: ["PiDesktop"],
            path: "Tests/PiDesktopTests"
        ),
        .testTarget(
            name: "PiDeskKitTests",
            dependencies: ["PiDeskKit"],
            path: "Tests/PiDeskKitTests"
        ),
        .testTarget(
            name: "PiDeskDaemonTests",
            dependencies: ["PiDeskDaemon", "PiDeskKit"],
            path: "Tests/PiDeskDaemonTests"
        ),
        .testTarget(
            name: "PiDeskCLITests",
            dependencies: ["PiDeskCLI", "PiDeskKit"],
            path: "Tests/PiDeskCLITests"
        ),
        .testTarget(
            name: "PiDeskWebTests",
            dependencies: ["PiDeskWeb"],
            path: "Tests/PiDeskWebTests"
        )
    ]
)
