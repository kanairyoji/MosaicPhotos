import CoreGraphics
import Foundation

/// クラウド顔スキャンの**歩留まり実測**（ADR-89）の純ロジック：標本抽出と集計。
///
/// 背景: クラウド写真の顔スキャンは埋め込み到達率がローカル約 50% に対し **18% 以下**しかない。
/// 原因は 256px サムネに対する「顔 48px 以上」の下限（＝画面比 18.75% 必要）と推定されるが、
/// **推定のまま設計を決めない**（CLAUDE.md 性能原則）。実写真で歩留まり曲線を測って決める。
///
/// 測り方の要点: サイズごとに何度もダウンロードしない。**高解像度で 1 回だけ検出**し、
/// 各顔の正規化矩形から「サイズ S のときの顔ピクセル数 = 正規化辺 × S」を算術で出す。
/// これで 1 枚のダウンロードから全サイズの歩留まりが得られる。
public enum FaceYieldMeasurement {

    // MARK: - 標本抽出

    /// 撮影日で層化した標本抽出（純・テスト対象）。
    ///
    /// 子どもの成長のように**時期によって顔の写り方が変わる**データでは、先頭から N 枚では偏る。
    /// 撮影日順に `strata` 個の層へ等分し、各層から均等に抜く。日時不明はひとつの層として扱い、
    /// 実データでの割合ぶんだけ含める（除外すると「日時不明の写真は測れていない」偏りが残る）。
    /// - Parameter items: (識別子, 撮影日) の一覧。順不同でよい。
    public static func stratifiedSample(_ items: [(id: String, date: Date?)],
                                        sampleSize: Int,
                                        strata: Int = 20) -> [String] {
        guard sampleSize > 0, !items.isEmpty else { return [] }
        guard items.count > sampleSize else { return items.map(\.id) }

        let dated = items.compactMap { item in item.date.map { (id: item.id, date: $0) } }
            .sorted { $0.date < $1.date }
        let undated = items.filter { $0.date == nil }.map(\.id)

        // 日時不明は実データの割合ぶんだけ（少なくとも 1 枚は含める）。
        let undatedQuota = undated.isEmpty ? 0
            : max(1, Int((Double(undated.count) / Double(items.count) * Double(sampleSize)).rounded()))
        let datedQuota = max(0, sampleSize - undatedQuota)

        var picked: [String] = []
        if datedQuota > 0, !dated.isEmpty {
            let bucketCount = max(1, min(strata, dated.count))
            let perBucket = max(1, datedQuota / bucketCount)
            for b in 0..<bucketCount {
                let lo = dated.count * b / bucketCount
                let hi = dated.count * (b + 1) / bucketCount
                guard lo < hi else { continue }
                let bucket = Array(dated[lo..<hi])
                // 層の中でも等間隔に抜く（先頭固まりを避ける）。
                let take = min(perBucket, bucket.count)
                let step = max(1, bucket.count / take)
                var i = 0
                while i < bucket.count, picked.count < datedQuota {
                    picked.append(bucket[i].id)
                    i += step
                }
            }
            // 端数で足りなければ、まだ入っていないものから順に補う。
            if picked.count < datedQuota {
                let chosen = Set(picked)
                for entry in dated where !chosen.contains(entry.id) {
                    picked.append(entry.id)
                    if picked.count >= datedQuota { break }
                }
            }
        }
        // 日時不明ぶん（等間隔）。
        if undatedQuota > 0, !undated.isEmpty {
            let step = max(1, undated.count / undatedQuota)
            var i = 0
            var added = 0
            while i < undated.count, added < undatedQuota {
                picked.append(undated[i])
                i += step
                added += 1
            }
        }
        return picked
    }

    // MARK: - 観測と集計

    /// 高解像度で 1 回検出したときの 1 顔ぶんの観測値（サイズ非依存の量だけを持つ）。
    public struct FaceObservation: Sendable, Equatable {
        /// 正規化した顔矩形の短辺（0…1）。サイズ S での顔ピクセル数 = shortSide × S。
        public let normalizedShortSide: CGFloat
        /// 検出信頼度（`VNFaceObservation.confidence`）。
        public let confidence: Float
        /// Vision の顔品質（`faceCaptureQuality`）。
        public let quality: Float

        public init(normalizedShortSide: CGFloat, confidence: Float, quality: Float) {
            self.normalizedShortSide = normalizedShortSide
            self.confidence = confidence
            self.quality = quality
        }
    }

    /// 1 サイズぶんの歩留まり。
    public struct SizeYield: Sendable, Equatable {
        public let size: Int
        /// 顔ピクセル下限（`minFacePixels` 相当）ごとの通過顔数。
        public let acceptedByPixelFloor: [Int: Int]
        public init(size: Int, acceptedByPixelFloor: [Int: Int]) {
            self.size = size
            self.acceptedByPixelFloor = acceptedByPixelFloor
        }
    }

    /// 検討する顔ピクセル下限（現行 48／モデル入力 112 に対する各段階）。
    public static let pixelFloors = [32, 48, 64, 80, 96, 112]

    /// 観測から「サイズ × 顔ピクセル下限」の歩留まり表を作る（純・テスト対象）。
    /// `sizes` は正方サムネの一辺（Dropbox の w256h256 等）。
    public static func yields(observations: [FaceObservation],
                              sizes: [Int],
                              minConfidence: Float) -> [SizeYield] {
        let usable = observations.filter { $0.confidence >= minConfidence }
        return sizes.map { size in
            var byFloor: [Int: Int] = [:]
            for floor in pixelFloors {
                byFloor[floor] = usable.count {
                    $0.normalizedShortSide * CGFloat(size) >= CGFloat(floor)
                }
            }
            return SizeYield(size: size, acceptedByPixelFloor: byFloor)
        }
    }

    /// 人間が読む表（診断ログ／レポート用）。行＝サイズ、列＝顔ピクセル下限。
    public static func report(photos: Int, photosWithFace: Int,
                              observations: [FaceObservation],
                              sizes: [Int], minConfidence: Float) -> String {
        let total = observations.count
        let usable = observations.filter { $0.confidence >= minConfidence }.count
        var lines: [String] = []
        lines.append("faces/yield: photos=\(photos) withFace=\(photosWithFace) "
                     + "faces=\(total) confidenceOK=\(usable) (minConfidence=\(minConfidence))")
        lines.append("  size |" + FaceYieldMeasurement.pixelFloors.map { String(format: "%6d", $0) }.joined())
        for y in yields(observations: observations, sizes: sizes, minConfidence: minConfidence) {
            let cells = pixelFloors.map { floor -> String in
                let n = y.acceptedByPixelFloor[floor] ?? 0
                let pct = total > 0 ? Double(n) / Double(total) * 100 : 0
                return String(format: "%5.1f%%", pct)
            }.joined()
            lines.append(String(format: "%6d |", y.size) + cells)
        }
        return lines.joined(separator: "\n")
    }
}

private extension Array {
    /// 条件を満たす要素数（`filter().count` の一時配列を作らない）。
    func count(where predicate: (Element) -> Bool) -> Int {
        reduce(0) { predicate($1) ? $0 + 1 : $0 }
    }
}
