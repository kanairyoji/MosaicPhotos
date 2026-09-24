import Foundation
import Testing
@testable import MosaicSupport

/// ⚠️ ADR-223 は「窓の終わりに手放す／前面では手放さない」と決めたが、**前面で放置され続けた
/// 場合**を見ていなかった。検索を 1 回すれば CLIP テキスト塔（実測 footprint 505MB）が載り、
/// あとは critical 圧迫か背面化まで載りっぱなしになる（常駐メモリの棚卸し）。
/// ここはその穴だけを埋める線引きで、**再ロードが 10〜35 秒**という前提を壊さないことが肝。
@Suite("使っていないモデルを手放す線引き")
struct ModelIdlePolicyTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test("線を越えていれば手放す")
    func releasesWhenIdleLongEnough() {
        #expect(ModelIdlePolicy.shouldRelease(lastUse: ago(301), now: now,
                                              idleSeconds: 300, analysisRunning: false))
    }

    @Test("ちょうど線上でも手放す（境界を含む）")
    func releasesExactlyAtBoundary() {
        #expect(ModelIdlePolicy.shouldRelease(lastUse: ago(300), now: now,
                                              idleSeconds: 300, analysisRunning: false))
    }

    /// ⚠️ ここが本命。検索して結果を眺めている数分で手放すと、次の検索が 35 秒待ちになる。
    @Test("線の手前では手放さない")
    func keepsWhenRecentlyUsed() {
        #expect(!ModelIdlePolicy.shouldRelease(lastUse: ago(299), now: now,
                                               idleSeconds: 300, analysisRunning: false))
    }

    /// ⚠️ 走っている解析から取り上げると、その場で再ロードが始まり、ANE ゲートの中なので
    /// ほかの推論も巻き添えで止まる。どれだけ放置されていても走っていれば手放さない。
    @Test("解析が走っている間は、どれだけ放置されていても手放さない")
    func neverReleasesWhileAnalysisRuns() {
        #expect(!ModelIdlePolicy.shouldRelease(lastUse: ago(10_000), now: now,
                                               idleSeconds: 300, analysisRunning: true))
    }

    /// ⚠️ 一度も使っていない＝そもそも載っていない。手放しても何も減らず、
    /// 5 秒刻みのアイドル監視から呼ばれるので診断ログだけが埋まる。
    @Test("一度も使っていなければ手放さない（ログを埋めない）")
    func noReleaseWhenNeverUsed() {
        #expect(!ModelIdlePolicy.shouldRelease(lastUse: nil, now: now,
                                               idleSeconds: 300, analysisRunning: false))
    }

    /// 時計が巻き戻った（時刻変更・NTP 補正）ときに、未来の記録で手放さないこと。
    @Test("最後の利用が未来でも手放さない")
    func noReleaseWhenClockWentBackwards() {
        #expect(!ModelIdlePolicy.shouldRelease(lastUse: now.addingTimeInterval(60), now: now,
                                               idleSeconds: 300, analysisRunning: false))
    }

    /// ⚠️ 既定値そのものを固定する。短くすると「検索 → 眺める → もう一度検索」で
    /// 再ロード（10〜35 秒）を踏むので、**変えるときは気づけるように**しておく。
    @Test("既定の線は 5 分")
    func defaultIsFiveMinutes() {
        #expect(ModelIdlePolicy.idleSeconds == 300)
    }
}
