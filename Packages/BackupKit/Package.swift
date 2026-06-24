// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BackupKit",
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
            path: "Sources/BackupKit"
        ),
        .testTarget(
            name: "BackupKitTests",
            dependencies: ["BackupKit"],
            path: "Tests/BackupKitTests"
        ),
    ]
)
