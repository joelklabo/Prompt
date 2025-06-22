// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Prompt",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "PromptShared",
            targets: ["PromptShared"]
        )
    ],
    dependencies: [
        // Dependencies will be added here when needed
    ],
    targets: [
        .target(
            name: "PromptShared",
            path: "Shared",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PromptTests",
            dependencies: ["PromptShared"],
            path: "Tests/SharedTests"
        ),
    ]
)
