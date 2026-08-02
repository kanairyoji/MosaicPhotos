import Foundation

/// 急ぎでない重い画像処理（先読みデコード・顔アバター生成・カバー生成など）を通す**低優先の共通レーン**。
///
/// iOS では別プロセス化できないため、「別プロセス＋nice で優先度を下げる」の等価物として:
/// - **同時実行数を絞る**（コア数−2）＝バーストで全コアを飽和させ UI/レンダーサーバを飢餓させない（提案1）
/// - **UI がビジーな間は譲る**（写真表示・スクロール・クラウド/フル取得中は空くまで待つ・提案5）
/// を 1 箇所に集約する。QoS（提案2）は呼び出し側 Task の `priority:` で下げる（本レーンは body を
/// 呼び出し側の実行コンテキストで走らせるだけ＝ここでは QoS を固定しない）。
///
/// 使い方（バルク＝急ぎでない処理）:
/// ```
/// await Task.detached(priority: .utility) {
///     await HeavyImageLane.run { heavyDecodeOrGenerate() }
/// }.value
/// ```
/// 可視セルなどユーザーが待っている**緊急**処理は本レーンを通さず直接・高 QoS で走らせる（提案3の2レーン化）。
public enum HeavyImageLane {

    /// 同時実行スロットと待機列を管理する actor（counter のみ・重い body は載せない）。
    private actor Gate {
        let maxConcurrent: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(maxConcurrent: Int) { self.maxConcurrent = max(1, maxConcurrent) }

        func acquire() async {
            if active < maxConcurrent { active += 1; return }
            await withCheckedContinuation { waiters.append($0) }
            // resume 時点でスロットは release から引き継がれている（active は据え置き）。
        }

        func release() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()   // active はそのまま次の待機者へ引き継ぐ
            } else {
                active = max(0, active - 1)
            }
        }
    }

    private static let gate = Gate(maxConcurrent: max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    /// UI がビジーな間は少しずつ眠って譲る（キャンセルで抜ける・最大待ちは呼び出し側の寿命に従う）。
    public static func waitWhileUIBusy() async {
        while BackgroundActivityMonitor.isUIBusySnapshot && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)   // 0.2s
        }
    }

    /// バルク（急ぎでない）重い画像処理を「UI 譲り→同時数スロット取得→body→スロット返却」で実行する。
    /// body は**呼び出し側の実行コンテキスト**で in-place に走る（QoS は呼び出し側 Task の priority に従う・
    /// 結果は isolation 境界を跨がないので UIImage? など非 Sendable も返せる）。
    @discardableResult
    public static func run<T>(yieldToUI: Bool = true, _ body: () async -> T) async -> T {
        if yieldToUI { await waitWhileUIBusy() }
        await gate.acquire()
        let result = await body()
        await gate.release()
        return result
    }
}
