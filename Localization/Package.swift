// swift-tools-version: 6.0
import PackageDescription

// The language layer is its own package so its tests run without Chrome's
// framework (App's executable target links it).
let package = Package(
    name: "OpenArchLocalization",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OpenArchLocalization", targets: ["OpenArchLocalization"]),
    ],
    targets: [
        .target(name: "OpenArchLocalization"),
        .testTarget(name: "OpenArchLocalizationTests", dependencies: ["OpenArchLocalization"]),
    ]
)
