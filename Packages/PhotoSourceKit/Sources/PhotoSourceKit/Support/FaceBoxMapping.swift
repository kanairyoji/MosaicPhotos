import CoreGraphics

/// グリッドセル（中央の正方形トリミング表示）へ顔矩形を重ねるための座標変換（純ロジック）。
///
/// グリッドのサムネイルは aspect-fill の正方形＝**元画像の中央正方形だけ**が見えている。
/// 顔矩形は元画像基準の Vision 正規化座標（原点左下）なので、元画像のアスペクト比を使って
/// 「表示されている正方形クロップ」の単位座標（原点左上）へ変換する必要がある。
public enum FaceBoxMapping {
    /// Vision 正規化矩形（原点左下・元画像基準）→ 中央正方形クロップの単位座標（原点左上）。
    /// クロップで半分以上欠ける顔は描かない（端に枠の切れ端だけ残ると紛らわしい）。
    /// - Parameter aspectRatio: 元画像の 幅/高さ。不明なら 1（クロップ補正なし）を渡す。
    public static func squareCropUnitRects(visionBoxes: [CGRect],
                                           aspectRatio: CGFloat) -> [CGRect] {
        let r = aspectRatio > 0 ? aspectRatio : 1
        let cropW: CGFloat = min(1, 1 / r)   // クロップ領域（元画像の正規化単位・中央寄せ）
        let cropH: CGFloat = min(1, r)
        let x0 = (1 - cropW) / 2
        let y0 = (1 - cropH) / 2             // 中央クロップは上下対称なので top 原点でも同値
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var out: [CGRect] = []
        for b in visionBoxes {
            let topY = 1 - b.origin.y - b.height   // 原点左下 → 左上
            let rect = CGRect(x: (b.origin.x - x0) / cropW,
                              y: (topY - y0) / cropH,
                              width: b.width / cropW,
                              height: b.height / cropH)
            guard rect.width > 0, rect.height > 0 else { continue }
            let visible = rect.intersection(unit)
            guard !visible.isNull,
                  visible.width * visible.height >= 0.5 * rect.width * rect.height else { continue }
            out.append(visible)
        }
        return out
    }
}
