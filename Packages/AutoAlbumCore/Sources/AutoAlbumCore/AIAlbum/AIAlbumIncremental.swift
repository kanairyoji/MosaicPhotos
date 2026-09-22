import Foundation
import PerceptionCore

/// **増分再評価の規則**（純ロジック・テスト対象）。
///
/// 新しく埋め込まれた写真だけを採点してアルバムへ足す（`AIAlbumService.refreshIncremental`）。
/// その判断のうち、ストアにも LLM にも触らない部分をここに置く。
///
/// ⚠️ **全評価と同じ規則であること**が要（食い違うと、増分と全評価でアルバムの中身が変わる）。
/// 既知の食い違いは unresolved-problems.md「増分評価が全評価と違う規則で動いている」に 6 件ある。
/// 直すときはクエリ集ハーネスで測ってから（CLAUDE.md）。
enum AIAlbumIncremental {

    /// 評価済み件数を `adding` 枚ぶん進める。**現実の埋め込み総数で頭打ち**にする——
    /// 待機列へ戻した分を再処理すると、既に数えたアルバムで二重加算になり得るため。
    /// （既に総数を超えていたら、それより減らしはしない。）
    static func advancedEvaluatedCount(_ current: Int, adding: Int, embeddedNow: Int) -> Int {
        min(current + adding, max(current, embeddedNow))
    }

    /// ハード条件だけで判定が完結するアルバムか（ADR-109）。内容語が全部ハード接地語で、
    /// 除外も無い＝意味採点をしない。英訳文で意味採点すると「太郎」だけのアルバムに
    /// 新規の太郎写真が入らないことがあるため、全評価（`searchWithPool`）と同じく
    /// ハードを通ったものをそのまま足す。
    static func isHardOnly(_ spec: QuerySpec) -> Bool {
        let effective = spec.effectiveContentTerms
        return effective.include.isEmpty && effective.exclude.isEmpty && spec.hasHardConstraints
    }

    /// 新しい写真の採点（意味採点の経路）。
    ///
    /// 1. ハード条件（相対日付は `now` で解決）
    /// 2. 人系の除外があれば、実測の人数でハード除外（ADR-100: humanCount を主・顔スキャンを補助。
    ///    証拠が無い写真は通さない＝「無い＝いない」と読まない）
    /// 3. 意味採点（max-over-probes＋除外の相対判定・`QueryEmbedder` に一元化）
    ///
    /// - Parameter faceCounts: 人系の除外があるときだけ非 nil（無ければ 2 を飛ばす）。
    /// - Returns: ハードを通った写真と、採点できた写真の点数。
    static func scoreNewPhotos(_ photos: [EnrichedPhoto], vectors: [String: Data],
                               spec: QuerySpec, now: Date,
                               peopleMap: [String: [String]]?, signals: QuerySignals,
                               faceCounts: [String: Int]?, humanCounts: [String: Int],
                               query: QueryEmbedder.QueryVectors)
        -> (passed: [EnrichedPhoto], scores: [String: Float]) {
        var passed = QueryEvaluator.hardFilter(photos, spec: spec, now: now,
                                               peopleByRefKey: peopleMap, signals: signals)
        if let faceCounts {
            passed = passed.filter { photo in
                if let human = humanCounts[photo.id] { return human == 0 }
                if let faces = faceCounts[photo.id] { return faces == 0 }
                return false
            }
        }
        var scores: [String: Float] = [:]
        for photo in passed {
            guard let data = vectors[photo.id], let v = ClipMath.decode(data),
                  let score = QueryEmbedder.semanticScore(query, photoVector: v) else { continue }
            scores[photo.id] = score
        }
        return (passed, scores)
    }
}
