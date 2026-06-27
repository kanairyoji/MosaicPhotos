// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSourceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhotoSourceKit", targets: ["PhotoSourceKit"]),
    ],
    dependencies: [
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "PhotoSourceKit",
            dependencies: [
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/PhotoSourceKit"
        ),
        .testTarget(
            name: "PhotoSourceKitTests",
            dependencies: ["PhotoSourceKit"],
            path: "Tests/PhotoSourceKitTests"
        ),
    ]
)
