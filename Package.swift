// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TaskManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TaskManager", targets: ["TaskManager"])
    ],
    targets: [
        .executableTarget(
            name: "TaskManager",
            path: "Sources/TaskManager",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "TaskManagerTests",
            dependencies: ["TaskManager"],
            path: "Tests/TaskManagerTests"
        ),
    ]
)
