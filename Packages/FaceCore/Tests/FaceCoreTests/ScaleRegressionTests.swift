import CoreGraphics
import Foundation
import MosaicSupport
import PerceptionCore
import Testing
@testable import FaceCore

/// **規模退行テスト**（ADR-119）。
///
/// ⚠️ なぜ要るか: 1 日で 8 件の性能バグを踏んだ（18 秒・27.8 秒のハング、1GB でのクラッシュ）。
/// すべて同じ形だった——**「1 回ぶんに見える呼び出し」が、実はライブラリ規模に比例していた**。
///
///   `items.first { $0.id == x }`      → 全走査（しかも id は毎回 String を作る）
///   クラスタごとに `faces(inCluster:)` → クラスタ数ぶんの fetch（1,316 回）
///   対ごとに「別人」記録を舐める        → 対 × 記録数の内積（52 万 × R）
///
/// どれも**書いた時点では正しく、速かった**。ライブラリが育って初めて表に出る。
/// だから「動くこと」のテストでは永久に捕まらない。
///
/// ここでは **時間ではなく発行回数**を検証する。時間は CI で揺れるが、回数は決定的。
/// 規模を 4 倍にして**回数が比例して増えないこと**を見れば、この形は必ず捕まる。
/// ⚠️ この Suite は**意図的に重い**（実データ規模を作るため 30 秒台）。
/// 規模を小さくすると打ち切り上限を跨がず、「上限が効いているのか元から少ないのか」を
/// 区別できなくなる——実際、最初は 12/48 人で書いて**素通ししていた**。
@Suite("規模退行（回数がライブラリ規模に比例しないこと）", .serialized)
struct ScaleRegressionTests {

    /// 人物 N 人・1 人 3 枚のストアを作る。
    ///
    /// ⚠️ 埋め込みは**直交**させる（人物ごとに別の次元へ 1.0）。最初は角度をずらした 3 次元の
    /// ベクトルで作ったが、隣どうしの類似度が 0.93 になり統合しきい値（0.5）を超えて
    /// **全員が 1 クラスタに合流**していた——N を増やしてもクラスタが増えず、
    /// 規模テストとして何も見ていなかった。作った規模は必ず `clusterCount` で確かめる。
    private func makeStore(people: Int) async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for person in 0..<people {
            var vector = [Float](repeating: 0, count: people)
            vector[person] = 1                       // 直交＝別人として必ず分かれる
            for shot in 0..<3 {
                let signal = DetectedFaceSignal(
                    boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                    embedding: ClipMath.encodeHalf(vector), quality: 0.9)
                await store.recordScan(refKey: "L-p\(person)-\(shot)", faces: [signal])
            }
        }
        return store
    }

    /// 実際にできたクラスタ数（fixture が意図した規模になっているかの確認用）。
    private func clusterCount(_ store: FaceStore) async -> Int {
        await store.clusterCountsForTesting().count
    }

    /// 対象処理を 1 回走らせ、その間に発行された fetch 回数を返す。
    private func fetchCount(_ body: () async -> Void) async -> Int {
        PerfTrace.setEnabledForTesting(true)
        _ = PerfTrace.takeCounts()          // 直前までの分を捨てる
        await body()
        let counts = PerfTrace.takeCounts()
        PerfTrace.setEnabledForTesting(false)
        return counts["faceStore.fetch"] ?? 0
    }

    /// 1 対 1 の確認カード生成。**人物が増えても fetch 回数は増えない**こと。
    ///
    /// 直った経路: 以前はクラスタごとに 2 本（メンバー refKey ＋ 代表顔）引いており、
    /// 1,316 人で 1 画面あたり 2,632 回になっていた。
    @Test("レビュー候補の生成は人物数に比例して fetch しない")
    func reviewItemsDoesNotScaleWithPeople() async {
        // ⚠️ 規模は**打ち切り上限（`boundaryScanLimit`）を跨ぐ**ように取る。上限より小さい
        // 範囲だけで測ると、上限が効いているのか元から少ないのか区別できない。
        let small = await makeStore(people: 40)
        let large = await makeStore(people: 160)         // 4 倍

        // ⚠️ まず**規模が本当に増えているか**を確かめる（ここを外すと何も見ていないテストになる）。
        let smallPeople = await clusterCount(small), largePeople = await clusterCount(large)
        #expect(largePeople >= smallPeople * 3,
                "fixture がクラスタに分かれていない（\(smallPeople) → \(largePeople)）")

        let smallCount = await fetchCount { _ = await small.reviewItems(minFaces: 1, limit: 30) }
        let largeCount = await fetchCount { _ = await large.reviewItems(minFaces: 1, limit: 30) }
        #expect(smallCount > 0, "計測できていない（カウンタが動いていない）")
        #expect(largeCount <= smallCount * 2,
                """
                人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた。
                クラスタごとに引いていないか（1 回の射影クエリで取ってメモリで束ねる）。
                """)
    }

    /// ⚠️ **基準を絞った効果**（ADR-123）。名前を付けた数名だけを基準にするので、
    /// 無名の人物が何人増えても候補探索の fetch は増えない。
    /// ここが崩れると「人物が増えるほどレビューが遅くなる」が再発する（実フィードバック）。
    @Test("無名の人物が増えても、レビュー候補の生成は fetch が増えない")
    func reviewItemsDoesNotScaleWithUnnamedPeople() async {
        func namedPlusUnnamed(_ unnamed: Int) async -> FaceStore {
            let store = await makeStore(people: unnamed + 2)
            // 先頭 2 人にだけ名前を付ける（＝注目人物は常に 2 人）。
            for id in await store.clusterCountsForTesting().keys.sorted().prefix(2) {
                await store.rename(clusterID: id, name: "P\(id)")
            }
            return store
        }
        let small = await namedPlusUnnamed(20)
        let large = await namedPlusUnnamed(80)              // 4 倍

        let smallPeople = await clusterCount(small), largePeople = await clusterCount(large)
        #expect(largePeople >= smallPeople * 3,
                "fixture の人物が増えていない（\(smallPeople) → \(largePeople)）")

        let smallCount = await fetchCount { _ = await small.reviewItems(minFaces: 1, limit: 30) }
        let largeCount = await fetchCount { _ = await large.reviewItems(minFaces: 1, limit: 30) }
        #expect(smallCount > 0, "計測できていない（カウンタが動いていない）")
        #expect(largeCount <= smallCount,
                """
                無名の人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた。
                基準（命名済み）以外のクラスタを 1 件ずつ引いていないか。
                """)
    }

    /// 一括レビューの候補生成も同じ性質を持つこと。
    @Test("一括レビューの候補生成も人物数に比例して fetch しない")
    func batchReviewDoesNotScaleWithPeople() async {
        let small = await makeStore(people: 40)
        let large = await makeStore(people: 160)

        let smallCount = await fetchCount { _ = await small.batchReviewItem(minFaces: 1) }
        let largeCount = await fetchCount { _ = await large.batchReviewItem(minFaces: 1) }

        #expect(smallCount > 0)
        #expect(largeCount <= smallCount * 2,
                "人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた")
    }

    /// 人物一覧の読み込み（トップ画面で毎回通る）。
    @Test("人物一覧の読み込みは人物数に比例して fetch しない")
    func peopleClustersDoesNotScaleWithPeople() async {
        let small = await makeStore(people: 40)
        let large = await makeStore(people: 160)

        let smallCount = await fetchCount {
            _ = await small.peopleClusters(minFaces: 1, favoriteRefKeys: [], includeMembers: false)
        }
        let largeCount = await fetchCount {
            _ = await large.peopleClusters(minFaces: 1, favoriteRefKeys: [], includeMembers: false)
        }

        #expect(smallCount > 0)
        #expect(largeCount <= smallCount * 2,
                "人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた")
    }

    /// フル画面で写真を**開くたび**に呼ばれる経路（情報パネルの「人物」表示）。
    ///
    /// ⚠️ ここが人物数に比例すると、**写真を 1 枚開くだけで**クラスタ数ぶんの fetch が走る。
    /// 顔スキャンが進んで人物が増えるほど、写真を開くのが遅くなる。
    @Test("写真の人物名の解決は人物数に比例して fetch しない")
    func peopleNamesDoesNotScaleWithPeople() async {
        let small = await makeStore(people: 40)
        let large = await makeStore(people: 160)

        let smallPeople = await clusterCount(small), largePeople = await clusterCount(large)
        #expect(largePeople >= smallPeople * 3,
                "fixture がクラスタに分かれていない（\(smallPeople) → \(largePeople)）")

        let smallCount = await fetchCount { _ = await small.peopleNames(refKey: "L-p0-0", minFaces: 1) }
        let largeCount = await fetchCount { _ = await large.peopleNames(refKey: "L-p0-0", minFaces: 1) }

        #expect(smallCount > 0)
        #expect(largeCount <= smallCount * 2,
                """
                人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた。
                写真を 1 枚開くたびにこれが走る（情報パネルの人物表示）。
                """)
    }

    /// 夜間の再クラスタ。**利用者は待たないが、単一の `@ModelActor` を占有する**——
    /// 走っている間はピープル画面・写真の人物名がその完了まで待たされる。
    /// 占有時間そのものは処理の性質上ゼロにできないが、**無駄な往復は消しておく**。
    @Test("夜間の再クラスタは人物数に比例して fetch しない")
    func rebuildDoesNotScaleWithPeople() async {
        let small = await makeStore(people: 40)
        let large = await makeStore(people: 160)

        let smallPeople = await clusterCount(small), largePeople = await clusterCount(large)
        #expect(largePeople >= smallPeople * 3,
                "fixture がクラスタに分かれていない（\(smallPeople) → \(largePeople)）")

        let smallCount = await fetchCount { _ = await small.rebuildClusters() }
        let largeCount = await fetchCount { _ = await large.rebuildClusters() }

        #expect(smallCount > 0)
        #expect(largeCount <= smallCount * 2,
                """
                人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた。
                全顔は既にメモリにあるので、クラスタごとに引き直さないこと。
                """)
    }

    /// 命名の持ち越し（版上げ再スキャンの前に取るスナップショット）。
    @Test("命名スナップショットは人物数に比例して fetch しない")
    func namedEntriesDoNotScaleWithPeople() async {
        let small = await makeStore(people: 40)
        let large = await makeStore(people: 160)

        let smallCount = await fetchCount { _ = await small.namedClusterEntries() }
        let largeCount = await fetchCount { _ = await large.namedClusterEntries() }

        #expect(smallCount > 0)
        #expect(largeCount <= smallCount * 2,
                "人物 4 倍で fetch が \(smallCount) → \(largeCount) 回に増えた")
    }
}
