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
    ],
    targets: [
        .target(
            name: "MobileCLIPKit",
            dependencies: [
                .product(name: "AutoAlbumCore", package: "AutoAlbumCore"),
            ],
            path: "Sources/MobileCLIPKit"
        ),
    ]
)
