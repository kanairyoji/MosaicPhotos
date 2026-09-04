import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// 「なぜ合流しないか」の説明が、実際の割り当て規則と同じ結論になること（ADR-135）。
///
/// ⚠️ ここがずれると**デバッグ表示が嘘をつく**——チューニングの土台が崩れるので、
/// 説明側（純関数）と実装側（`FaceClustering.assign`）の両方を同じ入力で突き合わせる。
@Suite("判定の内訳（説明）")
struct FaceDecisionExplainTests {

    private let settings = FaceDecisionSettings(
        threshold: 0.50, baseThreshold: 0.50, assignMargin: 0.05,
        sizeAdaptiveMarginMax: 0.10, matureCount: 11,
        negativeSameThreshold: 0.55, mergeBandFloor: 0.40)

    @Test("サイズ適応マージンの式が FaceClustering と一致する")
    func sizeMarginMatchesClustering() {
        var clustering = FaceClustering(threshold: 0.50)
        clustering.sizeAdaptiveMarginMax = 0.10
        clustering.sizeAdaptiveMatureCount = 11
        for count in [1, 2, 5, 10, 11, 40] {
            #expect(abs(settings.sizeMargin(forCount: count)
                        - clustering.sizeMargin(forCount: count)) < 0.0001,
                    "count=\(count) で説明と実装がずれている")
        }
    }

    @Test("小さい相手は上乗せで届かない（素のしきい値は超えている）")
    func blockedBySizeMargin() {
        // count=1 → 上乗せ 0.10 → 実効 0.60。0.55 は素の 0.50 を超えるが届かない。
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.55, targetCount: 1), settings: settings)
        #expect(v == .blockedBySizeMargin(required: 0.60))
    }

    @Test("成熟した相手には上乗せ無しで入る")
    func joinsMatureCluster() {
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.55, targetCount: 40), settings: settings)
        #expect(v == .joins)
    }

    @Test("1 位と 2 位が紛らわしいとマージンゲートで止まる")
    func blockedByMargin() {
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.62, targetCount: 40, runnerUpSimilarity: 0.60),
            settings: settings)
        #expect(v == .blockedByMargin(gap: 0.62 - 0.60))
    }

    @Test("負例・同一写真・別名は理由が分かれて出る")
    func explicitBlockers() {
        #expect(FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.7, targetCount: 40, negativeRejected: true),
            settings: settings) == .blockedByNegative)
        #expect(FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.7, targetCount: 40, sharesPhoto: true),
            settings: settings) == .samePhoto)
        #expect(FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.7, targetCount: 40, nameConflict: true),
            settings: settings) == .differentNames)
    }

    @Test("しきい値未満は「届かない」")
    func belowThreshold() {
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.30, targetCount: 40), settings: settings)
        #expect(v == .belowThreshold(required: 0.50))
    }

    /// 説明と実装の突き合わせ: 同じ 2 クラスタ構成で `assign` の結果と結論が一致する。
    @Test("説明の結論が assign の実際の挙動と一致する")
    func matchesActualAssign() {
        // 成熟クラスタ（12 顔）と小クラスタ（1 顔）を作り、両方に 0.55 で似た顔を入れる。
        var clustering = FaceClustering(threshold: 0.50)
        clustering.sizeAdaptiveMarginMax = 0.10
        clustering.sizeAdaptiveMatureCount = 11
        for i in 0..<12 { _ = clustering.assign(faceID: "m\(i)", embedding: [1, 0, 0]) }
        _ = clustering.assign(faceID: "s0", embedding: [0, 1, 0])
        // fixture の前提: 成熟クラスタ 12 顔・小クラスタ 1 顔。
        #expect(clustering.clusters.count == 2)
        #expect(clustering.clusters[0].count == 12)
        #expect(clustering.clusters[1].count == 1)

        // 小クラスタにだけ cos 0.55 で似ている顔（成熟側とは 0.2）。
        let probe: [Float] = FaceClustering.normalized([0.2, 0.55, 0.81])
        let simSmall = FaceClustering.dot(probe, clustering.clusters[1].centroid)
        let verdict = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: simSmall, targetCount: 1), settings: settings)
        let assigned = clustering.assign(faceID: "probe", embedding: probe)
        // 説明が「上乗せで入らない」と言うなら、実際にも小クラスタへは入らない。
        if case .blockedBySizeMargin = verdict {
            #expect(assigned != clustering.clusters[1].id)
        } else {
            Issue.record("fixture: 上乗せで弾かれる位置になっていない（sim=\(simSmall)）")
        }
    }

    /// 内訳レポートの「間違い候補」＝重心から遠い順のメンバー（ADR-137）。
    /// 近傍（他人との距離）だけでは、**内側に紛れ込んだ顔**は見つからない。
    @Test("重心から外れた顔が間違い候補の先頭に出る")
    func outliersSurfaceContamination() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<10 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [DetectedFaceSignal(
                                    boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                                    embedding: ClipMath.encodeHalf([1, Float(i) * 0.005, 0, 0]),
                                    quality: 0.9)])
        }
        // 混入 1 枚（本人とは cos 0.52＝合流はするが明らかに外れている）。
        await store.recordScan(refKey: "L-x", faces: [DetectedFaceSignal(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            embedding: ClipMath.encodeHalf([0.52, 0, 0.854, 0]), quality: 0.9)])
        let map = await store.memberRefKeysByCluster()
        guard let aID = map.first(where: { $0.value.contains("L-a0") })?.key else {
            Issue.record("fixture: 人物が作れていない"); return
        }
        // 前提: 混入が同じ人物に入っている（入っていないと何も検証していない）。
        #expect(map[aID]?.contains("L-x") == true)

        guard let report = await store.decisionReport(clusterID: aID) else {
            Issue.record("レポートが作れていない"); return
        }
        #expect(report.outlierStatus == .computed)
        #expect(report.outliers.first?.refKey == "L-x", "混入が先頭に出ていない")
        // 本人の顔より明確に低い（＝並べ替えが効いている）。
        let ownMin = report.outliers.filter { $0.refKey != "L-x" }.map(\.similarity).min() ?? 1
        #expect((report.outliers.first?.similarity ?? 1) < ownMin)
    }


    /// ⚠️ 空リストの理由を UI が言い分けられること（ADR-145）。
    /// 「候補が無い」と「計算していない」を混ぜると、画面から消えた理由が分からない。
    @Test("大きな人物でもページで読み、上位 N 件は全体の中で正しい")
    func outlierStatusExplainsEmptyList() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<6 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [DetectedFaceSignal(
                                    boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                                    embedding: ClipMath.encodeHalf([1, Float(i) * 0.005, 0]),
                                    quality: 0.9)])
        }
        let map = await store.memberRefKeysByCluster()
        guard let aID = map.first(where: { $0.value.contains("L-a0") })?.key else {
            Issue.record("fixture: 人物が作れていない"); return
        }
        // 前提: 6 枚の人物。
        #expect(map[aID]?.count == 6)

        // ⚠️ 人物の大きさで諦めない（実フィードバック「顔が N 枚あり、未確認と出る」）。
        // ページ（2 件）を跨いで読んでも、上位 `limit` 件が**全体の中で**似ている度の低い順になること。
        let computed = await store.outlierFaces(clusterID: aID, centroid: [1, 0, 0],
                                                threshold: 0.5, limit: 3, pageSize: 2)
        #expect(computed.status == .computed)
        #expect(computed.faces.count == 3, "limit 件に絞られていない")
        let sims = computed.faces.map(\.similarity)
        #expect(sims == sims.sorted(), "似ている度の昇順になっていない: \(sims)")
        // 全件を 1 ページで読んだ結果と一致する（ページ分割で取りこぼしていない）。
        let whole = await store.outlierFaces(clusterID: aID, centroid: [1, 0, 0],
                                             threshold: 0.5, limit: 3, pageSize: 1000)
        #expect(computed.faces.map(\.faceID) == whole.faces.map(\.faceID),
                "ページを跨ぐと結果が変わる")

        // 顔が無い人物は「顔なし」。
        let empty = await store.outlierFaces(clusterID: 9999, centroid: [1, 0, 0], threshold: 0.5)
        #expect(empty.status == .noMembers)
    }
}
