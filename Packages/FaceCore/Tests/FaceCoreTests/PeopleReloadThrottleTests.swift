import Foundation
import Testing
@testable import FaceCore

/// **人物一覧の再読込は、重いほど間隔を空ける**（ADR-225・実機ログ diagnostics-93）。
///
/// ⚠️ 何を踏んだか: 静止時間が 700ms 固定だったので、1 回 2.6 秒（最大 8.7 秒）かかる一覧が
/// 「終わった直後にまた予約」で走り続け、**18 分で 160 回・合計 414 秒**になっていた。
/// 顔の `@ModelActor` は 1 本なので、その間ずっと写真の人物名・レビュー候補・スキャンが待つ。
@Suite("人物一覧の再読込の間引き（ADR-225）")
@MainActor
struct PeopleReloadThrottleTests {

    @Test("軽いうちは従来どおり素早く、重くなったら自分で空ける")
    func quietWindowScalesWithCost() {
        // まだ測っていない／一瞬で終わる＝従来の 700ms。
        #expect(PeopleEngine.reloadQuietMilliseconds(lastLoadSeconds: 0) == 700)
        #expect(PeopleEngine.reloadQuietMilliseconds(lastLoadSeconds: 0.1) == 700)
        // 実機の平均 2.6 秒 → 10.4 秒空ける（作り直しの 4 倍）。
        #expect(PeopleEngine.reloadQuietMilliseconds(lastLoadSeconds: 2.6) == 10_400)
        // 頭打ち 15 秒（一覧が古いままになりすぎない）。
        #expect(PeopleEngine.reloadQuietMilliseconds(lastLoadSeconds: 30) == 15_000)
    }
}
