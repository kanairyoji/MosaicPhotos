import Foundation

/// 解析セッション（ADR-182）の純ロジック: 進捗の合成・停止判定。
/// `AnalysisSession` は状態を持ち、判断はすべてここに置く（`NightlyWorkPolicy` と同じ分け方）。
enum AnalysisSessionPolicy {

    /// 進捗の「準備中」枠（モデルロードの 20〜40 秒に 1 目盛りずつ進める）。
    /// BGContinuedProcessingTask は**進捗を報告しないタスクから OS が殺す**ので、
    /// 写真が 1 枚も終わらない間も何かが進んでいると伝える。
    static let warmupUnits: Int64 = 20

    // ⚠️ 電池の下限は **`BackgroundYield` のゲート表**（ADR-196）が持つ。ここに置くと
    //    ブーストのループの中でしか効かず、「電池のため止めた」と言った直後に方針が
    //    同じ処理を再開する（レビュー指摘）。

    /// 残作業の合計（顔・タグ・埋め込み）。負の値（分母未確定）は 0 扱い。
    static func remaining(faces: Int, tagsPending: Int, embedPending: Int) -> Int {
        max(0, faces) + max(0, tagsPending) + max(0, embedPending)
    }

    /// `Progress` に渡す値。`peakRemaining` はこのセッションで観測した残作業の最大値
    /// （顔の残数はスキャン開始後に判明するので、途中で分母が増える）。
    /// - Returns: completed ≤ total を保証。
    static func progressUnits(peakRemaining: Int, remaining: Int, warmupTicks: Int) -> (completed: Int64, total: Int64) {
        let total = Int64(max(peakRemaining, 0)) + warmupUnits
        let done = Int64(max(0, peakRemaining - remaining)) + min(warmupUnits, Int64(max(0, warmupTicks)))
        return (min(done, total), total)
    }

    /// このブーストでやることが無くなったか。
    ///
    /// 呼ぶのは**前口上が終わったあと**（`AnalysisSession.watchProgress`）なので、
    /// 「顔スキャンがまだ始まっていない」状態は考えなくてよい（旧 `faceScanSettled` は撤去）。
    /// ⚠️ これは「残作業ゼロ」ではなく「いま動かせるものが無い」。残作業があるのにゲートで
    /// 畳んだ場合を `.finished` と区別するのは呼び出し側（ゲートに理由を聞く）。
    static func isFinished(remaining: Int, tagging: Bool, scanning: Bool) -> Bool {
        remaining == 0 && !tagging && !scanning
    }
}
