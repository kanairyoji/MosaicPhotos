// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PerceptionCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PerceptionCore", targets: ["PerceptionCore"]),
    ],
    dependencies: [
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "PerceptionCore",
            dependencies: [.product(name: "MosaicSupport", package: "MosaicSupport")],
            path: "Sources/PerceptionCore"
        ),
        .testTarget(
            name: "PerceptionCoreTests",
            dependencies: ["PerceptionCore"],
            path: "Tests/PerceptionCoreTests"
        ),
    ]
)
