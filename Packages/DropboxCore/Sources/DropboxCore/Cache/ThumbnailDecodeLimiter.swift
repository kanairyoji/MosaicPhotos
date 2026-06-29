import Foundation
import ImageCacheKit

/// Dropbox サムネの**ディスク**デコード（読込＋強制デコード）の同時実行数を制限する共有セマフォ。
/// 要求ごとに無制限の `Task.detached` を生むと協調スレッドプールが飽和し、CPU 競合で 1 枚が桁違いに
/// 遅くなる（実機計測で ~129ms に膨張）。同時実行を端末コア数程度に抑えて行列を浅く保つ。
/// ※ ネット応答のデコードはバッチ並行数で既に有界なので本セマフォは通さない（分離）。
enum ThumbnailDecode {
    static let limiter = AsyncSemaphore(value: DropboxInternalConstants.thumbnailDecodeConcurrency)
}
