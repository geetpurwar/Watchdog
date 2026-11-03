// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Watchdog",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Watchdog",
            path: "Sources/Watchdog",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
