import Foundation
import Testing
@testable import AutoAlbumCore

/// 増分再評価（Phase 2）の純ロジック：スコアプールのマージとメンバー選定。
/// フル評価と同じカットオフ規則（floor / top−margin / 上位 K）を増分でも適用することを固定する。
@Suite("AIAlbum incremental (mergePool / memberKeys)")
struct AIAlbumIncrementalTests {

    @Test("mergePool は新規スコアを合流し、上限を超えたら上位だけ残す")
    func mergeAndTrim() {
        let existing = ["a": Float(0.5), "b": Float(0.4)]
        let merged = AIAlbumSearcher.mergePool(existing, adding: ["c": 0.6, "b": 0.45])
        #expect(merged["c"] == 0.6)
        #expect(merged["b"] == 0.45)   // 新しいスコアで上書き
        #expect(merged["a"] == 0.5)

        // 上限テスト：poolLimit+50 件を入れると上位 poolLimit 件だけ残る。
        var big: [String: Float] = [:]
        for i in 0..<(AIAlbumSearcher.poolLimit + 50) { big["p\(i)"] = Float(i) }
        let trimmed = AIAlbumSearcher.mergePool([:], adding: big)
        #expect(trimmed.count == AIAlbumSearcher.poolLimit)
        #expect(trimmed["p\(AIAlbumSearcher.poolLimit + 49)"] != nil)   // 最高スコアは残る
        #expect(trimmed["p0"] == nil)                                    // 最低スコアは落ちる
    }

    @Test("memberKeys はフル評価と同じカットオフ（top−margin と floor の大きい方）を適用する")
    func memberCutoff() {
        // top=0.50 → cutoff = max(0.20, 0.50-0.06) = 0.44
        let pool: [String: Float] = ["top": 0.50, "near": 0.45, "border": 0.44, "below": 0.43, "far": 0.10]
        let keys = AIAlbumSearcher.memberKeys(fromPool: pool)
        #expect(Set(keys) == Set(["top", "near", "border"]))
        // スコア降順で並ぶ。
        #expect(keys.first == "top")
    }

    @Test("memberKeys は相対バンド（top−margin）のみ・score<=0 は落とす（フロア廃止）")
    func memberRelativeBand() {
        // 絶対フロアは廃止（ADR-24）。top=0.15 → cutoff=0.09 → 両方入る（審査層が刈る）。
        let pool: [String: Float] = ["a": 0.15, "b": 0.10]
        #expect(Set(AIAlbumSearcher.memberKeys(fromPool: pool)) == Set(["a", "b"]))
        // score<=0（無関係）は常に落ちる。
        #expect(AIAlbumSearcher.memberKeys(fromPool: ["x": -0.1, "y": 0.0]).isEmpty)
    }

    @Test("memberKeys は上位 K で打ち切る")
    func memberTopK() {
        var pool: [String: Float] = [:]
        for i in 0..<(AIAlbumSearcher.maxResults + 20) { pool["p\(i)"] = 0.9 }   // 全員同点＝全員 cutoff 内
        #expect(AIAlbumSearcher.memberKeys(fromPool: pool).count == AIAlbumSearcher.maxResults)
    }

    @Test("空プールは空を返す")
    func emptyPool() {
        #expect(AIAlbumSearcher.memberKeys(fromPool: [:]).isEmpty)
        #expect(AIAlbumSearcher.mergePool([:], adding: [:]).isEmpty)
    }
}
