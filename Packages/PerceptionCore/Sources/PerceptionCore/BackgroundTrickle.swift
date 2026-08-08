import Foundation
import MosaicSupport

/// 背景トリクル処理の共通ループ（PhotoTagger / FaceTagger / TagTagger が共用）。
/// 「バッチ供給 → 1 単位ずつ推論 → バッチごとに 1 回保存 → バッチ間スリープ」の骨格を提供する。
///
/// ⚠️ 不変条件: 停止判定は 1 単位ごと（各推論の**前**に `shouldPause` を確認）。
/// バッチ一括で確認すると、ロック解除直後の操作までの譲りが単位所要 × バッチ件数ぶん遅れる。
/// 「1 単位」は通常 1 枚。CLIP 埋め込みのみミニバッチ（≤8枚・ANE 償却で 2〜4 倍速）を単位とする。
@MainActor
public enum BackgroundTrickle {

    /// バッチ確定（保存・通知）後にループを続けるかどうか。
    public enum BatchOutcome {
        /// バッチ間スリープ（`betweenBatchNs`）を挟んで次バッチへ。
        case proceed
        /// スリープせず即終了（結果空＝推論に到達せずキャンセル、など）。
        case stop
    }

    /// `shouldPause` が立っている間 0.3s ずつ眠って譲る（キャンセルで抜ける）。
    /// `pausePerfLabel` を渡すと譲り待ちの発生数を PerfTrace に数える（センサー用途）。
    /// `onPauseBegin` は**譲りに入った瞬間に 1 回だけ**呼ぶ（ADR-79）。重いモデル（VLM≈877MB）を
    /// 抱えたまま眠ると、復帰直後のメモリ圧迫→サムネキャッシュ縮小→再デコード連鎖を招くため、
    /// ここで解放させる。推論の**前**に呼ばれるので、実行中の推論を壊すことはない。
    public static func waitWhilePaused(_ shouldPause: @MainActor () -> Bool,
                                pausePerfLabel: String? = nil,
                                onPauseBegin: (@MainActor () -> Void)? = nil) async {
        var notified = false
        while shouldPause() && !Task.isCancelled {
            if !notified { notified = true; onPauseBegin?() }
            if let pausePerfLabel { PerfTrace.count(pausePerfLabel) }
            try? await Task.sleep(nanoseconds: 300_000_000)   // 0.3s
        }
    }

    /// trickle ループ本体。
    /// - `nextBatch`: 次に処理する単位列を返す（**空配列で正常終了**）。todo の切り出し・動的クエリ・
    ///   尽きたときのログは呼び手がこの中で行う（各タガーで供給方法が異なるため）。
    /// - `processUnit`: 1 単位の推論。所要 ms を `unitPerfLabel` に記録する
    ///   （`unitPerfDivisor` で 1 枚あたりへ換算できる。既定 1）。
    /// - `commitBatch`: バッチ結果の保存・進捗/周期通知（save はバッチ 1 回、の置き場）。
    ///   キャンセルで途中までになった部分結果もそのまま渡す。`.stop` でスリープせず終了。
    public static func run<Unit, UnitResult>(
        maxBatches: Int = .max,
        betweenBatchNs: UInt64,
        shouldPause: @MainActor () -> Bool,
        pausePerfLabel: String? = nil,
        onPauseBegin: (@MainActor () -> Void)? = nil,
        unitPerfLabel: String,
        unitPerfDivisor: (Unit) -> Double = { _ in 1 },
        warmBatch: (@MainActor ([Unit]) -> Void)? = nil,
        nextBatch: @MainActor (_ batchIndex: Int) async -> [Unit],
        processUnit: @MainActor (Unit) async -> UnitResult,
        commitBatch: @MainActor (_ batchIndex: Int, _ batch: [Unit], _ results: [UnitResult]) async -> BatchOutcome
    ) async {
        var batchIndex = 0
        while batchIndex < maxBatches, !Task.isCancelled {
            let batch = await nextBatch(batchIndex)
            guard !batch.isEmpty else { break }
            // ⚠️ バッチの素材を**まとめて先に取りに行く**（ADR-83）。クラウド写真は 1 枚ずつ
            // サムネを取ると 1 枚 600〜800ms の往復が推論と直列に並び、AI 処理時間の 85〜90% を
            // ダウンロード待ちが占めていた（実測 diagnostics-31/32）。ここで**非同期に**一括要求
            // しておくと、Dropbox のバッチ API（25 枚/リクエスト・並列）に相乗りでき、
            // 2 枚目以降は取得済みから始まる。await しない＝1 枚目の処理と重ねる。
            warmBatch?(batch)

            var results: [UnitResult] = []
            for unit in batch {
                // ⚠️ 停止判定は 1 単位ごと：各推論の前に譲る（上記の不変条件）。
                await waitWhilePaused(shouldPause, pausePerfLabel: pausePerfLabel,
                                      onPauseBegin: onPauseBegin)
                if Task.isCancelled { break }
                let tUnit = PerfTrace.nowNs()
                let epoch = ProcessSuspension.epoch
                let result = await processUnit(unit)
                // 中断（suspend）を跨いだ単位は、所要が壁時計で汚染されているので計上しない
                // （実機ログで face.photoMs=1(Σ492753.8ms) のような偽値が出ていた）。
                if !ProcessSuspension.didSuspend(since: epoch) {
                    PerfTrace.count(unitPerfLabel, value: PerfTrace.msSince(tUnit) / unitPerfDivisor(unit))
                }
                results.append(result)
            }
            if await commitBatch(batchIndex, batch, results) == .stop { break }
            // ★ バッチ間で休む：端末・ネットワーク・UI を圧迫しない trickle 処理にする。
            //   候補D: サーマル状態で休止を自動調整（熱に余裕なら 1x＝プリセット通り、逼迫したら
            //   休止を延ばして発熱/サーマルスロットリングを避ける＝連続処理の実効速度を守る）。
            let pauseNs = UInt64(Double(betweenBatchNs) * thermalPauseMultiplier())
            try? await Task.sleep(nanoseconds: pauseNs)
            batchIndex += 1
        }
    }

    /// バッチ間スリープのサーマル係数（候補D）。重い処理は電源＋アイドル中のみだが、連続処理で
    /// 温まるため、逼迫時は休止を延ばして緩める（ユーザー選択のプリセットより速くはしない＝1x が上限）。
    public static func thermalPauseMultiplier() -> Double {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 1.0
        case .fair:     return 1.5
        case .serious:  return 3.0
        case .critical: return 8.0
        @unknown default: return 1.0
        }
    }
}
