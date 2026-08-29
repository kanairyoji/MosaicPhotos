// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotosFeatureKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhotosFeatureKit", targets: ["PhotosFeatureKit"]),
    ],
    dependencies: [
        .package(path: "../PhotoSourceKit"),
        .package(path: "../LocalPhotoKit"),
        .package(path: "../DropboxKit"),
        .package(path: "../MosaicSupport"),
        .package(path: "../PerceptionCore"),   // PhotoRef / AnalysisOrder（解析候補の並び）
    ],
    targets: [
        .target(
            name: "PhotosFeatureKit",
            dependencies: [
                .product(name: "PhotoSourceKit", package: "PhotoSourceKit"),
                .product(name: "LocalPhotoKit", package: "LocalPhotoKit"),
                .product(name: "DropboxKit", package: "DropboxKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
                .product(name: "PerceptionCore", package: "PerceptionCore"),
            ],
            path: "Sources/PhotosFeatureKit"
        ),
        .testTarget(
            name: "PhotosFeatureKitTests",
            dependencies: ["PhotosFeatureKit"],
            path: "Tests/PhotosFeatureKitTests"
        ),
    ]
)
