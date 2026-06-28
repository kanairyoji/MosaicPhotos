// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSourceKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhotoSourceKit", targets: ["PhotoSourceKit"]),
    ],
    dependencies: [
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "PhotoSourceKit",
            dependencies: [
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/PhotoSourceKit",
            // String Catalog を明示宣言（SwiftPM CLI は .xcstrings を自動認識しないため）。
            // これで Bundle.module が生成され、`L()` の解決先が確定する。
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(
            name: "PhotoSourceKitTests",
            dependencies: ["PhotoSourceKit"],
            path: "Tests/PhotoSourceKitTests"
        ),
    ]
)
