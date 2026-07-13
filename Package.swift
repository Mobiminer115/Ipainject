// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ForgeCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ForgeCore", targets: ["ForgeCore"])
    ],
    targets: [
        .target(
            name: "ForgeCore",
            path: "Sources/ForgeCore"
        ),
        .testTarget(
            name: "ForgeCoreTests",
            dependencies: ["ForgeCore"],
            path: "Tests/ForgeCoreTests"
        )
    ]
)
