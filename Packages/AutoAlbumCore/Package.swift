// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoAlbumCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AutoAlbumCore", targets: ["AutoAlbumCore"]),
    ],
    dependencies: [
        .package(path: "../PhotoSourceKit"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "AutoAlbumCore",
            dependencies: [
                .product(name: "PhotoSourceKit", package: "PhotoSourceKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/AutoAlbumCore"
        ),
        .testTarget(
            name: "AutoAlbumCoreTests",
            dependencies: ["AutoAlbumCore"],
            path: "Tests/AutoAlbumCoreTests"
        ),
    ]
)
