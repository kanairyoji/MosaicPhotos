import CoreGraphics
import Foundation

/// 顔解析用（1024px）クラウド画像の**使い捨てバッチ置き場**（ADR-90）。
///
/// 顔解析には 1024px が要るが（256px では到達率 3.8%）、68,200 枚ぶんをディスクに置くと
/// 5.9GB になる。そこで **1 バッチぶんだけメモリに持ち、使ったら捨てる**。
/// 表示用の 256px キャッシュ（`DropboxCacheStore`）は従来どおり別経路で、ここは触らない。
///
/// 流れ: `FaceTagger` のバッチ開始 → `warmUp`（バッチ取得・25 枚/リクエスト）→ ここへ格納 →
/// `detectFaces` が 1 枚ずつ `take` して消費（取り出したら破棄＝常駐を増やさない）。
actor CloudAnalysisImageCache {
    /// 取り置きの上限（バッチサイズの数倍あれば十分。取りこぼしても単発取得にフォールバックする）。
    private static let capacity = 64

    private var images: [String: CGImage] = [:]
    /// 追加順（上限超過で古い順に捨てる）。
    private var order: [String] = []

    func store(_ image: CGImage, for path: String) {
        if images[path] == nil { order.append(path) }
        images[path] = image
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    /// 取り出して**同時に破棄**する（1 枚 1024px は数 MB あるので抱え続けない）。
    func take(_ path: String) -> CGImage? {
        guard let image = images.removeValue(forKey: path) else { return nil }
        order.removeAll { $0 == path }
        return image
    }

    func removeAll() {
        images.removeAll()
        order.removeAll()
    }
}
