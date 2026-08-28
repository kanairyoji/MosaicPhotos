import CoreGraphics
import CryptoKit
import MosaicSupport
import SwiftUI
import UIKit

// MARK: - Face avatar image (統一コンポーネント＋メモリキャッシュ)

/// 顔クロップ画像の統一ビュー。ピープルのカルーセル・代表写真ピッカー・顔の管理・付け替え先一覧の
/// 5 箇所で同型の「placeholder + `.task { loadFaceAvatar(...) }`」が重複していたのを 1 つに集約する。
/// 形（円/角丸/矩形）とサイズは呼び出し側が `frame` / `clipShape` で決める（本体はクロップ画像のみ）。
///
/// 表示のたびに PHImageManager からフル画像を取得→顔クロップし直すのはスクロールで体感が悪いため、
/// 小さな `NSCache` を挟む（キー: refKey+box+maxPixel。メモリ圧迫時は NSCache が自動破棄）。
struct FaceAvatarImage: View {
    let refKey: String?
    let box: CGRect?
    var maxPixel: CGFloat = 400
    /// 読込前・失敗時のプレースホルダ（既定: person アイコン）。
    var placeholderIcon: String = "person.fill"

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let displayed {
                Image(uiImage: displayed).resizable().scaledToFill()
            } else {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        // 代表写真(cover)変更で box/refKey が変われば再読込される（キーに両方含む）。
        .task {
            image = await FaceAvatarCache.load(refKey: refKey, box: box, maxPixel: maxPixel)
            guard image == nil else { return }
            // ⚠️ **温めただけで終わりにしない**（実フィードバック）。クラウド写真のサムネが
            // まだ手元に無いときは `loadFaceAvatar` が取得を予約して nil を返す。`.task` は
            // 一度きりなので、そのままだと**人型アイコンのまま永久に変わらない**——セルが
            // 作り直される（スクロールアウト→復帰）と出る、という報告はこれ。
            // 取得を待つのではなく、**届いたか安く見に行く**（キャッシュ参照だけ）。
            // 画面外になれば `.task` ごとキャンセルされるので、見えていないものは追わない。
            for delay in FaceAvatarCache.retryDelays {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                image = await FaceAvatarCache.load(refKey: refKey, box: box, maxPixel: maxPixel)
                if image != nil { return }
            }
        }
        // ⚠️ キーが変わったら **@State ごと作り直す**。`.task(id:)` だけだと SwiftUI は
        // 同じビューを再利用するため、次の読み込みが終わるまで `image` に**前の顔が残る**。
        // 人物レビューでは質問文だけ先に切り替わり、古い顔を見たまま答えてしまう実害があった。
        .id(cacheKey)
    }

    /// 表示する画像。`image` は新しいキーでは必ず nil から始まる（`.id` で作り直すため）ので、
    /// メモリキャッシュにある分は同フレームで出す＝キャッシュ済みでもちらつかせない。
    private var displayed: UIImage? {
        image ?? FaceAvatarCache.peek(refKey: refKey, box: box, maxPixel: maxPixel)
    }

    private var cacheKey: String { FaceAvatarCache.key(refKey: refKey, box: box, maxPixel: maxPixel) }
}

/// 顔クロップ画像のキャッシュ（メモリ＋ディスク）。`loadFaceAvatar`（PHImageManager 取得＋クロップ）の前段。
/// ディスク層があるので再起動後もフル画像の再取得・再クロップをしない（カルーセルの初期表示が速い）。
enum FaceAvatarCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200   // 顔クロップは小さい（数十KB）ので件数上限のみで十分
        return c
    }()

    private static let diskDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("FaceAvatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 未取得のときに見に行き直す間隔（秒）。
    ///
    /// クラウドのサムネは低優先で温めるため、届くまでに数秒かかる。**間隔を広げながら**
    /// 数回だけ見に行く（合計約 20 秒）。取得を待つのではなくキャッシュを覗くだけなので安い。
    /// 打ち切るのは、届かないものを無限に追うと画面外の分まで抱え続けるため
    /// （届かない＝回線ポリシーで止まっている等。次に表示されたときに改めて取りに行く）。
    static let retryDelays: [Double] = [0.4, 0.8, 1.5, 2.5, 4, 5, 6]

    static func key(refKey: String?, box: CGRect?, maxPixel: CGFloat) -> String {
        let b = box.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-"
        return "\(refKey ?? "-")|\(b)|\(Int(maxPixel))"
    }

    private static func fileURL(for key: String) -> URL {
        // キーには "/" 等が含まれるためハッシュ名にする。⚠️ Swift の Hasher はシードが実行ごとに
        // 変わり再起動でヒットしなくなるため、安定な SHA256 を使う。
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(name).jpg")
    }

    /// メモリ層だけを同期で引く（描画中に使える＝キャッシュ済みならプレースホルダを挟まない）。
    static func peek(refKey: String?, box: CGRect?, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(refKey: refKey, box: box, maxPixel: maxPixel) as NSString)
    }

    /// 先読み（人物レビューの次カードなど）。メモリにあれば何もしない。
    static func prefetch(refKey: String?, box: CGRect?, maxPixel: CGFloat) {
        guard peek(refKey: refKey, box: box, maxPixel: maxPixel) == nil else { return }
        Task { _ = await load(refKey: refKey, box: box, maxPixel: maxPixel) }
    }

    static func load(refKey: String?, box: CGRect?, maxPixel: CGFloat) async -> UIImage? {
        let keyString = key(refKey: refKey, box: box, maxPixel: maxPixel)
        let k = keyString as NSString
        if let hit = cache.object(forKey: k) { return hit }

        // ディスクヒット（読み込み・デコードはメイン外）。顔アバターはカルーセルで大量に生成される
        // バルク処理なので、低優先レーン（同時数制限＋スクロール中は譲る）＋ .utility QoS で走らせる
        // （提案1/2/5）。ユーザーが待つ主写真ではないので UI に譲って構わない。
        let url = fileURL(for: keyString)
        let fromDisk = await Task.detached(priority: .utility) { () -> UIImage? in
            await HeavyImageLane.run {
                guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
                return img.preparingForDisplay() ?? img
            }
        }.value
        if let fromDisk {
            cache.setObject(fromDisk, forKey: k)
            return fromDisk
        }

        guard let image = await HeavyImageLane.run(yieldToUI: true, {
            await loadFaceAvatar(coverRefKey: refKey, box: box, maxPixel: maxPixel)
        }) else { return nil }
        cache.setObject(image, forKey: k)
        Task.detached(priority: .utility) {
            if let data = image.jpegData(compressionQuality: 0.85) { try? data.write(to: url) }
        }
        return image
    }
}
