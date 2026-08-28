import Foundation
import ImageCacheKit

/// 端末写真の取得（`PHImageManager.requestImage`）の同時実行数を絞る。
///
/// ⚠️ なぜ要るか（実機 diagnostics-59・アプリが落ちた）: サムネイルを密に表示するモード
/// （15 列）へ切り替えた直後からメモリが 164MB → **1032MB** へ急増し、jetsam で落ちた。
///
/// 内訳はカウンタが示していた——10 秒間で `thumb.cacheMiss=1072`。ミス 1 件につき
/// `PHImageManager.requestImage` が 1 本走るが、**同時実行に上限が無かった**。
/// しかも取得サイズは**最低 640×640**（小さい targetSize だと一部写真で向きが狂う
/// PHImageManager の挙動を避けるための下限・実測で 640 なら解消）。
///
///     640 × 640 × 4 バイト ≒ 1.6MB／枚 × 1,000 枚同時 ≒ 1.6GB
///
/// さらに取得後 `resizedUp` がセルサイズへ縮小する際にもう 1 枚確保する。列を増やすほど
/// 可視セルと先読みが増えるので、**密にするほど落ちやすい**という形になっていた。
///
/// 取得サイズは下げられない（向きが狂う）。**同時に持つ枚数**を絞るのが正しい対処。
enum PhotoRequest {
    /// 同時に走らせる `requestImage` の本数。
    ///
    /// 1 枚あたり 1.6MB 級を抱えるので、上限がそのままメモリの山になる。
    /// I/O とデコードが主なのでコア数に比例させつつ、上限を設けて山を有界にする
    /// （16 本なら約 26MB＝安全側）。下限 4 は低コア機で流量を保つため。
    static let limiter = AsyncSemaphore(value: min(16, max(4, ProcessInfo.processInfo.activeProcessorCount * 2)))
}
