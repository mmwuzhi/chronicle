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
        .target(
            name: "ChronicleDesktopCore",
            linkerSettings: [.linkedLibrary("sqlite3")],
        ),
        .executableTarget(
            name: "ChronicleDesktop",
            dependencies: ["ChronicleDesktopCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ],
        ),
        .testTarget(
            name: "ChronicleDesktopCoreTests",
            dependencies: ["ChronicleDesktopCore"],
        ),
        .testTarget(
            name: "ChronicleDesktopE2ETests",
            dependencies: ["ChronicleDesktop", "ChronicleDesktopCore"],
            linkerSettings: [.linkedFramework("Network")],
        ),
    ],
)
