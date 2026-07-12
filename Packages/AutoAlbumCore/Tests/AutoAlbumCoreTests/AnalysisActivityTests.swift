import Foundation
import Testing
@testable import AutoAlbumCore

// UserDefaults.standard を共有するため直列実行（並列だとパス間で干渉する）。
@Suite("AnalysisActivity (last-run timestamps)", .serialized)
struct AnalysisActivityTests {

    /// 各パスのキーは独立。テスト後に掃除する。
    private func clear() {
        for pass in AnalysisActivity.Pass.allCases {
            UserDefaults.standard.removeObject(forKey: "analysis.lastActivity.\(pass.rawValue)")
        }
    }

    @Test("未記録なら nil")
    func unsetIsNil() {
        clear()
        for pass in AnalysisActivity.Pass.allCases {
            #expect(AnalysisActivity.lastActivity(pass) == nil)
        }
        clear()
    }

    @Test("記録した時刻を読み戻せる（秒精度）")
    func recordRoundTrip() {
        clear()
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        AnalysisActivity.recordActivity(.embeddings, at: when)
        let got = AnalysisActivity.lastActivity(.embeddings)
        #expect(got != nil)
        #expect(abs((got ?? .distantPast).timeIntervalSinceReferenceDate - when.timeIntervalSinceReferenceDate) < 0.001)
        clear()
    }

    @Test("パスごとに独立して記録される")
    func passesAreIndependent() {
        clear()
        let t = Date(timeIntervalSinceReferenceDate: 900_000_000)
        AnalysisActivity.recordActivity(.faces, at: t)
        #expect(AnalysisActivity.lastActivity(.faces) != nil)
        #expect(AnalysisActivity.lastActivity(.embeddings) == nil)
        #expect(AnalysisActivity.lastActivity(.sceneTags) == nil)
        #expect(AnalysisActivity.lastActivity(.captions) == nil)
        clear()
    }

    @Test("AnalysisProgress は値を保持する")
    func progressHoldsValues() {
        let p = AnalysisProgress(total: 100, embedded: 40, sceneTagged: 70, captioned: 10)
        #expect(p.total == 100)
        #expect(p.embedded == 40)
        #expect(p.sceneTagged == 70)
        #expect(p.captioned == 10)
    }
}
