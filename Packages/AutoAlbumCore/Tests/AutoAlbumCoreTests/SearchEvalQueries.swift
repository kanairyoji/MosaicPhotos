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
        /// 除外条件を含むか（証拠ゲートの対象になる＝評価の主眼）。
        var hasExclusion: Bool { !exclude.isEmpty }

        /// 正解集合（コーパスの truth から機械的に導く）。
        func groundTruth(_ truth: [String: [String: Int]]) -> Set<String> {
            var out = Set<String>()
            for (refKey, counts) in truth {
                if !include.isEmpty && !include.contains(where: { (counts[$0] ?? 0) > 0 }) { continue }
                if exclude.contains(where: { (counts[$0] ?? 0) > 0 }) { continue }
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
              englishText: "landscape", include: [], exclude: ["person"]),
        Query(id: "no-people-food", text: "人が写っていない食べ物の写真",
              englishText: "food", include: ["pizza", "cake", "sandwich", "donut", "hot dog"],
              exclude: ["person"]),
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
