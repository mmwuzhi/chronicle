// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChronicleDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ChronicleDesktop", targets: ["ChronicleDesktop"]),
        .library(name: "ChronicleDesktopCore", targets: ["ChronicleDesktopCore"]),
    ],
    targets: [
        .target(name: "ChronicleDesktopCore"),
        .executableTarget(
            name: "ChronicleDesktop",
            dependencies: ["ChronicleDesktopCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ],
        ),
        .testTarget(
            name: "ChronicleDesktopCoreTests",
            dependencies: ["ChronicleDesktopCore"],
        ),
    ],
)
