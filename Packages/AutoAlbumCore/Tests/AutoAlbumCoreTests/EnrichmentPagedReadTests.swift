import Foundation
import Testing
@testable import AutoAlbumCore

/// **「2 列だけ」のつもりの全件 fetch が、全行を抱えていた**（ADR-246/247・diagnostics-102）。
///
/// ⚠️⚠️ ADR-236 で「`propertiesToFetch` は列を絞らない（あれはヒント）」と分かっていたのに、
/// **その誤解で書かれた既存の場所を数えなかった**。`enrichedRefKeysNewestFirst()` には
/// 「2 列だけ」、`TagStore.taggedRefKeys()` には「8 万件のタグ配列を実体化しない（射影）」と
/// 書いてあり、読む側には**軽い処理に見えていた**。実機では 2 つ続けて呼ばれて
/// **1 ステップ +341MB**（430MB → 771MB）、背面ではメモリ圧迫で 11 回落とされていた。
///
/// ⚠️ 常駐メモリはテストで測れないので、**回数で見る**（ADR-119）:
/// 「使い捨てコンテキストのページ読みを通っているか」は数えられる。
@Suite("取り込み台帳・タグ台帳の読み出しはページで送る（ADR-246）")
struct EnrichmentPagedReadTests {

    private func photo(_ refKey: String, _ date: Date?) -> EnrichedPhoto {
        EnrichedPhoto(id: refKey, captureDate: date, latitude: nil, longitude: nil,
                      placeName: nil, clipVector: nil)
    }

    private func store(_ count: Int) async -> AutoAlbumStore {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert((0..<count).map {
            photo("L-p\(String(format: "%05d", $0))",
                  Date(timeIntervalSince1970: Double(1_700_000_000 - $0 * 60)))
        })
        return store
    }

    @Test("取り込み済みの列挙は、使い捨てコンテキストのページ読みを通る")
    func enrichedEnumerationIsPaged() async {
        let store = await store(30)
        let before = await store.enrichmentPagesForTesting

        let keys = await store.enrichedRefKeysNewestFirst()

        #expect(keys.count == 30, "fixture: 取り込みが入っていない: \(keys.count)")
        #expect(await store.enrichmentPagesForTesting > before, """
            ページ読みを通っていない（このストアのコンテキストで全件 fetch している）。
            実機ではこれが 1 ステップ +341MB になり、背面でメモリ圧迫に落とされていた。
            """)
    }

    /// ⚠️ 並びを変えずに実装を替えたこと（撮影日降順・日付なしは最後）。
    /// ページはキーセット（refKey 昇順）で送るので、**読み終えてから**並べ替える必要がある。
    @Test("並びは撮影日の新しい順のまま（ページの順番が漏れていない）")
    func orderIsStillNewestFirst() async {
        let store = await store(12)

        let keys = await store.enrichedRefKeysNewestFirst()

        // fixture は i が小さいほど新しい（1_700_000_000 - i*60）。
        #expect(keys == (0..<12).map { "L-p\(String(format: "%05d", $0))" }, """
            撮影日降順になっていない（ページの順番がそのまま出ている）: \(keys.prefix(3))
            """)
    }

    /// ⚠️ 日付が無い行は最後。かつ**同じ条件なら毎回同じ並び**（実行ごとに変わると処理順が揺れる）。
    @Test("撮影日が無い写真は最後で、並びは決定的")
    func undatedGoLastDeterministically() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([photo("L-b", nil), photo("L-a", nil),
                            photo("L-dated", Date(timeIntervalSince1970: 1_700_000_000))])

        let keys = await store.enrichedRefKeysNewestFirst()

        #expect(keys == ["L-dated", "L-a", "L-b"], "日付なしが最後・決定的になっていない: \(keys)")
    }
}
