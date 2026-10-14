import Foundation
import Testing
@testable import BackupKit

/// 公開の純ロジック: シャードで束ねる・同じ中身に当たる refKey から 1 つを決定的に選ぶ。
/// 以前は `AnalysisPublisher.publish` の中に直書きで、勝つ refKey の規則にテストが無かった。
@Suite("解析の公開: シャードで束ねる・同じ中身の勝者")
struct AnalysisPublishShardingTests {

    @Test("束ねる: content_hash の先頭で分け、hash は小文字にそろえる")
    func groupsByShard() {
        let photos = [AnalysisPublisher.CloudPhoto(refKey: "C-/a.jpg", contentHash: "ABcd"),
                      AnalysisPublisher.CloudPhoto(refKey: "C-/b.jpg", contentHash: "abff"),
                      AnalysisPublisher.CloudPhoto(refKey: "L-x", contentHash: "cd00")]
        let (byShard, hashByRefKey) = AnalysisPublishPlanning.groupByShard(photos)
        let ab = ShareAnalysisData.shardName(forHash: "abcd")
        let cd = ShareAnalysisData.shardName(forHash: "cd00")
        #expect(ab != cd, "前提: 別のシャードに分かれる fixture")
        #expect(Set(byShard[ab] ?? []) == ["C-/a.jpg", "C-/b.jpg"])
        #expect(byShard[cd] == ["L-x"])
        #expect(hashByRefKey["C-/a.jpg"] == "abcd")
    }

    /// ⚠️ 辞書の反復順で勝者が変わると、中身が同じでも指紋が変わり毎回上げ直す。
    /// 50 個の refKey を同じ中身に当てる——「最後に見たもの」にしても通る確率を 1/50 にする。
    @Test("同じ中身に当たる refKey は、いちばん小さいものの解析を使う")
    func smallestRefKeyWins() {
        let refKeys = (0..<50).map { String(format: "C-/p%02d.jpg", $0) }
        var entries: [String: ShareAnalysisData.Entry] = [:]
        var hashByRefKey: [String: String] = [:]
        for refKey in refKeys {
            entries[refKey] = ShareAnalysisData.Entry(tags: [refKey])
            hashByRefKey[refKey] = "same"
        }
        entries["C-/other.jpg"] = ShareAnalysisData.Entry(tags: ["other"])
        hashByRefKey["C-/other.jpg"] = "otherhash"
        entries["C-/unknown.jpg"] = ShareAnalysisData.Entry(tags: ["x"])   // hash が分からない

        let out = AnalysisPublishPlanning.entriesByHash(entries, hashByRefKey: hashByRefKey)
        #expect(out.count == 2, "hash の分からない refKey を載せた")
        #expect(out["same"]?.tags == ["C-/p00.jpg"])
        #expect(out["otherhash"]?.tags == ["other"])
    }
}
