import CoreGraphics
import Foundation
import Testing
@testable import AutoAlbumCore

/// 顔認識フェーズ1（ADR-54）: clusterAll 衛生修正・マルチクロップ平均・
/// 同一写真 cannot-link・共起 notSame・統合サジェスト帯域拡張。
@Suite("FacePhase1 (cannot-link + co-occurrence + multi-crop)", .serialized)
struct FacePhase1Tests {

    private func signal(_ v: [Float], quality: Float = 1) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    // MARK: - ① clusterAll 衛生修正

    @Test("clusterAll は qualityFloor と qualities を尊重する")
    func clusterAllRespectsQuality() {
        let faces: [(faceID: String, embedding: [Float])] = [
            ("good1", [1, 0, 0]), ("good2", [1, 0.02, 0]), ("blurry", [1, 0.01, 0]),
        ]
        // blurry は品質 0.2 < floor 0.4 → クラスタに入らない。
        let clusters = FaceClustering.clusterAll(faces, threshold: 0.5,
                                                 qualityFloor: 0.4,
                                                 qualities: ["blurry": 0.2])
        #expect(clusters.count == 1)
        #expect(clusters[0].count == 2)
        #expect(!clusters[0].faceIDs.contains("blurry"))
    }

    // MARK: - ④ マルチクロップ平均（純関数）

    @Test("averagedEmbedding は要素平均→再正規化・次元不一致は nil")
    func averagedEmbedding() {
        let avg = FaceClustering.averagedEmbedding([[1, 0, 0], [0, 1, 0]])
        #expect(avg != nil)
        // (0.5,0.5,0) を正規化 → (0.707, 0.707, 0)
        #expect(abs(avg![0] - 0.7071) < 1e-3)
        #expect(abs(avg![1] - 0.7071) < 1e-3)
        #expect(abs(FaceClustering.dot(avg!, avg!) - 1) < 1e-4)   // 単位ベクトル
        // 1 本だけなら正規化のみ。
        let single = FaceClustering.averagedEmbedding([[3, 4, 0]])
        #expect(abs(single![0] - 0.6) < 1e-4)
        // 次元不一致・空は nil。
        #expect(FaceClustering.averagedEmbedding([[1, 0], [1, 0, 0]]) == nil)
        #expect(FaceClustering.averagedEmbedding([]) == nil)
    }

    // MARK: - A. 同一写真 cannot-link

    @Test("同一写真の 2 顔は同一埋め込みでも別クラスタになる")
    func samePhotoCannotLink() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 1 枚の写真に「同じ埋め込み」の顔が 2 つ（双子・誤検出想定）。
        await store.recordScan(refKey: "L-twins", faces: [signal([1, 0, 0]), signal([1, 0, 0])])
        // 従来は両方が同じクラスタに入った。cannot-link で 2 クラスタに分かれる。
        let boxes0 = await store.faceBoxes(refKey: "L-twins", clusterID: 0)
        let boxes1 = await store.faceBoxes(refKey: "L-twins", clusterID: 1)
        #expect(boxes0.count == 1)
        #expect(boxes1.count == 1)
    }

    @Test("別写真の同一人物は従来どおり合流する（cannot-link の過剰適用なし）")
    func differentPhotosStillMerge() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1)
        #expect(people.first?.count == 3)
    }

    // MARK: - B. 共起 notSame（統合サジェスト抑制）

    @Test("3 枚以上一緒に写る 2 クラスタは統合サジェストに出ない")
    func coOccurrenceSuppressesMergeSuggestion() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 兄弟想定: 類似度 ≈ 0.40（帯域内）の 2 人が同じ写真に 3 回一緒に写る。
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0.4, 0.917, 0]   // cos ≈ 0.40
        for i in 0..<3 {
            await store.recordScan(refKey: "L-both\(i)", faces: [signal(a), signal(b)])
        }
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        #expect(!items.contains { if case .samePerson = $0 { return true }; return false })
    }

    @Test("共起なしの帯域内ペアは従来どおりサジェストされる")
    func nonCoOccurringPairStillSuggested() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 {
            await store.recordScan(refKey: "L-p\(i)", faces: [signal([1, 0, 0.01 * Float(i)])])
        }
        for i in 0..<3 {
            await store.recordScan(refKey: "L-q\(i)", faces: [signal([0.4, 0.917, 0])])
        }
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        #expect(items.contains { if case .samePerson = $0 { return true }; return false })
    }
}
