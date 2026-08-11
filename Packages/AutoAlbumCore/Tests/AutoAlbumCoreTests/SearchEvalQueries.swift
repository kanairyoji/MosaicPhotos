import Foundation
@testable import AutoAlbumCore

/// 評価クエリと指標（純ロジック）。
///
/// 実障害が「除外条件つきクエリに、除外すべき写真が混ざる」＝**precision の問題**だったので、
/// Recall だけを見ていた既存ハーネスと違い **precision / recall / F1 を both 出す**。
/// 正解は COCO のラベルから機械的に決まる（人手の判断を入れない＝再実行で同じ数字になる）。
enum SearchEvalQueries {

    /// 1 クエリ。`include`/`exclude` は**正解の定義**（COCO クラス名）であって、
    /// パイプラインへ渡す語ではない。パイプラインには `text`（自然文）を渡す。
    struct Query {
        let id: String
        /// ユーザーが入力する自然文（日本語）。
        let text: String
        /// 夜間 FM 翻訳の代替（英語の意味文）。空なら決定的チャンネルのみで解く。
        let englishText: String
        /// 正解: これらのクラスのいずれかが写っている（空なら条件なし）。
        let include: [String]
        /// 正解: これらのクラスが 1 つも写っていない。
        let exclude: [String]
        /// 正解: 撮影年（日付複合クエリ用。nil なら日付条件なし）。
        var year: Int?
        /// 正解: 属性の要求（S10・ADR-103）。
        var requireSmiling = false
        var requireChild = false
        var requireBeautiful = false
        /// 正解: 子供が**写っていない**（大人は可）。人物除外の粗さの定量化用。
        var requireNoChild = false
        /// 現状の既知の限界を**定量化**するためのクエリ（マクロ平均から除外して別枠で出す）。
        /// 例: レキシコン外の語＝作成時プレビューでは立たない（夜間 FM が受け持つ）。
        var knownLimitation: String?
        /// 除外条件を含むか（証拠ゲートの対象になる＝評価の主眼）。
        var hasExclusion: Bool { !exclude.isEmpty }

        /// 正解集合（コーパスの truth から機械的に導く）。
        func groundTruth(corpus: SearchEvalCorpus.Corpus,
                         dates: [String: Date] = [:]) -> Set<String> {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            // 「綺麗」の正解 = 真値スコアの上位 20%（ADR-78 のベストショット定義と同じ）。
            let beautifulFloor = requireBeautiful
                ? PhotoQuality.adaptiveThreshold(scores: Array(corpus.truthAesthetics.values)) : 0
            var out = Set<String>()
            for (refKey, counts) in corpus.truth {
                if !include.isEmpty && !include.contains(where: { (counts[$0] ?? 0) > 0 }) { continue }
                if exclude.contains(where: { (counts[$0] ?? 0) > 0 }) { continue }
                if let year {
                    guard let date = dates[refKey],
                          calendar.component(.year, from: date) == year else { continue }
                }
                if requireSmiling, !corpus.truthSmiling.contains(refKey) { continue }
                if requireChild, !corpus.truthChild.contains(refKey) { continue }
                if requireNoChild, corpus.truthChild.contains(refKey) { continue }
                if requireBeautiful, (corpus.truthAesthetics[refKey] ?? -1) < beautifulFloor { continue }
                out.insert(refKey)
            }
            return out
        }
    }

    /// 評価クエリ集。実障害（人物除外）を中心に、汎用性を確かめるため
    /// **人物以外の除外**（犬・車・食べ物）と肯定のみのクエリも入れる。
    /// 汎用化が効いていれば人物以外でも同じだけ改善するはず＝点対応との区別がつく。
    static let all: [Query] = [
        // --- 実障害そのもの ---
        // 純粋形（肯定語なし）。人物証拠の網羅率がそのまま precision に出る＝実障害の核心。
        Query(id: "no-people-only", text: "人が写っていない写真",
              englishText: "", include: [], exclude: ["person"]),
        Query(id: "no-people", text: "人が写っていない風景",
              englishText: "landscape", include: [], exclude: ["person"],
              knownLimitation: "「風景」の展開は語彙接地が必要＝Caltech ハーネスで計測（COCO は画像が無く重心を作れない）"),
        Query(id: "no-people-food", text: "人が写っていない食べ物の写真",
              englishText: "food", include: ["pizza", "cake", "sandwich", "donut", "hot dog"],
              exclude: ["person"],
              knownLimitation: "「食べ物」の展開は語彙接地が必要＝Caltech ハーネスで計測（同上）"),
        // --- 人物以外の除外（汎用性の確認） ---
        Query(id: "no-dog", text: "犬が写っていない写真",
              englishText: "", include: [], exclude: ["dog"]),
        Query(id: "no-car", text: "車が写っていない写真",
              englishText: "", include: [], exclude: ["car"]),
        Query(id: "cat-no-dog", text: "犬が写っていない猫の写真",
              englishText: "cat", include: ["cat"], exclude: ["dog"]),
        // --- 肯定のみ（除外の変更で肯定側を壊していないかの対照） ---
        Query(id: "dog", text: "犬の写真", englishText: "dog", include: ["dog"], exclude: []),
        Query(id: "train", text: "電車の写真", englishText: "train", include: ["train"], exclude: []),
        Query(id: "pizza", text: "ピザの写真", englishText: "pizza", include: ["pizza"], exclude: []),
        Query(id: "cat", text: "猫の写真", englishText: "cat", include: ["cat"], exclude: []),
        // --- 連言（S5d の効果確認） ---
        Query(id: "no-dog-and-cat", text: "犬と猫が写っていない写真",
              englishText: "", include: [], exclude: ["dog", "cat"]),
        // --- 日付複合（ハード条件×内容語） ---
        Query(id: "dog-2024", text: "2024年の犬の写真", englishText: "dog",
              include: ["dog"], exclude: [], year: 2024),
        Query(id: "no-people-2025", text: "2025年の人が写っていない写真", englishText: "",
              include: [], exclude: ["person"], year: 2025),
        // --- S9 でレキシコンへ追補した語（以前は 0 件＝既知の限界だった） ---
        Query(id: "bus", text: "バスの写真", englishText: "bus", include: ["bus"], exclude: []),
        Query(id: "no-bus", text: "バスが写っていない写真", englishText: "", include: [], exclude: ["bus"]),
        // --- 動物の具体語（S10 レキシコン追補分） ---
        Query(id: "horse", text: "馬の写真", englishText: "horse", include: ["horse"], exclude: []),
        Query(id: "elephant", text: "象の写真", englishText: "elephant", include: ["elephant"], exclude: []),
        Query(id: "giraffe", text: "キリンの写真", englishText: "giraffe", include: ["giraffe"], exclude: []),
        Query(id: "zebra", text: "シマウマの写真", englishText: "zebra", include: ["zebra"], exclude: []),
        Query(id: "dog-or-cat", text: "犬と猫の写真", englishText: "dog and cat",
              include: ["dog", "cat"], exclude: []),
        // --- 属性条件（S10・ADR-103: 笑顔＝顔スキャン実測・綺麗＝美的スコア） ---
        Query(id: "child", text: "子供の写真", englishText: "child",
              include: [], exclude: [], requireChild: true),
        Query(id: "smiling", text: "笑っている写真", englishText: "",
              include: [], exclude: [], requireSmiling: true),
        Query(id: "smiling-child", text: "笑っている子供の写真", englishText: "child",
              include: [], exclude: [], requireSmiling: true, requireChild: true),
        Query(id: "beautiful", text: "綺麗な写真", englishText: "",
              include: [], exclude: [], requireBeautiful: true),
        Query(id: "beautiful-cat", text: "綺麗な猫の写真", englishText: "cat",
              include: ["cat"], exclude: [], requireBeautiful: true),
        Query(id: "beautiful-2024", text: "2024年の綺麗な写真", englishText: "",
              include: [], exclude: [], year: 2024, requireBeautiful: true),
        // 人物除外の粗さの定量化: 「子供がいない」は現状「人がいない」へ丸められる
        //（年齢の証拠が無く『大人だけ』を検証できないため・保守側）。
        Query(id: "no-child", text: "子供が写っていない写真", englishText: "",
              include: [], exclude: [], requireNoChild: true,
              knownLimitation: "子供除外は人物除外へ丸められる（年齢証拠なし・R が構造的に低い）"),
    ]

    // MARK: - 指標

    struct Score {
        let queryID: String
        let hasExclusion: Bool
        let truePositives: Int
        let retrieved: Int
        let relevant: Int

        var precision: Double { retrieved == 0 ? 0 : Double(truePositives) / Double(retrieved) }
        var recall: Double { relevant == 0 ? 0 : Double(truePositives) / Double(relevant) }
        var f1: Double {
            let (p, r) = (precision, recall)
            return (p + r) == 0 ? 0 : 2 * p * r / (p + r)
        }
        /// 誤って混ざった件数（実障害の直接指標）。
        var falsePositives: Int { retrieved - truePositives }
    }

    static func score(queryID: String, hasExclusion: Bool,
                      retrieved: Set<String>, relevant: Set<String>) -> Score {
        Score(queryID: queryID, hasExclusion: hasExclusion,
              truePositives: retrieved.intersection(relevant).count,
              retrieved: retrieved.count, relevant: relevant.count)
    }

    /// マクロ平均（クエリごとに等重み）。件数の多いクエリに引きずられないようにする。
    static func macro(_ scores: [Score]) -> (precision: Double, recall: Double, f1: Double) {
        guard !scores.isEmpty else { return (0, 0, 0) }
        let n = Double(scores.count)
        return (scores.reduce(0) { $0 + $1.precision } / n,
                scores.reduce(0) { $0 + $1.recall } / n,
                scores.reduce(0) { $0 + $1.f1 } / n)
    }
}
