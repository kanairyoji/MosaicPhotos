import Foundation
import MosaicSupport
import Testing
@testable import AutoAlbumCore

/// 家族共有の取り込み・輸出の**規模退行**（ADR-119）。
///
/// ⚠️ 共有の反映は 1 回あたり最大 500 枚、夜間タガーの採用は 512 件ページで呼ばれる。
/// ここが 1 枚ずつ引くと、共有を使うたびに数百〜千の往復が走る。
/// 同じ引数で呼ばれる兄弟（`TagStore` の tags / ocrTexts / humanCounts / aesthetics）は
/// 最初から 1 回のまとめ引きで、**ここだけが揃っていなかった**。
///
/// ⚠️ **件数だけを検証しても意味がない**（レビュー指摘）。取得結果の件数は 1 枚ずつ引く
/// 実装でも同じになるので、実装を戻してもテストは通ってしまう。**発行回数**を数える。
@Suite("共有の輸出入（規模）", .serialized)
struct ShareExportScaleTests {

    /// 埋め込み **と** enrichment 行を持つストアを作る。
    ///
    /// ⚠️ enrichment を作らないと `adoptImportedEmbeddings` は**常に空**を返す（採用は
    /// enrichment 行がある写真だけ）。最初の版はこれを忘れており、採用処理が全面的に
    /// 壊れていても通るテストになっていた（レビュー指摘）。FaceCore で踏んだ
    /// 「fixture が意図した状態になっていない」と同じ罠。
    private func makeStore(photos: Int, withEnrichment: Bool = true) async -> AutoAlbumStore {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        if withEnrichment {
            await store.upsert((0..<photos).map {
                EnrichedPhoto(id: "L-\($0)", captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                              latitude: nil, longitude: nil, placeName: nil)
            })
        }
        _ = await store.upsertImportedEmbeddings((0..<photos).map {
            (refKey: "L-\($0)", vectorHalf: Data(repeating: UInt8($0 % 251), count: 32))
        })
        return store
    }

    private func keys(_ n: Int) -> [String] { (0..<n).map { "L-\($0)" } }

    /// 対象処理を 1 回走らせ、その間に発行された fetch 回数を返す。
    private func fetchCount(_ body: () async -> Void) async -> Int {
        PerfTrace.setEnabledForTesting(true)
        _ = PerfTrace.takeCounts()
        await body()
        let counts = PerfTrace.takeCounts()
        PerfTrace.setEnabledForTesting(false)
        return counts["autoAlbumStore.fetch"] ?? 0
    }

    @Test("埋め込みの取り出しは枚数に比例して fetch しない")
    func embeddingsHalfIsBatched() async {
        let store = await makeStore(photos: 400)

        let smallCount = await fetchCount { _ = await store.embeddingsHalf(forRefKeys: keys(50)) }
        let largeCount = await fetchCount { _ = await store.embeddingsHalf(forRefKeys: keys(400)) }

        #expect(smallCount > 0, "計測できていない（カウンタが動いていない）")
        #expect(largeCount <= smallCount * 2,
                """
                枚数 8 倍で fetch が \(smallCount) → \(largeCount) 回に増えた。
                共有の反映は 1 回あたり最大 500 枚で、そのたびに往復する。
                """)

        // 取りこぼしていないことも確かめる（回数だけ見ると「引かなければ速い」で通る）。
        #expect(await store.embeddingsHalf(forRefKeys: keys(400)).count == 400)
    }

    @Test("取り込み済みの採用も枚数に比例して fetch しない")
    func adoptIsBatched() async {
        let store = await makeStore(photos: 400)

        let smallCount = await fetchCount { _ = await store.adoptImportedEmbeddings(refKeys: keys(50)) }
        let largeCount = await fetchCount { _ = await store.adoptImportedEmbeddings(refKeys: keys(400)) }

        #expect(smallCount > 0)
        #expect(largeCount <= smallCount * 2,
                "枚数 8 倍で fetch が \(smallCount) → \(largeCount) 回に増えた")
    }

    /// 採用が**実際に効いている**こと。空集合でも `count <= n` は通るので、
    /// 返値そのものと副作用（`sceneTagged`）を確かめる。
    @Test("採用は対象を返し、処理済みの印を立てる")
    func adoptMarksSceneTagged() async {
        let store = await makeStore(photos: 30)

        let adopted = await store.adoptImportedEmbeddings(refKeys: keys(30))

        #expect(adopted == Set(keys(30)), "採用されていない（空集合でも通るテストになっていた）")
        let tagged = await store.sceneTaggedRefKeysForTesting()
        #expect(tagged.isSuperset(of: Set(keys(30))), "処理済みの印が立っていない＝夜間に再解析する")
    }

    /// enrichment が無い写真は採用しない（夜間タガーが対象から外すのは enrichment がある分だけ）。
    @Test("enrichment が無ければ採用しない")
    func adoptSkipsWithoutEnrichment() async {
        let store = await makeStore(photos: 30, withEnrichment: false)
        #expect(await store.adoptImportedEmbeddings(refKeys: keys(30)).isEmpty)
    }

    @Test("分割は件数に比例した往復にならない")
    func chunkingIsBounded() {
        // 400 件ずつに切るので、往復は「件数 ÷ 400」。件数に比例はしない。
        #expect(AutoAlbumStore.refKeyChunks(Array(repeating: "x", count: 1)).count == 1)
        #expect(AutoAlbumStore.refKeyChunks((0..<1200).map { "L-\($0)" }).count == 3)
        #expect(AutoAlbumStore.refKeyChunks([]).isEmpty)
    }

    @Test("重複した refKey は 1 回だけ引く")
    func duplicateKeysAreCollapsed() {
        let chunks = AutoAlbumStore.refKeyChunks(Array(repeating: "L-1", count: 500))
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 1, "同じキーを何度も引いている")
    }
}
