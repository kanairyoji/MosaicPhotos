// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalPhotoKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LocalPhotoKit", targets: ["LocalPhotoKit"]),
    ],
    dependencies: [
        .package(path: "../LocalPhotoCore"),
        .package(path: "../PhotoSourceKit"),
    ],
    targets: [
        .target(
            name: "LocalPhotoKit",
            dependencies: [
                .product(name: "LocalPhotoCore", package: "LocalPhotoCore"),
                .product(name: "PhotoSourceKit", package: "PhotoSourceKit"),
            ],
            path: "Sources/LocalPhotoKit"
        ),
    ]
)
