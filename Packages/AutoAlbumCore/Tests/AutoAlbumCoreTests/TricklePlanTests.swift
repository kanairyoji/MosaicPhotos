import Foundation
import Testing
@testable import AutoAlbumCore

/// 背景トリクルの手順（ADR-198）。
/// **コメントにしか書かれていなかった不変条件**を、ここで初めて固定する。
/// 以前この判断は `scheduleBackgroundFill()` の 117 行クロージャの中にあり、テストは 2 本だった。
@Suite("背景トリクルの手順（ADR-198）")
struct TricklePlanTests {

    private func labels(_ i: TricklePlan.Inputs) -> [String] { TricklePlan.steps(i).map(\.label) }

    @Test("既定はタグ → 埋め込み（タグは検索の一次ランキングなので先）")
    func defaultOrder() {
        #expect(labels(.init()) == ["tags(40)", "embed"])
    }

    /// ADR-85 の回帰。上限が無いとタグが窓を独占し、CLIP 埋め込みが**永久に飢餓**する
    /// （実機 diag-28〜33: タグは 33,662→24,505 と進む一方、未埋め込みは 43,611→43,626 と
    /// まったく減らず、`embed: batch` が数週間 1 度も出ていなかった）。
    @Test("回帰: シーンタグには必ず有限の上限がある（無いと埋め込みが飢餓する）")
    func tagPhaseAlwaysHasAFiniteLimit() {
        for network in [true, false] {
            for warming in [true, false] {
                let steps = TricklePlan.steps(.init(networkAllowed: network,
                                                    labelerNeedsWarming: warming))
                let limits = steps.compactMap { step -> Int? in
                    if case .tagScenes(let max, _) = step { return max }
                    return nil
                }
                #expect(limits.count == 1, "タグの段が 1 つでない")
                #expect(limits[0] > 0 && limits[0] < .max, "上限が無限（飢餓する）")
                #expect(limits[0] == TricklePlan.tagBatchesPerRun)
            }
        }
    }

    /// クラウド写真のタグ付けはサムネ DL を伴うので、回線が許されないときは対象から外す。
    /// ローカルは通信不要なので常に進む（Wi-Fi 未接続の夜間に端末内写真まで止まった実障害の対処）。
    @Test("回線が許されないときは候補を端末内写真だけに絞る")
    func localOnlyWhenNetworkIsBlocked() {
        #expect(labels(.init(networkAllowed: false)) == ["tags(40,local)", "embed"])
        #expect(labels(.init(networkAllowed: true)) == ["tags(40)", "embed"])
    }

    /// ADR-80 の回帰。以前はゲート判定の外にあったため、起動直後でも CLIP テキストタワーの
    /// ロード（新規インストール直後は実測 23 秒）＋約300語の encode が走り、起動を重くしていた。
    @Test("回帰: ゲートが閉じているときはラベラのウォームを起こさない")
    func doesNotWarmTheLabelerWhileTheGateIsClosed() {
        #expect(!labels(.init(labelerNeedsWarming: true, gateOpen: false)).contains("warmLabeler"))
        #expect(labels(.init(labelerNeedsWarming: true, gateOpen: true)).contains("warmLabeler"))
    }

    @Test("温まっているラベラは温め直さない")
    func doesNotWarmAnAlreadyWarmLabeler() {
        #expect(!labels(.init(labelerNeedsWarming: false)).contains("warmLabeler"))
    }

    @Test("ウォームはタグより前（ついでの仕事を後ろに回さない＝ANE を細切れに使う）")
    func warmComesFirst() {
        let steps = labels(.init(labelerNeedsWarming: true))
        #expect(steps.firstIndex(of: "warmLabeler")! < steps.firstIndex(of: "tags(40)")!)
    }

    /// 窓の残りは全部埋め込みに使う（VLM キャプションのインターリーブは ADR-108 で廃止）。
    @Test("手順は必ず埋め込みで終わる")
    func alwaysEndsWithEmbedding() {
        for network in [true, false] {
            for warming in [true, false] {
                for open in [true, false] {
                    let steps = labels(.init(networkAllowed: network,
                                             labelerNeedsWarming: warming, gateOpen: open))
                    #expect(steps.last == "embed", "\(steps)")
                }
            }
        }
    }
}
