import CoreGraphics
import CryptoKit
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
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        // 代表写真(cover)変更で box/refKey が変われば再読込される（キーに両方含む）。
        .task(id: cacheKey) {
            image = await FaceAvatarCache.load(refKey: refKey, box: box, maxPixel: maxPixel)
        }
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

    static func load(refKey: String?, box: CGRect?, maxPixel: CGFloat) async -> UIImage? {
        let keyString = key(refKey: refKey, box: box, maxPixel: maxPixel)
        let k = keyString as NSString
        if let hit = cache.object(forKey: k) { return hit }

        // ディスクヒット（読み込み・デコードはメイン外）
        let url = fileURL(for: keyString)
        let fromDisk = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }.value
        if let fromDisk {
            cache.setObject(fromDisk, forKey: k)
            return fromDisk
        }

        guard let image = await loadFaceAvatar(coverRefKey: refKey, box: box, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: k)
        Task.detached(priority: .utility) {
            if let data = image.jpegData(compressionQuality: 0.85) { try? data.write(to: url) }
        }
        return image
    }
}
