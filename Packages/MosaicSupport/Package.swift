// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MosaicSupport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MosaicSupport", targets: ["MosaicSupport"]),
    ],
    targets: [
        .target(
            name: "MosaicSupport",
            path: "Sources/MosaicSupport"
        ),
        .testTarget(
            name: "MosaicSupportTests",
            dependencies: ["MosaicSupport"],
            path: "Tests/MosaicSupportTests"
        ),
    ]
)
