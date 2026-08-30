import Foundation

/// 顔クラスタリングのしきい値をユーザー修正から**自動校正**する純ロジック（B1・ADR-46）。
///
/// 修正は「同一人物ペア（統合承認・顔の確認）」と「別人ペア（付け替え・統合拒否）」という
/// ラベル付きの類似度サンプルを生む。固定 0.45 の代わりに、正例と負例を最もよく分離する
/// しきい値を選ぶ＝ユーザーのライブラリの顔分布（家族の似方・撮影条件）に自動適応する。
/// サンプルが少ないうちは既定値のまま（過学習防止）。
public enum FaceCalibration {

    /// 既定しきい値（facenet 正規化埋め込みの手動調整値・校正前のフォールバック）。
    public static let defaultThreshold: Float = 0.45
    /// 校正に必要な最小サンプル数（正例・負例それぞれ）。未満なら既定値のまま。
    public static let minSamples = 8

    /// 校正してよい最低の**分離度**（AUC）。これ未満なら校正しない（ADR-149）。
    ///
    /// ⚠️ 実測（実機 9,973 件）で、顔レベルの正例（confirm）と負例（reassign）の
    /// **AUC は 0.472**＝コイン投げ以下だった。重なった 2 分布から「最もよく分ける境界」を
    /// 探すと、件数の多い側（負例は正例の 5.5 倍）を全部落とす端（0.974）が最適解になり、
    /// 可動域の上限に張り付く——**ユーザーが直すほど厳しくなる**という逆向きの動きの正体。
    /// 分離できないデータからは境界を作らない。
    public static let minSeparability = 0.60

    /// 校正結果の可動域（異常なサンプルでしきい値が暴れないための安全域）。
    ///
    /// ⚠️ 上限は 0.70 → **0.55**（ADR-68 追補）。実機で修正 130 件から校正値が **0.60** まで上がり、
    /// サイズ適応マージン（最大 +0.10）と積み上がって**実効 0.70**になっていた。0.70 は
    /// FG-NET で純度 0.907／再現率 0.342＝「混ざらないが全く集まらない」領域で、実測の
    /// 単発クラスタ 1,170 個・最大クラスタ 15 顔（9,446 枚スキャン）はこれで説明がつく。
    /// データセット計測: しきい値 0.60→0.55 で FG-NET 家族3人の分裂 5.0→2.3・F1 0.503→0.791、
    /// LFW（901人）は F1 0.904→0.906 でほぼ中立＝**両立する**。
    /// 校正そのものは維持する（ユーザーの修正は引き続き反映される）が、分裂側へ振り切らせない。
    public static let clampRange: ClosedRange<Float> = 0.35...0.55

    /// 正例と負例がどれだけ分離しているか（AUC＝順位で測るので尺度に依らない）。
    /// 1.0 = 完全分離、0.5 = 無関係、0.5 未満 = 逆転。
    ///
    /// ⚠️ **重みも効かせる**（確度＝ADR-68 追補6）。件数の多い低確度サンプルが分離度の判断まで
    /// 支配すると、「校正してよいか」の門番が確度の低い回答で決まってしまう。
    public static func separability(positive: [(Float, Double)],
                                    negative: [(Float, Double)]) -> Double {
        guard !positive.isEmpty, !negative.isEmpty else { return 0.5 }
        let sortedNegative = negative.sorted { $0.0 < $1.0 }
        // 負例の重みの累積（value 未満／以下 の重み合計を二分探索で引く）。
        var prefix: [Double] = [0]
        prefix.reserveCapacity(sortedNegative.count + 1)
        for entry in sortedNegative { prefix.append(prefix[prefix.count - 1] + entry.1) }
        let negativeWeight = prefix[prefix.count - 1]
        func weight(strictlyBelow value: Float) -> Double {
            var low = 0, high = sortedNegative.count
            while low < high {
                let mid = (low + high) / 2
                if sortedNegative[mid].0 < value { low = mid + 1 } else { high = mid }
            }
            return prefix[low]
        }
        func weight(atMost value: Float) -> Double {
            var low = 0, high = sortedNegative.count
            while low < high {
                let mid = (low + high) / 2
                if sortedNegative[mid].0 <= value { low = mid + 1 } else { high = mid }
            }
            return prefix[low]
        }
        var area = 0.0
        var positiveWeight = 0.0
        for (value, w) in positive {
            let below = weight(strictlyBelow: value)
            let equal = weight(atMost: value) - below
            area += w * (below + equal / 2)
            positiveWeight += w
        }
        guard positiveWeight > 0, negativeWeight > 0 else { return 0.5 }
        return area / (positiveWeight * negativeWeight)
    }

    /// 重みなし版（テスト・分析用）。
    public static func separability(positive: [Float], negative: [Float]) -> Double {
        separability(positive: positive.map { ($0, 1.0) }, negative: negative.map { ($0, 1.0) })
    }

    /// 正例（同一人物ペアの類似度）と負例（別人ペアの類似度）から最適しきい値を求める。
    /// 分類精度（正例 ≥ t かつ 負例 < t の数）を最大化する境界を選び、同点なら既定値に近い方。
    public static func calibratedThreshold(positive: [Float], negative: [Float],
                                           fallback: Float = defaultThreshold) -> Float {
        calibratedThreshold(positive: positive.map { ($0, 1) },
                            negative: negative.map { ($0, 1) }, fallback: fallback)
    }

    /// **確度で重み付けした**校正（ADR-68 追補6）。
    ///
    /// 同じ「はい」でも判断材料の量で信頼度は違う。1 対 1 の確認（2 枚を並べて尋ねる）は
    /// 材料が揃っているが、まとめて確認（小さなアバターを一覧から選ぶ）は取り違えが起こりやすく、
    /// **1 セッションで数百件入る**ため、等重みだと校正がそれ一色に染まる（実機で修正 216→611 件の
    /// 大半が一括レビュー由来だった）。件数ではなく**重みの合計**で最適境界を選ぶ。
    ///
    /// - Parameters:
    ///   - positive/negative: (類似度, 重み) の並び。重みは `FaceCorrection.confidence`。
    public static func calibratedThreshold(positive: [(Float, Double)],
                                           negative: [(Float, Double)],
                                           fallback: Float = defaultThreshold,
                                           clamp: ClosedRange<Float> = clampRange,
                                           minSeparability: Double = minSeparability) -> Float {
        // サンプル数の足切りは**重み合計**で見る（低確度ばかりで校正を動かさない）。
        let posWeight = positive.reduce(0.0) { $0 + $1.1 }
        let negWeight = negative.reduce(0.0) { $0 + $1.1 }
        guard posWeight >= Double(minSamples), negWeight >= Double(minSamples) else { return fallback }
        // ⚠️ **分離できないデータからは境界を作らない**（ADR-149）。重なった分布で
        // 「最もよく分ける境界」を探すと、件数の多い側を全部落とす端が答えになる。
        guard separability(positive: positive, negative: negative) >= minSeparability else {
            return fallback
        }

        // ⚠️ **候補ごとに全サンプルを走査しない**（ADR-142）。以前は候補しきい値ごとに
        // `positive.filter { … }` を作っていたため O(n²)＋毎回の配列確保で、修正が 8,868 件に
        // 育った実機では 1 回の校正が秒単位になっていた（しかも修正のたびに再計算される）。
        // 並べ替えて一度だけ舐める（結果は完全に同じ・`FaceCalibrationTests` で総当たりと突合）。
        //
        //   score(t) = Σ{正例: sim ≥ t} + Σ{負例: sim < t}
        //
        // 候補 t を昇順に見ると、正例側は「t 未満になった分」が減り、負例側は「t 未満に入った分」が
        // 増える——どちらも単調なので、走査位置を進めながら累積で更新できる。
        let pos = positive.sorted { $0.0 < $1.0 }
        let neg = negative.sorted { $0.0 < $1.0 }
        var candidates = Array(Set(positive.map(\.0)).union(neg.map(\.0)))
        candidates.sort()
        var best = fallback
        var bestScore = -Double.greatestFiniteMagnitude
        var posBelow = 0.0, negBelow = 0.0
        var pi = 0, ni = 0
        for t in candidates {
            while pi < pos.count, pos[pi].0 < t { posBelow += pos[pi].1; pi += 1 }
            while ni < neg.count, neg[ni].0 < t { negBelow += neg[ni].1; ni += 1 }
            let score = (posWeight - posBelow) + negBelow
            if score > bestScore
                || (score == bestScore && abs(t - fallback) < abs(best - fallback)) {
                best = t
                bestScore = score
            }
        }
        return min(max(best, clamp.lowerBound), clamp.upperBound)
    }
}
