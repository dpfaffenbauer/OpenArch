// swift-tools-version: 6.0
import Foundation
import PackageDescription

// OpenArch runs on Chrome's own framework with OpenArch's layer
// (docs/chromium-engine.md). The bridge's classes (OACEngine, OACPane,
// OACProfile) live in the framework; OPENARCH_ENGINE_FRAMEWORKS, set by
// App/build.sh, is the folder that holds it. Without it, the engine
// scripts/fetch-chromium-engine.sh put into Vendor/engine.
let engineFrameworks = ProcessInfo.processInfo.environment["OPENARCH_ENGINE_FRAMEWORKS"]
    ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../Vendor/engine/Chromium.app/Contents/Frameworks")
        .standardizedFileURL.path

let package = Package(
    name: "OpenArch",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../Localization"),
    ],
    targets: [
        .target(
            name: "OpenArchCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-F", engineFrameworks, "-framework", "Chromium Framework"]),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "OpenArch",
            dependencies: ["OpenArchCore",
                           .product(name: "OpenArchLocalization", package: "Localization"),
                           .product(name: "OpenArchShared", package: "Shared")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Apple's on-device model (macOS 26 and later); OpenArch still starts on macOS 15.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
