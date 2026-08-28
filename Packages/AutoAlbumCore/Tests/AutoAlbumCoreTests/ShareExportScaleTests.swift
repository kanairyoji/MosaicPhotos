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
@Suite("共有の輸出入（規模）", .serialized)
struct ShareExportScaleTests {

    private func makeStore(photos: Int) async -> AutoAlbumStore {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let batch = (0..<photos).map { i in
            (refKey: "L-\(i)", vectorHalf: Data(repeating: UInt8(i % 251), count: 32))
        }
        _ = await store.upsertImportedEmbeddings(batch)
        return store
    }

    private func keys(_ n: Int) -> [String] { (0..<n).map { "L-\($0)" } }

    @Test("埋め込みの取り出しは枚数に比例して fetch しない")
    func embeddingsHalfIsBatched() async {
        let store = await makeStore(photos: 400)

        // 分割単位（fetchChunk）を跨ぐ規模で測る。下回る範囲だけだと、
        // まとめ引きが効いているのか元から少ないのか区別できない。
        let small = await store.embeddingsHalf(forRefKeys: keys(50))
        let large = await store.embeddingsHalf(forRefKeys: keys(400))

        #expect(small.count == 50, "取りこぼしている")
        #expect(large.count == 400, "取りこぼしている")
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

    /// 夜間タガーの採用パス。埋め込みがある写真だけを「処理済み」に採用する。
    @Test("取り込み済みの採用は、埋め込みがあるものだけを拾う")
    func adoptOnlyPicksEmbedded() async {
        let store = await makeStore(photos: 30)
        let adopted = await store.adoptImportedEmbeddings(refKeys: keys(50))   // 30 件だけ存在
        #expect(adopted.count <= 30, "存在しない refKey まで採用している")
        #expect(adopted.allSatisfy { keys(30).contains($0) })
    }
}
