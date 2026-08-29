// swift-tools-version: 5.9
import PackageDescription

/// ピープル（顔クラスタ）の **UI 層**。
///
/// ⚠️ 端末写真（LocalPhotoCore/LocalPhotoKit）と Dropbox（DropboxCore/DropboxKit）は
/// ロジック層と UI 層の 2 パッケージに分けてあるのに、**ピープルだけ UI がアプリに残っていた**
/// （11 ファイル・約 1,800 行＝アプリの Home/ の 4 割）。同じ構成に揃える:
/// ロジックは `FaceCore`、UI はここ。アプリは合成に専念する。
let package = Package(
    name: "PeopleKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PeopleKit", targets: ["PeopleKit"]),
    ],
    dependencies: [
        .package(path: "../AutoAlbumCore"),      // FaceCore / PerceptionCore を再エクスポート
        .package(path: "../PhotosFeatureKit"),   // MergedPhotoStore / LocalAssetIndex
        .package(path: "../BackupKit"),          // 共有セット（人物の共有）
        .package(path: "../MosaicSupport"),
    ],
    targets: [
        .target(
            name: "PeopleKit",
            dependencies: [
                .product(name: "AutoAlbumCore", package: "AutoAlbumCore"),
                .product(name: "PhotosFeatureKit", package: "PhotosFeatureKit"),
                .product(name: "BackupKit", package: "BackupKit"),
                .product(name: "MosaicSupport", package: "MosaicSupport"),
            ],
            path: "Sources/PeopleKit",
            // ⚠️ SwiftPM CLI は .xcstrings を自動認識しない。明示しないと Bundle.module が
            // 生成されず `swift test` が落ちる（root CLAUDE.md の i18n 規約）。
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(
            name: "PeopleKitTests",
            dependencies: ["PeopleKit"],
            path: "Tests/PeopleKitTests"
        ),
    ]
)
