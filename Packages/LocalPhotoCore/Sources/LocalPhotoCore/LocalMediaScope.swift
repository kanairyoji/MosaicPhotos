import Photos

/// 端末のライブラリ全体を一覧するときに、何を含めるか。
///
/// 動画を出すのはホームの「すべて」「端末」だけ（2026-10-17）。解析・場所・旅行アルバム・
/// バックアップは写真だけを前提にしていて、それぞれ自分で `mediaType == image` を絞っている。
/// ⚠️ ここを変えても、それらには効かない（効かせるときは各所を数えて直す）。
public enum LocalMediaScope: Sendable, Equatable {
    /// 写真だけ。
    case photosOnly
    /// 写真と動画。
    case photosAndVideos

    /// 一覧の取得に使う条件。
    var predicate: NSPredicate {
        switch self {
        case .photosOnly:
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .photosAndVideos:
            NSPredicate(format: "mediaType == %d || mediaType == %d",
                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        }
    }

    /// 動画を含み得るか（フィルタの「写真／動画」欄）。
    public var includesVideos: Bool { self == .photosAndVideos }
}
