// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DropboxKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DropboxKit", targets: ["DropboxKit"]),
    ],
    dependencies: [
        .package(path: "../DropboxCore"),
        .package(path: "../PhotoSourceKit"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "DropboxKit",
            dependencies: [
                .product(name: "DropboxCore", package: "DropboxCore"),
                .product(name: "PhotoSourceKit", package: "PhotoSourceKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/DropboxKit"
        ),
        .testTarget(
            name: "DropboxKitTests",
            dependencies: ["DropboxKit"],
            path: "Tests/DropboxKitTests"
        ),
    ]
)
