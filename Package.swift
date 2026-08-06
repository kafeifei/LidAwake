// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LidAwake",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "LidAwakeApp", targets: ["LidAwakeApp"]),
        .executable(name: "LidAwakeHelper", targets: ["LidAwakeHelper"]),
    ],
    targets: [
        .target(
            name: "LidAwakeCore"
        ),
        .executableTarget(
            name: "LidAwakeApp",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "LidAwakeHelper",
            dependencies: ["LidAwakeCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "LidAwakeCoreTests",
            dependencies: ["LidAwakeCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
