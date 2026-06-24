// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageCacheKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ImageCacheKit", targets: ["ImageCacheKit"]),
    ],
    targets: [
        .target(
            name: "ImageCacheKit",
            path: "Sources/ImageCacheKit"
        ),
        .testTarget(
            name: "ImageCacheKitTests",
            dependencies: ["ImageCacheKit"],
            path: "Tests/ImageCacheKitTests"
        ),
    ]
)
