// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AirPodWand",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AirPodWandCore",
            type: .static,
            targets: ["AirPodWandCore"]
        ),
        .executable(
            name: "AirPodWandCLI",
            targets: ["AirPodWandCLI"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AirPodWandCore",
            dependencies: [],
            path: "Sources/AirPodWandCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "AirPodWandCLI",
            dependencies: ["AirPodWandCore"],
            path: "Sources/AirPodWandCLI",
            exclude: ["Info.plist"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AirPodWandCLI/Info.plist"
                ])
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
