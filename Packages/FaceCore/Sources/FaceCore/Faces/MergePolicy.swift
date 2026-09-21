import Foundation

/// **「この 2 つを、どこまで機械がやってよいか」を 1 つの表にしたもの**
/// （純ロジック・テスト対象・ADR-213）。
///
/// ## なぜ出したか
/// 「どれくらい似ていたら何をするか」の判断が 5 か所に散っていた——
/// 自動で寄せるバー（`FaceTuning.autoAbsorbBar`）、チェック済みで見せるバー
/// （`autoSuggestBar`）、尋ねる下限（`mergeBandFloor`）、断片の大きさの上限と
/// 1 位 2 位の差（`FaceStore+Absorb` の静的定数）、同一写真の共起回数（`FaceStore`）。
/// どれも**同じ 1 本の軸**（似ている度合い）の上の目盛りなのに、別々の場所で別々に読まれ、
/// 「この帯は何をする帯なのか」を通して見られる場所がなかった。
///
/// ⚠️ 値そのものは `face-accuracy.md` の実測で決まっている（ADR-153/154/155/162）。
/// ここは**値を集めて意味を与えるだけ**で、1 つも動かしていない。
///
/// ## 帯（下から）
/// ```
///           ask 下限            preselect              absorb
///   ──────────┼────────────────────┼──────────────────────┼────────→ 似ている
///    無視     │      尋ねる        │  チェック済みで見せる │ 断片なら自動で寄せる
/// ```
/// **人物どうしは、どれだけ似ていても自動で結合しない**（ADR-153）。自動になるのは
/// 「断片（1〜2 枚・無名・アンカーなし）を、確立した人物へ寄せる」ときだけ——
/// 失敗の代償が小さいから（1 枚外せば直る）。人物どうしを機械が混ぜると取り返しが付かない。
public enum MergePolicy {

    /// 機械が取ってよい行動。
    public enum Action: String, Sendable, Equatable {
        /// 自動で寄せる（断片 → 確立した人物のときだけ）。
        case absorb
        /// **チェックを付けた状態で**見せる（結合はユーザーの一手が要る・ADR-153）。
        case preselect
        /// 「同じ人ですか？」と尋ねる。
        case ask
        /// 何もしない（尋ねても当たらない帯）。
        case ignore
    }

    /// 帯の境目。プロファイル（`FaceTuning`）と校正後のしきい値から作る。
    public struct Bars: Sendable, Equatable {
        public let absorb: Float
        public let preselect: Float
        public let askFloor: Float
        public init(absorb: Float, preselect: Float, askFloor: Float) {
            self.absorb = absorb
            self.preselect = preselect
            self.askFloor = askFloor
        }
    }

    public static func bars(tuning: FaceTuning, threshold: Float) -> Bars {
        Bars(absorb: tuning.autoAbsorbBar, preselect: tuning.autoSuggestBar,
             askFloor: tuning.mergeBandFloor(threshold: threshold))
    }

    /// - Parameter isFragmentToPerson: 小さい方が「断片」で、相手が確立した人物か。
    ///   **自動で寄せてよいのはこの形のときだけ**（ADR-153/154）。
    public static func action(similarity: Float, isFragmentToPerson: Bool,
                              bars: Bars) -> Action {
        if similarity < bars.askFloor { return .ignore }
        if isFragmentToPerson && similarity >= bars.absorb { return .absorb }
        if similarity >= bars.preselect { return .preselect }
        return .ask
    }

    // MARK: - 構造の定数（似ている度合いではなく「形」で決まるもの）

    /// 「断片」とみなす最大の写真枚数（ADR-154/155）。
    ///
    /// ⚠️ **上げない**。LFW 実測で、上限を 5 枚に上げると発火した吸収は**全部間違い**だった
    /// （大きい断片ほど発火し、しかも間違える）。2 枚以下はどのバーでも一度も誤らなかった。
    public static let absorbMaxPhotos = 2

    /// 吸収先として認める最小の写真枚数（＝確立した人物）。
    public static let absorbTargetMinPhotos = FaceClustering.matureCountDefault

    /// 吸収で要求する 1 位と 2 位の差。**紛らわしければ寄せない**（兄弟・親子の取り違え対策）。
    public static let absorbMargin: Float = 0.05

    /// 1 回の夜間処理で寄せる上限（処理を有界にする）。
    public static let absorbLimitPerRun = 500

    /// 同じ写真にこれ以上の回数いっしょに写っていたら「別人」とみなす（ADR-54）。
    /// 同一人物は 1 枚に 1 回しか写れない。偶発の誤検出 1〜2 回は許す。
    public static let coOccurrenceNotSame = 3
}
