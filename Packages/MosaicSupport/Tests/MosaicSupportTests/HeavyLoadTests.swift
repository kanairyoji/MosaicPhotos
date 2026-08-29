import Foundation
import Testing
@testable import MosaicSupport

/// 起動・復帰の一括ロードの札（`HeavyLoad`）。**重ならないこと**を作る仕組みなので、
/// 「札が立つ / 外れる / 立ちっぱなしでも自動で無効になる」の 3 点を固定する。
/// ⚠️ `.serialized`: 札はプロセス共通なので、並列に走ると互いの `resetForTesting` で
/// 潰し合う（他所で実際に踏んだ形）。この Suite は順番に流す。
@Suite("一括ロードの札", .serialized)
struct HeavyLoadTests {

    private func fresh() { HeavyLoad.resetForTesting() }

    @Test("begin で立ち、end で外れる")
    func beginAndEnd() {
        fresh()
        #expect(!HeavyLoad.isInFlight())
        HeavyLoad.begin("a")
        #expect(HeavyLoad.isInFlight())
        #expect(HeavyLoad.activeLabels() == ["a"])
        HeavyLoad.end("a")
        #expect(!HeavyLoad.isInFlight())
    }

    /// ⚠️ 同じ処理が重なって走ることはある（起動直後の再構築など）。片方の終了で札が
    /// 消えると、まだ走っている方が無防備になる。
    @Test("同じラベルが重なったら、全部終わるまで札は外れない")
    func nestedSpansKeepTheFlag() {
        fresh()
        HeavyLoad.begin("merged")
        HeavyLoad.begin("merged")
        HeavyLoad.end("merged")
        #expect(HeavyLoad.isInFlight(), "1 つ終わっただけで札が外れた")
        HeavyLoad.end("merged")
        #expect(!HeavyLoad.isInFlight())
    }

    /// ⚠️ 安全弁。終了報告が来ない事故（例外経路・キャンセル）で札が残ると、背景処理が
    /// **永久に止まる**。期限を過ぎた札は数えない（`isGeneratingAlbums` と同じ処方）。
    @Test("期限を過ぎた札は無視する（背景処理を永久に止めない）")
    func staleSpansExpire() {
        fresh()
        let started = Date()
        HeavyLoad.begin("stuck", now: started)
        #expect(HeavyLoad.isInFlight(now: started.addingTimeInterval(HeavyLoad.maxSpanSeconds - 1)))
        #expect(!HeavyLoad.isInFlight(now: started.addingTimeInterval(HeavyLoad.maxSpanSeconds + 1)))
        HeavyLoad.end("stuck")
    }

    @Test("span は本体が投げても札を外す")
    func spanReleasesOnThrow() async {
        fresh()
        struct Boom: Error {}
        _ = try? await HeavyLoad.span("x") { throw Boom() }
        #expect(!HeavyLoad.isInFlight(), "throw で札が残った")
    }

    /// 一括ロード中は、背景の重い処理（トリクル・モデルのロード）が譲る。
    /// ここが繋がっていないと札を立てても何も起きない。
    @Test("札が立っている間は heavyShouldPause が true")
    @MainActor
    func gateReflectsFlag() {
        fresh()
        HeavyLoad.begin("boot")
        #expect(BackgroundYield.heavyShouldPause())
        HeavyLoad.end("boot")
    }
}
