// swift-tools-version: 6.0
import PackageDescription

// What OpenArch for Mac and OpenArch for iPhone and iPad have in common:
// sharing bookmarks as encrypted links (see docs/sharing.md).
let package = Package(
    name: "OpenArchShared",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "OpenArchShared", targets: ["OpenArchShared"]),
    ],
    targets: [
        .target(name: "OpenArchShared"),
        .testTarget(name: "OpenArchSharedTests", dependencies: ["OpenArchShared"]),
    ]
)
