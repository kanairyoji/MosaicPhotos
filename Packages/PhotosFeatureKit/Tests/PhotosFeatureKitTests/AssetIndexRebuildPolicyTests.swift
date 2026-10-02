#if canImport(UIKit)
import Foundation
import Testing
@testable import PhotosFeatureKit

/// **アセット索引を作り直してよいか**の規則（ADR-249・実機ログ diagnostics-103）。
///
/// ⚠️⚠️ **なぜ必要になったか**: `invalidate()` が PhotoKit の変更通知を受けるたびに
/// その場で `rebuild()` を呼んでいた。通知が続く間（iCloud 同期・バックアップの書き込み中）
/// **2〜3 秒おきに 18,204 件を列挙し直し**、1 セッションで built 36 回 / invalidated 33 回、
/// footprint は 592 → **857MB** になっていた。
/// しかも `buildTask?.cancel()` は走っている `enumerateObjects` を止められない
/// （協調的キャンセルの確認点が無い）ので、**列挙が重なって**積み上がる。
///
/// ⚠️ **同じ規則が `DropboxPhotoStore` には在った**（ADR-224/225：静かになってから 1 回＋
/// 間隔は直近の所要から）。ここだけ抜けていた——「同じ規則が散って 1 か所だけ抜ける」の 12 例目。
///
/// ⚠️ 実時間で待つテストは書かない（ADR-241）。時計を引数にして規則だけを固定する。
@Suite("アセット索引の作り直しは間引く（ADR-249）")
struct AssetIndexRebuildPolicyTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// ⚠️ **これが本丸**。変化が続いている間は作り直さない。
    @Test("変化が続いている間は待つ")
    func waitsWhileChangesKeepArriving() {
        // いま変更を受けたばかり（前回の作り直しは十分前）。
        let wait = AssetIndexRebuildPolicy.secondsToWait(
            now: t0, lastChangeAt: t0,
            lastRebuildAt: t0.addingTimeInterval(-3600), lastRebuildSeconds: 0.3)
        #expect(wait > 0, "変化の直後なのに作り直そうとしている: \(wait)")
        #expect(wait <= AssetIndexRebuildPolicy.quietWindow + 0.001,
                "静かの窓より長く待っている: \(wait)")
    }

    @Test("静かになったら作り直す")
    func rebuildsOnceQuiet() {
        let now = t0.addingTimeInterval(AssetIndexRebuildPolicy.quietWindow)
        let wait = AssetIndexRebuildPolicy.secondsToWait(
            now: now, lastChangeAt: t0,
            lastRebuildAt: t0.addingTimeInterval(-3600), lastRebuildSeconds: 0.3)
        #expect(wait <= 0, "静かになったのに待ち続けている: \(wait)")
    }

    /// ⚠️ ADR-225 と同じ規則: 重い端末ほど自分で間隔を空ける。
    @Test("間隔は直近の所要の 4 倍（下限と頭打ちつき）")
    func spacingScalesWithCost() {
        // 作り直しが 1 秒かかった → 4 秒だが、下限 5 秒が勝つ。
        let cheap = AssetIndexRebuildPolicy.secondsToWait(
            now: t0, lastChangeAt: t0.addingTimeInterval(-3600),
            lastRebuildAt: t0, lastRebuildSeconds: 1.0)
        #expect(abs(cheap - AssetIndexRebuildPolicy.floorInterval) < 0.001,
                "下限が効いていない: \(cheap)")

        // 3 秒かかった → 12 秒空ける（下限より長い）。
        let heavy = AssetIndexRebuildPolicy.secondsToWait(
            now: t0, lastChangeAt: t0.addingTimeInterval(-3600),
            lastRebuildAt: t0, lastRebuildSeconds: 3.0)
        #expect(abs(heavy - 12.0) < 0.001, "所要に応じて空けていない: \(heavy)")

        // 極端に重くても頭打ち。
        let huge = AssetIndexRebuildPolicy.secondsToWait(
            now: t0, lastChangeAt: t0.addingTimeInterval(-3600),
            lastRebuildAt: t0, lastRebuildSeconds: 600)
        #expect(abs(huge - AssetIndexRebuildPolicy.maxInterval) < 0.001,
                "頭打ちが効いていない: \(huge)")
    }

    /// ⚠️ **両方を満たすまで待つ**（遅い方が勝つ）。片方だけ見ると、
    /// 静かでも間隔が足りない回／間隔は空いても変化が続いている回が漏れる。
    @Test("「静かになった」と「間隔が空いた」の遅い方まで待つ")
    func waitsForWhicheverIsLater() {
        // 静かにはなったが、直前に作り直したばかり。
        let wait = AssetIndexRebuildPolicy.secondsToWait(
            now: t0.addingTimeInterval(AssetIndexRebuildPolicy.quietWindow),
            lastChangeAt: t0, lastRebuildAt: t0, lastRebuildSeconds: 0.3)
        #expect(wait > 0, "間隔が空いていないのに作り直そうとしている: \(wait)")
    }

    /// ⚠️ **初回は待たせすぎない**。まだ一度も作り直していない（`lastRebuildAt` が遠い過去）なら、
    /// 静かになりしだい走ってよい——起動直後の索引構築が 5 秒遅れると体感に出る。
    @Test("まだ一度も作り直していなければ、静かになった時点で走る")
    func firstBuildIsNotDelayedByTheInterval() {
        let wait = AssetIndexRebuildPolicy.secondsToWait(
            now: t0.addingTimeInterval(AssetIndexRebuildPolicy.quietWindow),
            lastChangeAt: t0, lastRebuildAt: .distantPast, lastRebuildSeconds: 0)
        #expect(wait <= 0, "初回の索引構築まで間隔で待たせている: \(wait)")
    }
}
#endif
