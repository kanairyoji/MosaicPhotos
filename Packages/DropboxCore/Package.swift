// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DropboxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DropboxCore", targets: ["DropboxCore"]),
        // テスト専用の偽 Dropbox。DropboxCore と BackupKit の**両方のテスト**から使う
        //（状態を持つ偽物を 1 つに保つため・本番ターゲットは依存しない）。
        .library(name: "DropboxTestSupport", targets: ["DropboxTestSupport"]),
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
        .target(
            name: "DropboxTestSupport",
            dependencies: ["DropboxCore"],
            path: "Sources/DropboxTestSupport"
        ),
        .testTarget(
            name: "DropboxCoreTests",
            dependencies: ["DropboxCore", "DropboxTestSupport"],
            path: "Tests/DropboxCoreTests"
        ),
    ]
)
