import Foundation
import MosaicSupport

/// ANE 系の重い処理の優先度。前景（ユーザーが待っている）と背景（夜間バッチ）を区別する。
public enum MLInferencePriority: Sendable {
    /// 前景。検索・AI アルバム作成など、ユーザーが結果を待っている処理。待機列の先頭側に入る。
    case interactive
    /// 背景。夜間のタグ付け・埋め込み・顔スキャン・キャプション。前景が待っている間は譲る。
    case background
}

/// 端末の **Neural Engine（ANE）を使う重い処理を 1 つずつに直列化**する共有ゲート。
///
/// ⚠️ 実機で判明した障害（diagnostics-19）: 顔検出（Vision `VNImageRequestHandler.perform`＝ANE）と
/// CLIP 埋め込み/モデルロード（Core ML＝ANE）が**同時に走ると ANE がデッドロックし、Vision の perform が
/// 永久に返らない**（顔スキャンが最初の 1 枚で固まり People=0 のまま）。以前は CLIP 埋め込みが Wi-Fi
/// ゲートで止まっていて顔スキャンが ANE を独占できていたため顕在化しなかった（ADR-69 で埋め込みが
/// 常時走るようになって表面化）。
///
/// 対策: 顔検出・CLIP 埋め込み・Vision タグ・VLM キャプション・各モデルロードといった **ANE 系の重い
/// 処理をこのゲートに通し、同時に 1 つだけ**実行する（推論粒度で直列化）。単体では固まらない（実績あり）
/// ので、直列化すればデッドロックしない。ロードの一時的な待ち（数十秒）はあるがトリクル処理なので許容。
///
/// ## どこで包むか（重要・ADR-73）
/// **ANE に実際に触れる場所＝`MobileCLIPKit` の各ランタイム/アダプタの内側**で包む。
/// 呼び出し側（`FaceTagger` / `TagTagger` / `PhotoTagger` などの夜間タガー）は**包まない**。
/// 理由は 2 つ:
/// - **漏れ防止**: 呼び出し側で包む方式だと、ゲートを通さない経路（前景の検索＝CLIP テキスト塔など）が
///   容易に生まれる。実際 `QueryEmbedder` → `TextEmbedder.embed` は素通りしていた。
/// - **占有時間の最小化**: 呼び出し側で包むと画像ロード（PHImageManager / Dropbox サムネ取得＝ANE を
///   使わない I/O）までゲート内に入り、その間ほかの推論が全部止まる。推論だけを包めばロードは並列に回る。
///
/// ## 優先度（ADR-75）
/// 待機列は **interactive / background の 2 本**で、解放時は interactive を先に起こす。前景の検索が
/// 夜間バッチの待ち行列（`senseInfo` は同時 3 件がゲート待ちになる）の後ろに並ぶのを防ぐ。
/// interactive は低頻度（ユーザー操作由来）なので background の飢餓は実際上起きない。
///
/// ⚠️ **残る最悪ケース**: 優先度は「待機列」の順序を変えるだけで、**実行中の保持者は横取りできない**。
/// モデルロード（CLIP 画像塔は実機 16〜35 秒）がゲート内で走るため、その最中に来た前景要求は
/// ロード完了まで待つ。ロードをゲート外へ出せば解消するが、「ロードと推論の同時実行が ANE で安全か」は
/// 実機未検証（過去に確認済みなのは**ロード同士**の並列が安全なことだけ＝`CoreMLModelSupport` の記述）。
/// 危険側に倒れると再び永久ハングなので、検証するまではロードもゲート内に置く。
///
/// ⚠️ **入れ子にしないこと**。`run` の中でさらに `run` を呼ぶと本来デッドロックする。保険として同一タスク
/// からの再入は検出して素通しする（下記 `isHeld`）が、これは安全網であって設計ではない。
/// なお `Task.detached` はタスクローカルを引き継がないため、`run` の内側で detached を作ってそこから
/// `run` を呼ぶと検出できず**本当に固まる**。ゲート内では detached を作らないこと。
///
/// 実装: `actor` の再入を利用した公平な FIFO ゲート。`run` は body 実行中ゲートを保持し、他の `run` は待つ。
public actor MLInferenceGate {
    public static let shared = MLInferenceGate()

    /// 現在のタスクがゲートを保持しているか（入れ子検出用）。`Task.detached` には伝播しない。
    @TaskLocal private static var isHeld = false

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var busy = false
    private var interactiveWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private var nextWaiterID = 0
    /// enqueue より先にキャンセルが届いた待機者の ID（登録時に先頭へ入れるため保持する）。
    private var earlyCancels: Set<Int> = []
    /// 「まだ待機中（払い出し前）」の待機者 ID。`promote` が **払い出し済みの ID を
    /// `earlyCancels` に書き込んで永久に残す**のを防ぐために持つ（下記参照）。
    private var pendingIDs: Set<Int> = []

    private func acquire(_ priority: MLInferencePriority) async {
        if !busy {
            busy = true
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        pendingIDs.insert(id)
        // キャンセルされた待機者は**列の先頭へ繰り上げる**（`run` の戻り値は非 Optional なので、
        // ゲートを取らずに body を飛ばすことはできない＝待ち時間だけを最短化する）。
        // これで「キャンセル済みなのに行列の最後尾で順番待ち」が無くなり、BGTask 期限切れの
        // 後片付けや顔スキャンの中断が、現在の保持者 1 件ぶんの待ちで済むようになる。
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                enqueue(Waiter(id: id, continuation: cont), priority: priority)
            }
        } onCancel: {
            Task { await self.promote(id) }
        }
        // 払い出し済み。この後に届く promote は無視させる（`pendingIDs` から外す）。
        pendingIDs.remove(id)
        earlyCancels.remove(id)   // 取りこぼしの保険（通常は enqueue が消費済み）
    }

    private func enqueue(_ waiter: Waiter, priority: MLInferencePriority) {
        let wasCancelledEarly = earlyCancels.remove(waiter.id) != nil
        switch priority {
        case .interactive:
            if wasCancelledEarly { interactiveWaiters.insert(waiter, at: 0) }
            else { interactiveWaiters.append(waiter) }
        case .background:
            if wasCancelledEarly { backgroundWaiters.insert(waiter, at: 0) }
            else { backgroundWaiters.append(waiter) }
        }
    }

    /// キャンセルされた待機者を自分の優先度クラスの先頭へ繰り上げる。
    /// まだ enqueue されていなければ `earlyCancels` に覚えておき、登録時に先頭へ入れる。
    ///
    /// ⚠️ 「どちらの列にも居ない」には **2 通り**ある。(a) まだ enqueue 前、(b) **もう払い出し済み**
    /// （onCancel の `Task` が actor に届く前に `release()` がその待機者を resume して列から外した）。
    /// (b) を (a) と誤認して `earlyCancels` に入れると、その ID は二度と enqueue されないので
    /// **永久に残り Set が無制限に増える**。スクロール中の先読み破棄のような高頻度経路で効くため、
    /// `pendingIDs`（払い出し前だけ真）で 2 つを区別する。
    private func promote(_ id: Int) {
        if let index = interactiveWaiters.firstIndex(where: { $0.id == id }) {
            if index > 0 {
                let waiter = interactiveWaiters.remove(at: index)
                interactiveWaiters.insert(waiter, at: 0)
            }
            return
        }
        if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            if index > 0 {
                let waiter = backgroundWaiters.remove(at: index)
                backgroundWaiters.insert(waiter, at: 0)
            }
            return
        }
        guard pendingIDs.contains(id) else { return }   // (b) 払い出し済み＝記録しない
        earlyCancels.insert(id)                         // (a) enqueue 前にキャンセルが届いた
    }

    /// テスト用の内部状態スナップショット（本番経路では使わない）。
    /// 待機列と `earlyCancels` が処理後にきちんと空へ戻ることを検証するために公開する。
    var debugState: (interactive: Int, background: Int, earlyCancels: Int, pending: Int, busy: Bool) {
        (interactiveWaiters.count, backgroundWaiters.count, earlyCancels.count, pendingIDs.count, busy)
    }

    /// テスト用: 「**払い出し済み**（もう待機していない）ID に遅れて届いた promote」を模擬する。
    /// この競合（onCancel の Task が actor に届く前に `release()` が resume してしまう）は
    /// スケジューリング依存で決定的に再現できないため、契約そのものを直接検証するための seam。
    func debugPromoteStaleWaiter(_ id: Int) { promote(id) }

    private func release() {
        // interactive を優先して起こす（前景がユーザーを待たせないように）。
        if !interactiveWaiters.isEmpty {
            interactiveWaiters.removeFirst().continuation.resume()   // busy は保持したまま引き継ぐ
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().continuation.resume()
        } else {
            busy = false
        }
    }

    /// ANE 系の重い処理を直列化して実行する。body は取得〜解放の間だけ実行され、他の呼び出しは待機する。
    /// 同一タスクが既に保持している場合（入れ子）は、デッドロックさせず素通しする（保持は継続）。
    public func run<T: Sendable>(priority: MLInferencePriority = .background,
                                 _ body: @Sendable () async -> T) async -> T {
        if Self.isHeld {
            assertionFailure("MLInferenceGate.run が入れ子で呼ばれた（設計上は 1 段のみ）")
            return await body()
        }
        // ⚠️ ゲート待ちは「別の推論が長く占有している」ときにだけ長くなる。占有側は無関係な経路
        //    （例: 表示ラベラの事前ウォーム＝CLIP テキストタワーのロード 15.5 秒・実機 diagnostics-40）
        //    のことがあり、待たされた側のログだけを見ても犯人が分からない。**長い待ちは記録する**
        //    ＝次のログで「誰が待たされたか」を突き合わせられるようにする（ADR-95 追記）。
        let waitStart = PerfTrace.nowNs()
        let epoch = ProcessSuspension.epoch
        await acquire(priority)
        let waitedMs = PerfTrace.msSince(waitStart)
        if waitedMs >= 1000, !ProcessSuspension.didSuspend(since: epoch) {
            Diagnostics.mark(String(format: "ANE gate: waited %.0fms (priority=%@)",
                                    waitedMs, String(describing: priority)))
        }
        let result = await Self.$isHeld.withValue(true) { await body() }
        release()
        return result
    }
}
