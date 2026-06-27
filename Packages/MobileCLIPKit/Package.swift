// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobileCLIPKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MobileCLIPKit", targets: ["MobileCLIPKit"]),
    ],
    dependencies: [
        .package(path: "../AutoAlbumCore"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "MobileCLIPKit",
            dependencies: [
                .product(name: "AutoAlbumCore", package: "AutoAlbumCore"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/MobileCLIPKit"
        ),
    ]
)
