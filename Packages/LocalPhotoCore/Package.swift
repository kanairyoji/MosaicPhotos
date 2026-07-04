// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalPhotoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LocalPhotoCore", targets: ["LocalPhotoCore"]),
    ],
    dependencies: [
        .package(path: "../PhotoSourceKit"),
        .package(path: "../ImageCacheKit"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "LocalPhotoCore",
            dependencies: [
                .product(name: "PhotoSourceKit", package: "PhotoSourceKit"),
                .product(name: "ImageCacheKit", package: "ImageCacheKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/LocalPhotoCore"
        ),
        .testTarget(
            name: "LocalPhotoCoreTests",
            dependencies: ["LocalPhotoCore"],
            path: "Tests/LocalPhotoCoreTests"
        ),
    ]
)
