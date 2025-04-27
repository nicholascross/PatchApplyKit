// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "MinimalPatchApply",
    products: [
        .library(
            name: "MinimalPatchApply",
            targets: ["MinimalPatchApply"]
        ),
    ],
    dependencies: [
        // No external dependencies
    ],
    targets: [
        .target(
            name: "MinimalPatchApply",
            path: "Sources/MinimalPatchApply"
        ),
        .testTarget(
            name: "MinimalPatchApplyTests",
            dependencies: ["MinimalPatchApply"],
            path: "Tests/MinimalPatchApplyTests"
        ),
    ]
)