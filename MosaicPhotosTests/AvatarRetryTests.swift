import Testing
@testable import MosaicPhotos

/// ⚠️ 実フィードバック: まとめて確認画面で、Dropbox 上にあってまだ取得できていない写真が
/// **白黒の人型アイコンのまま変わらない**。置いておいても変わらず、スクロールアウトして
/// もう一度表示すると出る。`.task` が一度きりで、温めを予約したあと誰も取りに戻らないため。
@Suite("アバターの取り直し間隔")
struct AvatarRetryTests {

    @Test("何度か見に行き直す")
    func retriesSeveralTimes() {
        #expect(FaceAvatarCache.retryDelays.count >= 3,
                "1〜2 回では低優先の温めが届く前に諦めてしまう")
    }

    @Test("間隔は広がっていく")
    func delaysIncrease() {
        let delays = FaceAvatarCache.retryDelays
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 },
                "等間隔で叩き続けると、見えていない分まで負荷になる")
    }

    @Test("最初の 1 回は素早く見に行く")
    func firstRetryIsQuick() {
        #expect((FaceAvatarCache.retryDelays.first ?? 99) <= 1.0,
                "既にキャッシュ済みだった場合に人型が長く残る")
    }

    /// 届かないものを無限に追うと、画面外の分まで抱え続ける。
    @Test("合計時間は有界")
    func totalIsBounded() {
        let total = FaceAvatarCache.retryDelays.reduce(0, +)
        #expect(total > 5, "短すぎると回線が遅いときに間に合わない")
        #expect(total <= 60, "長すぎると届かない分を延々と追い続ける")
    }
}
