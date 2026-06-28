// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageCacheKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ImageCacheKit", targets: ["ImageCacheKit"]),
    ],
    dependencies: [
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "ImageCacheKit",
            dependencies: [
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/ImageCacheKit"
        ),
        .testTarget(
            name: "ImageCacheKitTests",
            dependencies: ["ImageCacheKit"],
            path: "Tests/ImageCacheKitTests"
        ),
    ]
)
