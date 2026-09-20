// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BackupKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BackupKit", targets: ["BackupKit"]),
    ],
    dependencies: [
        .package(path: "../DropboxCore"),
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "BackupKit",
            dependencies: [
                .product(name: "DropboxCore", package: "DropboxCore"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/BackupKit",
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(
            name: "BackupKitTests",
            dependencies: [
                "BackupKit",
                // 状態を持つ偽 Dropbox は DropboxCore 側の支援ターゲットに 1 つだけ置く
                //（BackupKit と DropboxCore の両方のテストから同じものを使う）。
                .product(name: "DropboxTestSupport", package: "DropboxCore"),
            ],
            path: "Tests/BackupKitTests"
        ),
    ]
)
