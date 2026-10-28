// swift-tools-version: 5.9
import PackageDescription

// The deb2ipa app shell (M8) exists only where SwiftUI exists: the Linux
// CI compiles the DebKit library and tests only. Adding the executable
// target conditionally keeps `swift test` on ubuntu-24.04 building the
// exact same package graph it always has (lesson 7.S: the SwiftUI layer is
// compiled only by Xcode; here that is deliberate, not a gap - the
// macos-latest build-app workflow IS the app layer's compiler and its
// green run is the SwiftUI smoke test).
var targets: [Target] = [
    .target(
        name: "DebKit",
        dependencies: [
            .product(name: "SWCompression", package: "SWCompression"),
        ]
    ),
    .testTarget(
        name: "DebKitTests",
        dependencies: ["DebKit"]
    ),
]
#if canImport(SwiftUI)
targets.append(
    .executableTarget(
        name: "deb2ipa",
        dependencies: ["DebKit"]
    )
)
#endif

let package = Package(
    name: "DebKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DebKit", targets: ["DebKit"]),
    ],
    dependencies: [
        // Pinned to 4.8.7: 4.9.0+ raised SWCompression's platform floor to
        // iOS 17 / macOS 14, above this package's iOS 16 / macOS 13 contract.
        // The Linux CI cannot enforce iOS platform floors (no such platform
        // on Linux), so the conflict was only exposed by the M8 macOS build.
        // 4.9.0/4.9.1 changed no API DebKit uses; the pin keeps the floor.
        .package(url: "https://github.com/tsolomko/SWCompression.git", exact: "4.8.7"),
    ],
    targets: targets
)
