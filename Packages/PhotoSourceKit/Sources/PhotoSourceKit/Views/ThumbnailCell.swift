#if canImport(UIKit)
import SwiftUI

/// グリッドの 1 セル。確定した正方形サイズ `side` を受け取り、サムネイルを
/// 正方形にセンタークロップして表示する。
struct ThumbnailCell<Store: PhotoStore>: View {
    let store: Store
    let item: Store.Item
    /// セルの一辺（pt）。呼び出し側が GeometryReader から算出した確定値を渡す。
    /// セル自身がこの正方形フレームを持つことで、(1) LazyVGrid/LazyVStack が行高を
    /// 推定せず正確なコンテンツ高を持てる（スクロールジャンプ防止）、
    /// (2) 画像を正方形にセンタークロップできる。
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            // 下地兼プレースホルダ（読み込み前・万一の余白の背景）
            Color(uiColor: .secondarySystemBackground)
            if let image {
                // ★ 正方形センタークロップ（背景: サムネイル仕様）
                //   Dropbox の get_thumbnail / PhotoKit のサムネイルは、元画像の縦横比を
                //   保持した非正方形（例: 96x128 の縦長 / 128x96 の横長）で返ってくる。
                //   このグリッドは正方形セル前提なので、scaledToFill で正方形セル(side×side)を
                //   埋めるよう拡大し（アスペクト比は維持＝歪ませない）、はみ出した上下または
                //   左右を .clipped() で切り取ってセンタークロップする。
                //   ※ かつてコンテナを .aspectRatio(1, .fit) で正方形化していたが、内側の
                //     scaledToFill（画像の自然比）と競合してコンテナが画像の縦横比に
                //     引きずられ、非正方形表示＝レイアウト崩れになっていた。確定サイズの
                //     .frame(width:height:) + .clipped() に統一して競合を排除している。
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .task(id: item.id, priority: .userInitiated) {
            image = nil
            let scale = UIScreen.main.scale
            // サムネイル取得サイズはセルの実ピクセルサイズ（side × 画面倍率）に合わせる。
            let targetSize = CGSize(width: side * scale, height: side * scale)
            image = await store.thumbnail(for: item, targetSize: targetSize)
        }
    }
}
#endif
