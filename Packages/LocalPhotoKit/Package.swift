// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalPhotoKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LocalPhotoKit", targets: ["LocalPhotoKit"]),
    ],
    dependencies: [
        .package(path: "../LocalPhotoCore"),
        .package(path: "../PhotoSourceKit"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "LocalPhotoKit",
            dependencies: [
                .product(name: "LocalPhotoCore", package: "LocalPhotoCore"),
                .product(name: "PhotoSourceKit", package: "PhotoSourceKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/LocalPhotoKit",
            resources: [.process("Localizable.xcstrings")]
        ),
    ]
)
