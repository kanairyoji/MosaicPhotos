import Foundation
@testable import AutoAlbumCore

/// 検索品質評価のコーパス（COCO val2017 のラベルから合成）。
///
/// なぜ COCO か: 既存の `SearchQualityTests`（Imagenette）は**肯定側の Recall** を測るもので、
/// 人物の正解ラベルが無く「〜が写っていない」の precision を評価できなかった。実障害
/// （「人が写っていない風景」に人が混ざる）を測れる正解が必要。COCO は 80 クラスの
/// 物体アノテーションを持ち person を含むので、除外条件を正解付きで評価できる。
///
/// なぜ画像を使わないか: ここで測りたいのは**解釈→接地→照合→証拠ゲート**の層であって、
/// Vision/CLIP の認識精度ではない（そちらは既存の Imagenette ハーネスが測る）。
/// 正解ラベルから台帳を合成することで、層を分離して段階ごとの寄与を測れる。
enum SearchEvalCorpus {

    /// データセットの所在（`scripts/fetch_search_eval_datasets.sh` が配置）。
    static var labelsURL: URL {
        // .../Packages/AutoAlbumCore/Tests/AutoAlbumCoreTests/x.swift → 5 つ上がリポジトリルート。
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(".search_eval/coco_val2017_labels.json")
    }

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: labelsURL.path) }

    struct Labels: Decodable {
        let classes: [String]
        let images: [String: [String: Int]]   // 画像 → クラス名 → 個数
    }

    /// 索引の網羅率（実機 diagnostics-45 の実測に合わせる）。
    /// 「未索引を『無い』と読んでしまう」誤りを再現できるよう、既定でこの偏りを入れる。
    struct Coverage {
        /// シーンタグ＋humanCount（夜間タグ付けパス）。実機は約 86%。
        var tags: Double = 0.86
        /// 顔スキャン（facenet パイプライン）。実機は約 11%。
        var faces: Double = 0.11
        static let device = Coverage()
        /// 全件索引済み（上限性能を見る用）。
        static let complete = Coverage(tags: 1, faces: 1)
    }

    /// 合成したコーパス一式。
    struct Corpus {
        var photos: [EnrichedPhoto]
        /// シーンタグ台帳（refKey → タグ）。未索引の写真は**キーごと存在しない**。
        var tags: [String: [String]]
        /// Vision 上半身検出の人数（refKey → 人数）。未索引は存在しない。
        var humanCounts: [String: Int]
        /// 顔スキャンの実測（refKey → 顔数）。未スキャンは存在しない。
        var faceCounts: [String: Int]
        /// 笑顔の実測（refKey → 笑顔の顔数）。**顔スキャンと同じ網羅率**（同じ写真だけキーが在る）。
        var smileCounts: [String: Int]
        /// 命名済み人物（「X の Y」複合クエリ用・S15）。previewInterpretation の namedPeople に渡す。
        var namedPeople: [String]
        /// 正解: 人物名 → その人が写っている refKey 集合（決定的に合成・EnrichedPhoto.people にも焼く）。
        var truthPerson: [String: Set<String>]
        /// 美的スコア台帳（タグ付けと同じ網羅率＝Vision 一括パスで同時計測されるため）。
        var aesthetics: [String: Double]
        /// 正解（refKey → 実際に写っているクラス→個数）。評価専用でパイプラインには渡さない。
        var truth: [String: [String: Int]]
        /// 属性の正解（評価専用）。
        var truthSmiling: Set<String>
        var truthChild: Set<String>
        /// 美的スコアの真値（全写真・網羅率の影響を受けない正解定義用）。
        var truthAesthetics: [String: Double]
    }

    /// 決定的な疑似乱数（0..<1）。refKey から作るのでシャッフル不要・再実行で同じ結果になる。
    private static func deterministicUnit(_ key: String, salt: UInt64) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603 &+ salt
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Double(hash % 1_000_000) / 1_000_000.0
    }

    static func load(coverage: Coverage = .device) throws -> Corpus {
        let data = try Data(contentsOf: labelsURL)
        let labels = try JSONDecoder().decode(Labels.self, from: data)

        var photos: [EnrichedPhoto] = []
        var tags: [String: [String]] = [:]
        var humanCounts: [String: Int] = [:]
        var faceCounts: [String: Int] = [:]
        var smileCounts: [String: Int] = [:]
        var aesthetics: [String: Double] = [:]
        var truth: [String: [String: Int]] = [:]
        var truthPerson: [String: Set<String>] = ["山田太郎": [], "鈴木花子": []]
        var truthSmiling = Set<String>()
        var truthChild = Set<String>()
        var truthAesthetics: [String: Double] = [:]
        photos.reserveCapacity(labels.images.count)

        // 撮影日は決定的に散らす（日付条件つきクエリのため）。基準日 2024-01-01。
        let base = Date(timeIntervalSince1970: 1_704_067_200)

        for stem in labels.images.keys.sorted() {
            let counts = labels.images[stem]!
            let refKey = "L-coco-\(stem)"
            truth[refKey] = counts

            let dayOffset = Int(deterministicUnit(refKey, salt: 1) * 730)   // 2 年ぶん
            // 命名済み人物（S15・「X の Y」複合クエリ用）: 人物写真の一部へ決定的に割り当てる。
            // 実機の「命名済み顔クラスタ」に相当（EnrichedPhoto.people に焼き込み＝検索の照合先）。
            var names: [String] = []
            if (counts["person"] ?? 0) > 0 {
                if deterministicUnit(refKey, salt: 9) < 0.25 { names.append("山田太郎") }
                if deterministicUnit(refKey, salt: 10) < 0.20 { names.append("鈴木花子") }
            }
            for n in names { truthPerson[n, default: []].insert(refKey) }
            photos.append(EnrichedPhoto(
                id: refKey,
                captureDate: base.addingTimeInterval(TimeInterval(dayOffset) * 86_400),
                latitude: nil, longitude: nil, placeName: nil, people: names))

            // --- 属性の真値（S10・ADR-103）。人物写真の一部が「笑顔」「子供」を持ち、
            //     美的スコアは全写真に真値がある（索引の網羅率とは独立に定義する）。
            let personCount = counts["person"] ?? 0
            let isSmiling = personCount > 0 && deterministicUnit(refKey, salt: 6) < 0.4
            let isChild = personCount > 0 && deterministicUnit(refKey, salt: 7) < 0.3
            let aestheticScore = deterministicUnit(refKey, salt: 8) * 1.1 - 0.2   // -0.2〜0.9
            if isSmiling { truthSmiling.insert(refKey) }
            if isChild { truthChild.insert(refKey) }
            truthAesthetics[refKey] = aestheticScore

            // --- シーンタグ台帳（+ humanCount + 美的スコア）。網羅率ぶんだけ索引済みにする ---
            if deterministicUnit(refKey, salt: 2) < coverage.tags {
                // ⚠️ 実機のシーンタグは**物体検出ではなく場面分類**なので、写っている人を
                //    タグとして出さないことが多い。ここでは正解クラスをタグ化しつつ、
                //    person だけは 3 割しかタグに出さない（＝タグだけでは人の有無を判定できない
                //    という現実を再現する）。humanCount は上半身検出なので別途正確に入れる。
                var t = counts.keys.filter { $0 != "person" }.sorted()
                if counts["person"] != nil, deterministicUnit(refKey, salt: 3) < 0.3 {
                    t.append("person")
                }
                // 子供が写っている写真は（タグ付け済みなら）child タグが付く想定。
                if isChild { t.append("child") }
                tags[refKey] = t
                humanCounts[refKey] = counts["person"] ?? 0
                // 美的スコアは Vision 一括パス（タグ付け）で同時計測される＝同じ網羅率。
                aesthetics[refKey] = aestheticScore
            }

            // --- 顔スキャン（網羅率が低い）。笑顔はこのパスの実測 ---
            if deterministicUnit(refKey, salt: 4) < coverage.faces {
                faceCounts[refKey] = counts["person"] ?? 0
                smileCounts[refKey] = isSmiling ? max(1, personCount / 2) : 0
            }
        }

        return Corpus(photos: photos, tags: tags, humanCounts: humanCounts,
                      faceCounts: faceCounts,
                      smileCounts: smileCounts,
                      namedPeople: ["山田太郎", "鈴木花子"], truthPerson: truthPerson,
                      aesthetics: aesthetics, truth: truth,
                      truthSmiling: truthSmiling, truthChild: truthChild,
                      truthAesthetics: truthAesthetics)
    }
}
