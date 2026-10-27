// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveNotes",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LiveNotesCore", targets: ["LiveNotesCore"]),
        .executable(name: "LiveNotes", targets: ["LiveNotesApp"])
    ],
    targets: [
        .target(
            name: "LiveNotesCore",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "LiveNotesApp",
            dependencies: ["LiveNotesCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "LiveNotesTests",
            dependencies: ["LiveNotesCore"],
            path: "Tests"
        )
    ]
)
