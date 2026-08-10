import Foundation
import Testing
@testable import AutoAlbumCore

/// 表示ラベラの事前ウォームは**外から止められる**こと（ADR-95 追記）。
///
/// 実機 diagnostics-40 の回帰: フォアグラウンド復帰で `prewarmTask` を cancel しても、
/// ラベラ内部の「二重構築を防ぐ共有 Task」には伝播せず、約300語の text encode と
/// CLIP テキストタワーのロード（実測 15456ms）が走り切って ANE ゲートを占有し続けていた。
/// seam に中断の入口があること／既定実装が安全（何もしない）ことを固定する。
@Suite("LabelProvider prewarm cancellation")
struct LabelProviderPrewarmTests {

    /// 共有 Task に合流する実装（本番の `CLIPDisplayLabeler` と同じ形）を模したスタブ。
    private final class SharedBuildLabeler: LabelProvider, @unchecked Sendable {
        let lock = NSLock()
        var buildTask: Task<Bool, Never>?
        /// 構築が最後まで走り切ったか（中断できていれば false のまま）。
        var completedFully = false
        /// 構築に入ったことを待ち合わせるための連続実行フラグ。
        let started = Continuation()

        final class Continuation: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() { lock.lock(); fired = true; lock.unlock() }
            var isFired: Bool { lock.lock(); defer { lock.unlock() }; return fired }
        }

        func labels(forEmbedding clipVector: Data) async -> [String] { [] }

        func prewarm() async {
            lock.lock()
            let task = buildTask ?? {
                let t = Task { [weak self] () -> Bool in
                    self?.started.fire()
                    // 「約300語の encode」を模す。1 語ごとに中断を見るのが要点。
                    for _ in 0..<300 {
                        if Task.isCancelled { return false }
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    self?.completedFully = true
                    return true
                }
                buildTask = t
                return t
            }()
            lock.unlock()
            _ = await task.value
        }

        func cancelPrewarm() {
            lock.lock()
            let task = buildTask
            buildTask = nil
            lock.unlock()
            task?.cancel()
        }
    }

    @Test("cancelPrewarm は共有 Task に伝播して構築を止める")
    func cancelPrewarmStopsSharedBuild() async {
        let labeler = SharedBuildLabeler()
        // prewarm は「外側の Task」から起こす（本番の prewarmTask と同じ構図）。
        let outer = Task { await labeler.prewarm() }
        while !labeler.started.isFired { await Task.yield() }

        // ⚠️ 外側の cancel **だけ**では止まらない、が本件の真因。seam 経由で明示的に止める。
        outer.cancel()
        labeler.cancelPrewarm()
        await outer.value

        #expect(!labeler.completedFully, "中断したのに約300語の構築が走り切っている")
    }

    @Test("既定実装の cancelPrewarm は何もしない（未対応の実装を壊さない）")
    func defaultCancelIsNoop() {
        struct Plain: LabelProvider {
            func labels(forEmbedding clipVector: Data) async -> [String] { [] }
            func prewarm() async {}
        }
        Plain().cancelPrewarm()   // クラッシュしないこと＝既定実装が存在すること
        #expect(Plain().isReady)
    }
}
