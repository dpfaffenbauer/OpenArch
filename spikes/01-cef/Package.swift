// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The CEF binary distribution lives in <repo>/Vendor/cef (see scripts/fetch-cef.sh).
let cefRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../Vendor/cef")
    .standardizedFileURL.path
let cefWrapper = "\(cefRoot)/build/libcef_dll_wrapper/libcef_dll_wrapper.a"

// Must match the flags libcef_dll_wrapper is built with (cmake/cef_variables.cmake).
let cefCxxSettings: [CXXSetting] = [
    .unsafeFlags(["-I", cefRoot, "-fno-rtti", "-fno-exceptions", "-fobjc-arc"]),
]

let package = Package(
    name: "OpenArchSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "OpenArchCore",
            publicHeadersPath: "include",
            cxxSettings: cefCxxSettings,
            linkerSettings: [
                .unsafeFlags([cefWrapper]),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "OpenArchSpike",
            dependencies: ["OpenArchCore"]
        ),
        .executableTarget(
            name: "OpenArchSpikeHelper",
            cxxSettings: cefCxxSettings,
            linkerSettings: [
                .unsafeFlags([cefWrapper]),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
