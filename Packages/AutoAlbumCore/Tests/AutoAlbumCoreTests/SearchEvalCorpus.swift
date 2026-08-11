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
        /// VLM キャプション（お気に入り限定）。実機は 1% 未満。
        var captions: Double = 0.01

        static let device = Coverage()
        /// 全件索引済み（上限性能を見る用）。
        static let complete = Coverage(tags: 1, faces: 1, captions: 1)
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
        /// VLM キャプション。未生成は存在しない。
        var captions: [String: String]
        /// 正解（refKey → 実際に写っているクラス→個数）。評価専用でパイプラインには渡さない。
        var truth: [String: [String: Int]]
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
        var captions: [String: String] = [:]
        var truth: [String: [String: Int]] = [:]
        photos.reserveCapacity(labels.images.count)

        // 撮影日は決定的に散らす（日付条件つきクエリのため）。基準日 2024-01-01。
        let base = Date(timeIntervalSince1970: 1_704_067_200)

        for stem in labels.images.keys.sorted() {
            let counts = labels.images[stem]!
            let refKey = "L-coco-\(stem)"
            truth[refKey] = counts

            let dayOffset = Int(deterministicUnit(refKey, salt: 1) * 730)   // 2 年ぶん
            photos.append(EnrichedPhoto(
                id: refKey,
                captureDate: base.addingTimeInterval(TimeInterval(dayOffset) * 86_400),
                latitude: nil, longitude: nil, placeName: nil))

            // --- シーンタグ台帳（+ humanCount）。網羅率ぶんだけ索引済みにする ---
            if deterministicUnit(refKey, salt: 2) < coverage.tags {
                // ⚠️ 実機のシーンタグは**物体検出ではなく場面分類**なので、写っている人を
                //    タグとして出さないことが多い。ここでは正解クラスをタグ化しつつ、
                //    person だけは 3 割しかタグに出さない（＝タグだけでは人の有無を判定できない
                //    という現実を再現する）。humanCount は上半身検出なので別途正確に入れる。
                var t = counts.keys.filter { $0 != "person" }.sorted()
                if counts["person"] != nil, deterministicUnit(refKey, salt: 3) < 0.3 {
                    t.append("person")
                }
                tags[refKey] = t
                humanCounts[refKey] = counts["person"] ?? 0
            }

            // --- 顔スキャン（網羅率が低い） ---
            if deterministicUnit(refKey, salt: 4) < coverage.faces {
                faceCounts[refKey] = counts["person"] ?? 0
            }

            // --- VLM キャプション（ごく一部） ---
            if deterministicUnit(refKey, salt: 5) < coverage.captions {
                let subjects = counts.keys.sorted().prefix(4).joined(separator: ", ")
                captions[refKey] = subjects.isEmpty ? "a photo" : "a photo of \(subjects)"
            }
        }

        return Corpus(photos: photos, tags: tags, humanCounts: humanCounts,
                      faceCounts: faceCounts, captions: captions, truth: truth)
    }
}
