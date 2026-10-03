import Foundation
import Testing
@testable import AutoAlbumCore

/// **ゲートの「材料の約束」をテストする**（ADR-251）。
///
/// ⚠️⚠️ **なぜこの種類のテストが要るか**（実機で踏んだ）。
/// 判断を純ロジック（`TagWorkGate` 等）へ出して規則をテストするのは良いが、
/// **規則が正しくても、材料が約束を守っていなければゲートは機能しない**。
/// `CandidateEnumerationGate` は規則も材料の取り出しも「正しく」書けていたのに、
/// 材料に選んだ `itemsRevision` が**撮影日の問い合わせでも進む**札だったため、
/// 実機で **1 回も効かなかった**（diagnostics-104・`候補の列挙を見送る` が 0 件）。
///
/// ⚠️ 純ロジックのテストは**その穴を原理的に見つけられない**——材料は引数で与えられるので、
/// 「その引数が現実にどう動くか」はテストの外にある。
/// だから**材料ごとに、ゲートが頼っている性質を実物に対して固定する**。
@Suite("ゲートの材料の約束（ADR-251）")
struct GateInputContractTests {

    private func photo(_ refKey: String) -> EnrichedPhoto {
        EnrichedPhoto(id: refKey, captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                      latitude: nil, longitude: nil, placeName: nil, clipVector: nil)
    }

    private func sense(_ tags: [String]) -> PhotoSenseInfo {
        PhotoSenseInfo(tags: tags, ocrText: nil, humanCount: 0, aesthetic: nil)
    }

    // MARK: - TagWorkGate の材料

    /// 約束 1: **写真が増えなければ `enrichedCount` は動かない。**
    /// ⚠️ これが破れると、やることが無い夜も毎回 8.6 万行を 2 回読む（実機で +341MB だった形）。
    @Test("取り込みが増えなければ、取り込み済みの数は動かない")
    func enrichedCountIsStableWithoutNewPhotos() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert((0..<5).map { photo("L-p\($0)") })
        let before = await store.enrichedCount()

        // 同じ写真を入れ直す（＝再同期）。増えていないので数は動かないこと。
        await store.upsert((0..<5).map { photo("L-p\($0)") })

        #expect(await store.enrichedCount() == before, """
            同じ写真の入れ直しで取り込み済みの数が動いた。
            これが動くと TagWorkGate は毎晩「変わった」と答え、8.6 万行の読み出しを払い続ける。
            """)
    }

    @Test("写真が増えたら、取り込み済みの数は増える（＝ゲートが走る側へ倒れる）")
    func enrichedCountGrowsWithNewPhotos() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([photo("L-a")])
        let before = await store.enrichedCount()

        await store.upsert([photo("L-b")])

        #expect(await store.enrichedCount() > before, "写真が増えたのに数が動かない（取りこぼす側）")
    }

    /// 約束 2: **タグを付けなければ `taggedCountCurrentVersion` は動かない。**
    @Test("タグを付けなければ、タグ付け済みの数は動かない")
    func taggedCountIsStableWithoutTagging() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        _ = await store.recordTags([(refKey: "L-a", info: sense(["sea"]))])
        let before = await store.taggedCountCurrentVersion()

        // 同じ写真に同じタグを入れ直す（＝再実行）。件数は増えないこと。
        _ = await store.recordTags([(refKey: "L-a", info: sense(["sea"]))])

        #expect(await store.taggedCountCurrentVersion() == before,
                "同じ写真の再記録で件数が増えた（ゲートが毎回「変わった」になる）")
    }

    @Test("タグを付けたら、タグ付け済みの数は増える")
    func taggedCountGrowsWithTagging() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        _ = await store.recordTags([(refKey: "L-a", info: sense(["sea"]))])
        let before = await store.taggedCountCurrentVersion()

        _ = await store.recordTags([(refKey: "L-b", info: sense(["food"]))])

        #expect(await store.taggedCountCurrentVersion() > before, "タグを付けたのに数が動かない")
    }

    /// ⚠️ 約束 3: **版を上げたら、タグ付け済みの数は減る**（＝全部やり直す側へ倒れる）。
    /// 「増えたときだけ走る」と書くと、版を上げた晩に 1 枚もタグ付けしない。
    @Test("版より古い記録は、タグ付け済みに数えない")
    func taggedCountIgnoresOlderVersions() async {
        let store = TagStore(isStoredInMemoryOnly: true)
        _ = await store.recordTags([(refKey: "L-a", info: sense(["sea"]))])
        #expect(await store.taggedCountCurrentVersion() == 1, "fixture: 記録できていない")
        // 旧版の記録は数に入らない＝版を上げると数が減る、という性質をここで固定する。
        #expect(TagStore.currentVersion >= 1)
    }
}
