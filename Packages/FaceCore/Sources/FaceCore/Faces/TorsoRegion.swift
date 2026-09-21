import CoreGraphics
import Foundation

/// **顔の位置から胴体（服装）の領域を決める**（純ロジック・テスト対象・ADR-212）。
///
/// 座標は Vision と同じ正規化系（原点**左下**・0…1）。胴体は顔の**真下**にあるので、
/// y を顔の下端から下へ伸ばす。
///
/// ```
///        ┌─────┐          ← 顔（w × h）
///        │ 顔  │
///    ┌───┴─────┴───┐      ← 胴体: 幅 2w・高さ 2.5h を顔の中心に合わせて下へ
///    │    胴体     │
///    └─────────────┘
/// ```
///
/// ⚠️ **はみ出したら諦める**。引きの写真で人物が画面の下端に写っていると胴体はほとんど
/// 入らない。切れた胴体を無理に使うと「床」や「机」を服として比べることになる——
/// 似ていないものが似ていると出るより、**手がかりが無いと言う方が安全**。
public enum TorsoRegion {

    /// 顔の幅に対する胴体の幅の比。
    public static let widthScale: CGFloat = 2.0
    /// 顔の高さに対する胴体の高さの比。
    public static let heightScale: CGFloat = 2.5
    /// 切り取った結果、意図した面積のこれだけは残っていること。
    ///
    /// ⚠️ 低くすると「肩だけ」「背景だけ」が混ざる。CLIP は構図に敏感なので、
    /// 同じ人でも入り方が違えば似ていないと言い、別人でも同じ入り方なら似ていると言う。
    public static let minRemainingArea: CGFloat = 0.5

    /// 胴体の領域。画面外へはみ出しすぎるときは nil（＝この顔は服装の判断に参加しない）。
    public static func normalizedBox(forFace face: CGRect) -> CGRect? {
        guard face.width > 0, face.height > 0 else { return nil }
        let width = face.width * widthScale
        let height = face.height * heightScale
        let centerX = face.midX
        // 顔の下端（原点左下なので face.minY）から下へ伸ばす。
        let intended = CGRect(x: centerX - width / 2, y: face.minY - height,
                              width: width, height: height)
        let clipped = intended.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let intendedArea = intended.width * intended.height
        guard intendedArea > 0,
              (clipped.width * clipped.height) / intendedArea >= minRemainingArea else { return nil }
        return clipped
    }
}
