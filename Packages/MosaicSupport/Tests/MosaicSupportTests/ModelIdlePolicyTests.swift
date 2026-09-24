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

/// ⚠️ 判定と「記録を消す」が別々だと、その間に推論スレッドからの `note()` が割り込み、
/// **たった今使い始めた印を消してしまう**（そして走り始めた推論からモデルを取り上げる）。
/// `consumeIfIdle` はその 2 つをひと続きにするための入口なので、性質を固定する。
///
/// ⚠️ 確かめ方は**本番が使う API だけ**で書く（レビュー 21 周目）。以前は内部の
/// `lastUseAt` を覗いて「記録が消えたか」を見ていたが、それは**本番の誰も呼ばない
/// アクセサ**で、消すと通らなくなるテスト＝内部実装のテストになっていた。
/// 「もう一度消費できるか」で言い換えれば、外から見える振る舞いだけで同じことが言える。
@Suite("モデルの最終利用の記録")
struct ModelIdleTrackerTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    private func idle(_ t: ModelIdleTracker, analysisRunning: Bool = false) -> Bool {
        t.consumeIfIdle(now: now, idleSeconds: 300, analysisRunning: analysisRunning)
    }

    @Test("アイドルなら true を返す")
    func consumesWhenIdle() {
        let t = ModelIdleTracker()
        t.note(now: ago(400))
        #expect(idle(t))
    }

    /// ⚠️ これが本命。1 回消費したら、次の推論があるまで二度と通らないこと
    /// （＝記録が消えている。5 秒ごとに判定が通り続けるとランタイムを起こしてしまう）。
    @Test("続けて呼んでも 2 回目は通らない")
    func consumesOnlyOnce() {
        let t = ModelIdleTracker()
        t.note(now: ago(400))
        #expect(idle(t))
        #expect(!idle(t))
    }

    /// ⚠️ **消費のあとに来た `note()` は消されない**。消されると、走り始めた推論が
    /// 「使っていない」ことになり、次の判定でモデルを取り上げられる。
    @Test("消費の直後に使い始めたら、その印は残る")
    func noteAfterConsumeSurvives() {
        let t = ModelIdleTracker()
        t.note(now: ago(400))
        #expect(idle(t))
        t.note(now: now)                       // 推論が始まった
        #expect(!idle(t), "使い始めた直後に手放そうとしている")
    }

    /// ⚠️ 解析中は**記録も消さない**。消すと、解析が終わったあとに手放す機会を失う。
    /// 「解析が終わった体で呼び直すと通る」ことで、記録が残っているのを確かめる。
    @Test("解析中は消費せず、記録も消さない")
    func doesNotConsumeOrClearWhileAnalysisRuns() {
        let t = ModelIdleTracker()
        t.note(now: ago(10_000))
        #expect(!idle(t, analysisRunning: true))
        #expect(idle(t), "解析中に記録だけ消えている（終わっても手放せない）")
    }

    /// 一度も使っていなければ何も起きない（ランタイムの `shared` を起こさないため）。
    @Test("未使用なら消費しない")
    func neverUsedDoesNotConsume() {
        #expect(!idle(ModelIdleTracker()))
    }

    /// 線の手前では消費しない（記録も残る＝あとで線を越えたら通る）。
    @Test("線の手前では消費せず、記録も残る")
    func keepsRecordBeforeThreshold() {
        let t = ModelIdleTracker()
        t.note(now: ago(299))
        #expect(!idle(t))
        #expect(t.consumeIfIdle(now: now.addingTimeInterval(1), idleSeconds: 300,
                                analysisRunning: false),
                "1 秒後に線を越えたのに通らない（記録が消えている）")
    }

    /// ⚠️ `shared` を使い回すと、並列に走る他のテストと取り合いになる（共有状態は
    /// テストの差し込み口にしない・`unresolved-problems.md` の教訓）。独立性を明示する。
    @Test("インスタンスごとに独立している")
    func instancesAreIndependent() {
        let a = ModelIdleTracker(), b = ModelIdleTracker()
        a.note(now: ago(400))
        #expect(!idle(b), "別のインスタンスの記録が見えている")
    }
}
