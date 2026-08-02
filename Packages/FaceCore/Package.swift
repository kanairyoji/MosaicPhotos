// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FaceCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FaceCore", targets: ["FaceCore"]),
    ],
    dependencies: [
        .package(path: "../MosaicSupport"),
        .package(path: "../PerceptionCore"),
    ],
    targets: [
        .target(
            name: "FaceCore",
            dependencies: [
                .product(name: "MosaicSupport", package: "MosaicSupport"),
                .product(name: "PerceptionCore", package: "PerceptionCore"),
            ],
            path: "Sources/FaceCore"
        ),
        .testTarget(
            name: "FaceCoreTests",
            dependencies: ["FaceCore"],
            path: "Tests/FaceCoreTests"
        ),
    ]
)
