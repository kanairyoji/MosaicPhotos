import Foundation
import ImageCacheKit

/// Dropbox サムネのデコード（ディスク読込＋強制デコード／ネット応答のデコード）の**同時実行数**を
/// 全体で制限する共有セマフォ。要求ごとに無制限の `Task.detached` を生むと協調スレッドプールが飽和し、
/// CPU 競合で 1 枚のデコードが桁違いに遅くなる（実機計測でディスクヒットが ~129ms に膨張）。
/// 同時実行を端末コア数に応じて抑え、各デコードを軽く・公平に保つ。
enum ThumbnailDecode {
    static let limiter = AsyncSemaphore(value: DropboxInternalConstants.thumbnailDecodeConcurrency)
}
