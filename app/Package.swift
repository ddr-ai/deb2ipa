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
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.9.0"),
    ],
    targets: targets
)
