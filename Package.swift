// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Islet",
            path: "Sources/Islet",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
