// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The CEF binary distribution lives in <repo>/Vendor/cef (see scripts/fetch-cef.sh).
let cefRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../Vendor/cef")
    .standardizedFileURL.path
let cefWrapper = "\(cefRoot)/build/libcef_dll_wrapper/libcef_dll_wrapper.a"

// Must match the flags libcef_dll_wrapper is built with (cmake/cef_variables.cmake).
let cefCxxSettings: [CXXSetting] = [
    .unsafeFlags(["-I", cefRoot, "-fno-rtti", "-fno-exceptions", "-fobjc-arc"]),
]

// OPENARCH_ENGINE=chromium (App/build.sh): Chrome's own framework instead of
// CEF (docs/chromium-engine.md). The bridge's classes live in the framework;
// OPENARCH_ENGINE_FRAMEWORKS is the folder that holds it.
let environment = ProcessInfo.processInfo.environment
let chromiumEngine = environment["OPENARCH_ENGINE"] == "chromium"
let engineFrameworks = environment["OPENARCH_ENGINE_FRAMEWORKS"] ?? ""

let coreTarget: Target = chromiumEngine
    ? .target(
        name: "OpenArchCore",
        path: "Sources/OpenArchCoreChromium",
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags(["-F", engineFrameworks, "-framework", "Chromium Framework"]),
            .linkedFramework("AppKit"),
        ]
    )
    : .target(
        name: "OpenArchCore",
        publicHeadersPath: "include",
        cxxSettings: cefCxxSettings,
        linkerSettings: [
            .unsafeFlags([cefWrapper]),
            .linkedFramework("AppKit"),
        ]
    )

// Chrome's framework brings its own helper apps.
let helperTargets: [Target] = chromiumEngine ? [] : [
    .executableTarget(
        name: "OpenArchHelper",
        cxxSettings: cefCxxSettings,
        linkerSettings: [
            .unsafeFlags([cefWrapper]),
            .linkedFramework("Foundation"),
        ]
    ),
]

let package = Package(
    name: "OpenArch",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../Localization"),
    ],
    targets: [
        coreTarget,
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
    ] + helperTargets,
    cxxLanguageStandard: .cxx20
)
