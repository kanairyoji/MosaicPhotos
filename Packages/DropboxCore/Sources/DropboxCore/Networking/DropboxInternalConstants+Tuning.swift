import Foundation
import MosaicSupport

/// 性能チューニングの定数（サムネのバッチ並行・キャッシュ容量・デコード並列・JPEG 品質）。
/// 「実機計測を見て調整する値」をここに集約する（API URL やプロトコル定数とは分けて、
/// チューニング時に触る箇所をまとめる）。本体宣言は `DropboxInternalConstants.swift`。
extension DropboxInternalConstants {

    // MARK: - Thumbnail batch（並行・チャンク・デバウンス）

    static let thumbnailBatchChunkSize = 25
    /// バッチ（get_thumbnail_batch）リクエストの同時実行数。直列だと表示枚数増加時に
    /// ネットワーク往復が積み上がって遅いため、複数バッチを並行させて取得を高速化する。
    /// ※ CPU/メモリではなく Dropbox のレート制限（429）で決まる値なので固定（ユーザー設定）にする。
    static let maxConcurrentThumbnailRequests = 4
    static let thumbnailBatchDebounceNs: UInt64 = 30_000_000   // 30 ms

    // MARK: - Cache 容量・デコード並列（DropboxCacheStore）

    static let defaultThumbnailByteLimit = 50 * 1_024 * 1_024    // 50 MB
    static let defaultFullImageByteLimit = 200 * 1_024 * 1_024   // 200 MB
    /// サムネのメモリ層（NSCache）の上限。実デコードサイズでコスト計上する（128px≈64KB）。
    /// **端末のメモリ予算から算出**する（固定値だと低RAM機でjetsam・高RAM機で取りこぼし）。
    /// 圧迫時の動的縮小は MemoryPressureMonitor / MemoryImageCache が担う（ベース＝ここ・二段構え）。
    static let thumbnailMemoryCostLimit = MemoryBudget.thumbnailCostLimit(budget: MemoryBudget.availableBytes())
    /// 件数上限はコスト上限から導く（≈64KB/枚）。最低 800 枚は確保。
    static let thumbnailMemoryCountLimit = max(800, thumbnailMemoryCostLimit / 65_536)
    /// 圧迫時にサムネメモリ層を絞る下限。コスト上限の半分（残数が少ないと再デコードが多発するため）。
    static let thumbnailMemoryPressureFloor = thumbnailMemoryCostLimit / 2
    /// サムネの**ディスク**デコード（読込＋強制デコード）の同時実行上限。デコード自体は ~3ms と軽く、
    /// 待ちの大半はディスク I/O とキュー（実機ログで diskHit ~775ms＝大半がこの順番待ち）。
    /// コア数の2倍程度まで上げて行列を浅くする。ネット応答デコードはバッチ並行数
    /// （maxConcurrentThumbnailRequests）で既に有界なので**本セマフォは通さない（分離）**。
    static let thumbnailDecodeConcurrency = max(6, ProcessInfo.processInfo.activeProcessorCount * 2)

    // MARK: - JPEG compression quality

    static let thumbnailJPEGQuality: CGFloat = 0.85
    static let fullImageJPEGQuality: CGFloat = 0.9
}
