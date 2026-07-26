// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PiDesktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PiDesktop", targets: ["PiDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "PiDesktop",
            path: "Sources/PiDesktop"
        ),
        .testTarget(
            name: "PiDesktopTests",
            dependencies: ["PiDesktop"],
            path: "Tests/PiDesktopTests"
        )
    ]
)
