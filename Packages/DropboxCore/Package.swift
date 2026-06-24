// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DropboxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DropboxCore", targets: ["DropboxCore"]),
    ],
    dependencies: [
        .package(path: "../ImageCacheKit"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "DropboxCore",
            dependencies: [
                .product(name: "ImageCacheKit", package: "ImageCacheKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/DropboxCore"
        ),
        .testTarget(
            name: "DropboxCoreTests",
            dependencies: ["DropboxCore"],
            path: "Tests/DropboxCoreTests"
        ),
    ]
)
