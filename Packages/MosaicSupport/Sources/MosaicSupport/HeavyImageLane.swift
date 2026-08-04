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
    ///
    /// キャンセル: 待機中にキャンセルされた要求は**列の先頭へ繰り上げる**（ADR-75）。`acquire` が必ず
    /// 成功する契約（`release` と 1:1）を保ったまま、待ち時間だけを最短化する。スクロールで破棄された
    /// 先読みデコードが、キャンセル済みなのに行列の最後尾で待ち続けるのを防ぐ。
    private actor Gate {
        private struct Waiter {
            let id: Int
            let continuation: CheckedContinuation<Void, Never>
        }

        let maxConcurrent: Int
        private var active = 0
        private var waiters: [Waiter] = []
        private var nextWaiterID = 0
        /// enqueue より先にキャンセルが届いた待機者の ID。
        private var earlyCancels: Set<Int> = []
        /// 「まだ待機中（払い出し前）」の待機者 ID。払い出し済みの ID が `earlyCancels` に残り続けて
        /// Set が無制限に増えるのを防ぐ（`promote` の注記を参照）。
        private var pendingIDs: Set<Int> = []

        init(maxConcurrent: Int) { self.maxConcurrent = max(1, maxConcurrent) }

        func acquire() async {
            if active < maxConcurrent { active += 1; return }
            let id = nextWaiterID
            nextWaiterID &+= 1
            pendingIDs.insert(id)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    enqueue(Waiter(id: id, continuation: cont))
                }
            } onCancel: {
                Task { await self.promote(id) }
            }
            // resume 時点でスロットは release から引き継がれている（active は据え置き）。
            pendingIDs.remove(id)
            earlyCancels.remove(id)
        }

        func release() {
            if waiters.isEmpty {
                active = max(0, active - 1)
            } else {
                waiters.removeFirst().continuation.resume()   // active はそのまま次の待機者へ引き継ぐ
            }
        }

        private func enqueue(_ waiter: Waiter) {
            if earlyCancels.remove(waiter.id) != nil { waiters.insert(waiter, at: 0) }
            else { waiters.append(waiter) }
        }

        /// ⚠️ 「列に居ない」には (a) まだ enqueue 前 と (b) **もう払い出し済み**（onCancel の `Task` が
        /// 届く前に `release()` が resume して列から外した）の 2 通りがある。(b) を `earlyCancels` に
        /// 入れるとその ID は二度と消えず Set が無制限に増える——スクロール中の先読み破棄で高頻度に
        /// 起きるので、`pendingIDs` で 2 つを区別する。
        private func promote(_ id: Int) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                guard pendingIDs.contains(id) else { return }   // (b) 払い出し済み＝記録しない
                earlyCancels.insert(id)                         // (a) enqueue 前にキャンセルが届いた
                return
            }
            guard index > 0 else { return }
            let waiter = waiters.remove(at: index)
            waiters.insert(waiter, at: 0)
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
