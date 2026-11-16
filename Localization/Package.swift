// swift-tools-version: 6.0
import PackageDescription

// The language layer is its own package so its tests run without the CEF
// toolchain (App's executable targets need Vendor/cef).
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
