import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// クラウド顔スキャンの歩留まり実測（ADR-89）の純ロジック。
@Suite("FaceYieldMeasurement")
struct FaceYieldMeasurementTests {

    private func day(_ n: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(n) * 86_400) }

    // MARK: - 標本抽出

    @Test("母集団が標本数以下ならそのまま全部返す")
    func smallPopulationReturnsAll() {
        let items = (0..<5).map { (id: "p\($0)", date: Optional(day($0))) }
        #expect(FaceYieldMeasurement.stratifiedSample(items, sampleSize: 100).count == 5)
    }

    @Test("標本数と空入力の境界")
    func boundaries() {
        #expect(FaceYieldMeasurement.stratifiedSample([], sampleSize: 10).isEmpty)
        let items = (0..<100).map { (id: "p\($0)", date: Optional(day($0))) }
        #expect(FaceYieldMeasurement.stratifiedSample(items, sampleSize: 0).isEmpty)
    }

    /// 要点: 先頭 N 枚ではなく**時期全体**から抜けること（子どもの成長で写り方が変わるため）。
    @Test("撮影日で層化する: 標本が全期間に広がる")
    func sampleSpansWholeTimeline() {
        let items = (0..<10_000).map { (id: "p\($0)", date: Optional(day($0))) }
        let picked = Set(FaceYieldMeasurement.stratifiedSample(items, sampleSize: 200, strata: 20))
        // 期間を 10 分割し、どの区間からも採れていること。
        for segment in 0..<10 {
            let lo = segment * 1_000, hi = (segment + 1) * 1_000
            let inSegment = (lo..<hi).contains { picked.contains("p\($0)") }
            #expect(inSegment, "区間 \(segment) から 1 枚も採れていない＝偏り")
        }
    }

    @Test("撮影日不明の写真も割合ぶん含める（除外すると偏る）")
    func includesUndatedProportionally() {
        let dated = (0..<900).map { (id: "d\($0)", date: Optional(day($0))) }
        let undated = (0..<100).map { (id: "u\($0)", date: Date?.none) }
        let picked = FaceYieldMeasurement.stratifiedSample(dated + undated, sampleSize: 100)
        let undatedPicked = picked.filter { $0.hasPrefix("u") }.count
        #expect(undatedPicked >= 5 && undatedPicked <= 20, "日時不明が約 10% 含まれるべき: \(undatedPicked)")
    }

    @Test("標本数を超えない")
    func doesNotExceedSampleSize() {
        let items = (0..<10_000).map { (id: "p\($0)", date: Optional(day($0))) }
        #expect(FaceYieldMeasurement.stratifiedSample(items, sampleSize: 137).count <= 137)
    }

    @Test("重複を返さない")
    func noDuplicates() {
        let items = (0..<5_000).map { (id: "p\($0)", date: Optional(day($0))) }
        let picked = FaceYieldMeasurement.stratifiedSample(items, sampleSize: 300)
        #expect(Set(picked).count == picked.count)
    }

    // MARK: - 歩留まり集計

    private func face(_ shortSide: CGFloat, confidence: Float = 1.0)
        -> FaceYieldMeasurement.FaceObservation {
        .init(normalizedShortSide: shortSide, confidence: confidence, quality: 0.8)
    }

    /// 要点: 「サイズ S での顔ピクセル = 正規化辺 × S」という算術が正しいこと。
    /// これが成り立つので**1 回の高解像度検出**で全サイズの歩留まりが出せる。
    @Test("サイズ換算: 正規化辺 × サイズ が下限を超えた顔だけ通る")
    func pixelArithmetic() {
        // 正規化 0.1 の顔 → 256px で 25.6px、640px で 64px、1024px で 102.4px。
        let obs = [face(0.10)]
        let y = FaceYieldMeasurement.yields(observations: obs, sizes: [256, 640, 1024], minConfidence: 0.8)
        #expect(y[0].acceptedByPixelFloor[48] == 0)     // 256px: 25.6px → 48 下限に届かない
        #expect(y[1].acceptedByPixelFloor[48] == 1)     // 640px: 64px → 通る
        #expect(y[1].acceptedByPixelFloor[112] == 0)    // 640px: 112 下限には届かない
        #expect(y[2].acceptedByPixelFloor[96] == 1)     // 1024px: 102.4px → 96 は通る
        #expect(y[2].acceptedByPixelFloor[112] == 0)    // 112 には僅かに届かない
    }

    /// 実バグの状況を再現: 現行 256px＋48px 下限では、画面比 18.75% 未満の顔が全滅する。
    @Test("現行設定(256px/48px下限)は画面比 18.75% 未満の顔を全部落とす")
    func currentSettingRejectsTypicalFaces() {
        // 家族写真でよくある顔の大きさ（画面比 5〜12%）＋ たまにある大きな顔（20%）。
        let obs = [face(0.05), face(0.08), face(0.10), face(0.12), face(0.20)]
        let y = FaceYieldMeasurement.yields(observations: obs, sizes: [256], minConfidence: 0.8)
        #expect(y[0].acceptedByPixelFloor[48] == 1)   // 0.20 のみ（0.20×256=51px）
    }

    @Test("信頼度が下限未満の顔は母数から除く")
    func filtersLowConfidence() {
        let obs = [face(0.5, confidence: 0.9), face(0.5, confidence: 0.3)]
        let y = FaceYieldMeasurement.yields(observations: obs, sizes: [1024], minConfidence: 0.8)
        #expect(y[0].acceptedByPixelFloor[112] == 1)   // 低信頼の 1 件は数えない
    }

    @Test("レポートはサイズごとの行を持つ")
    func reportShape() {
        let text = FaceYieldMeasurement.report(
            photos: 100, photosWithFace: 40,
            observations: [face(0.10), face(0.25)],
            sizes: [256, 1024], minConfidence: 0.8)
        #expect(text.contains("photos=100 withFace=40 faces=2"))
        #expect(text.contains("   256 |"))
        #expect(text.contains("  1024 |"))
    }
}
