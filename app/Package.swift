// swift-tools-version: 5.9
import PackageDescription

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
    targets: [
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
)
