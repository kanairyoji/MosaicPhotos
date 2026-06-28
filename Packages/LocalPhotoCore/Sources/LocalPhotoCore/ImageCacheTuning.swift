#if canImport(UIKit)
import Foundation
import ImageCacheKit

/// 画像キャッシュ系の内部チューニング値を**表示用に公開**する小さなファサード。
/// 値の実体は `ImageCacheKit`（アプリは直接リンクしないため、リンク済みの本パッケージ経由で見せる）。
/// Developer Options のメモリ診断で参照する。
public enum ImageCacheTuning {
    /// フル画像の表示時ダウンサンプル最大辺（px）。
    public static var fullImageMaxPixel: Int { Int(ImageDownsampling.displayMaxPixel) }
    /// メモリ圧迫時に絞る最小上限（MB）。
    public static var memoryPressureFloorMB: Int { MemoryImageCache.pressureFloorBytes / (1024 * 1024) }
    /// 圧迫後に上限を元へ戻すまでの秒数。
    public static var memoryPressureRestoreSeconds: Int { Int(MemoryImageCache.pressureRestoreDelay) }
}
#endif
