import CoreGraphics
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

/// 顔クロップ画像のメモリキャッシュ。`loadFaceAvatar`（PHImageManager 取得＋クロップ）の前段。
enum FaceAvatarCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200   // 顔クロップは小さい（数十KB）ので件数上限のみで十分
        return c
    }()

    static func key(refKey: String?, box: CGRect?, maxPixel: CGFloat) -> String {
        let b = box.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-"
        return "\(refKey ?? "-")|\(b)|\(Int(maxPixel))"
    }

    static func load(refKey: String?, box: CGRect?, maxPixel: CGFloat) async -> UIImage? {
        let k = key(refKey: refKey, box: box, maxPixel: maxPixel) as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let image = await loadFaceAvatar(coverRefKey: refKey, box: box, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: k)
        return image
    }
}
