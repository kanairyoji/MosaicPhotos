import Foundation
import Observation

/// **同時に 1 本だけ走るバックグラウンド作業**（ADR-198）。
///
/// ## なぜ共通部品にしたか
/// 「1 本だけ走らせる」「止めた側が遅れて終わっても後続を踏まない」「走行中に来た要求を
/// 1 回だけ拾い直す」——この 3 つはコード中に**手書きで散らばっていた**:
/// `Task<Void, Never>?` のホルダが 24 か所、世代カウンタ（`xxxGeneration &+= 1`）が 7 個、
/// 保留フラグ（`pending` / `needsAnotherPass` / `refreshRequested`）が 3 個。
/// しかもそれぞれ別々にバグっていた:
/// - 「A をキャンセル後に B が始まり、その後 A が終了したときに A が **B のハンドルを消す**」
///   （レビュー指摘 → `GenerationHandle` を新設したが 1 か所でしか使われなかった）
/// - 「キャンセルで抜けると、直前に立った要求が誰にも処理されず数字が凍る」（レビュー指摘）
///
/// ## 使い分け
/// | やりたいこと | API |
/// |---|---|
/// | 走行中なら何もしない（二重起動の抑止） | `start(_:)` |
/// | 走行中でも明け渡させて始め直す（処理枠の先頭・ADR-95） | `restart(_:)` |
/// | 走行中なら「終わってからもう 1 回だけ」 | `coalesce(_:)` |
/// | 明示的に止める（前面復帰・ADR-79） | `stop()` |
/// | 終わるまで待つ（テスト・設定画面） | `waitUntilIdle()` |
///
/// ## 世代ガード
/// `restart` / `stop` は世代を進める。旧タスクの本体が遅れて終わっても、**自分の世代でなければ
/// 後始末をしない**——これが無いと、止めた側が後続の実行中フラグを落としてしまう。
@MainActor
@Observable
public final class SingleFlightTask {

    /// いま走っているか。`@Observable` なので SwiftUI から直接観測できる
    /// （委譲プロパティ `var isScanning: Bool { scan.isRunning }` がそのまま追従する）。
    public private(set) var isRunning = false {
        didSet { if isRunning != oldValue { onStateChange?(isRunning) } }
    }

    /// 走行状態が変わったときに呼ばれる。`BackgroundActivityMonitor` のような**鏡写し**に使う。
    /// ⚠️ 本体の `defer` で鏡写しすると、明け渡した旧タスクが遅れて終わったときに
    /// **後続の状態を上書きする**。世代を知っているこちらから通知する。
    @ObservationIgnored public var onStateChange: ((Bool) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// 走行中に来た要求（**1 つだけ**畳む）。2 つ以上は最後のものが残る。
    @ObservationIgnored private var pending: (() async -> Void)?
    @ObservationIgnored private var pendingPriority: TaskPriority?
    /// 止めた/明け渡したタスク。`waitUntilIdle()` が待つ対象（下の `retiringLimit` 件まで）。
    @ObservationIgnored private var retiring: [Task<Void, Never>] = []
    /// 控えるのは直近だけ。`waitUntilIdle()` を呼ばない呼び出し側（駆動役・処理枠）が
    /// `stop` / `restart` を繰り返すので、際限なく溜めない。落とすのは**とうに終わっている**
    /// 古いキャンセル済みタスクなので、待ちの保証は実用上保たれる。
    @ObservationIgnored private static let retiringLimit = 4

    public init() {}

    /// 走行中なら何もしない。戻り値＝実際に始めたか。
    ///
    /// - Parameter priority: ⚠️ **必ず指定する**（レビュー指摘）。素の `Task { }` は
    ///   呼び出し元の優先度を引き継ぐ。背景トリクル（CLIP 埋め込み・Vision タグ・顔検出）は
    ///   `.background` でなければ UI 操作（`.userInitiated`）と CPU を奪い合う
    ///   ——駆動役や SwiftUI の `.task` から起こされると既定で昇格してしまう。
    @discardableResult
    public func start(priority: TaskPriority? = nil, _ body: @escaping () async -> Void) -> Bool {
        guard !isRunning else { return false }
        launch(body, priority: priority)
        return true
    }

    /// 走行中なら明け渡させてから始め直す。
    ///
    /// 夜間の処理枠は重い処理のための特権時間なので、前面で始まってゲート閉で眠っている実行が
    /// 居座っていると窓が丸ごと空転する（実機 diagnostics-38: 窓 77 秒のうち有効な処理は 0）。
    public func restart(priority: TaskPriority? = nil, _ body: @escaping () async -> Void) {
        // ⚠️ ここで `isRunning` を落とさない。落とすと鏡写し（`onStateChange`）が
        // false → true とばたつき、「解析が一瞬止まった」ように見える。
        // 明け渡しても**作業が走っていること自体は続いている**。
        invalidateCurrent()
        // ⚠️ 予約も捨てる（`stop()` と対称にする・レビュー指摘）。明け渡した実行に対して
        // 積まれていた「もう 1 回」は、呼び出し側が畳もうとしている仕事の続きなので
        // 引き継がない——引き継ぐと、捨てたはずの作業が後から蘇る。
        pending = nil
        launch(body, priority: priority)
    }

    /// 走行中なら「終わってからもう 1 回だけ」を予約する。走行中でなければすぐ始める。
    ///
    /// ⚠️ 予約は**捨てない**。捨てると「実行中に来た本物の変化」が消える
    /// （実例: 数え直しの最中に解析が終わり、完了直後の数字が凍る）。
    public func coalesce(priority: TaskPriority? = nil, _ body: @escaping () async -> Void) {
        guard isRunning else { launch(body, priority: priority); return }
        pending = body
        pendingPriority = priority
    }

    /// 明示的に止める。予約も捨てる。
    public func stop() {
        guard isRunning else { return }
        invalidateCurrent()
        isRunning = false
        pending = nil
        pendingPriority = nil
    }

    /// 走っている作業（と、その後に控えている予約）が全部終わるまで待つ。
    ///
    /// ⚠️ **止めた作業も待つ**。`cancel()` は「降りてくれ」と伝えるだけで、実行中の 1 単位は
    /// 最後まで走る。`reset` のように「本当に止まってからストアを消す」必要がある呼び出しが
    /// あるので、明け渡した/止めたハンドルも `retiring` に控えて待つ
    /// （待たずに消すと `FaceTagger.isRunning` が残り、次のスキャンが無言で skip される）。
    public func waitUntilIdle() async {
        while true {
            if !retiring.isEmpty {
                let stopped = retiring
                retiring.removeAll()
                for handle in stopped { await handle.value }
                continue
            }
            guard let current = task else { return }
            await current.value
        }
    }

    // MARK: - 内部

    /// 走行中のタスクを無効化する（世代を進めて、旧タスクの末尾処理を素通りさせる）。
    /// `isRunning` はここでは触らない——落とすかどうかは呼び出し側が決める。
    private func invalidateCurrent() {
        guard let current = task else { return }
        current.cancel()
        // ⚠️ ハンドルを**捨てない**（レビュー前の自己点検で発見した退行）。捨てると
        // `waitUntilIdle()` が即座に返り、「止めてからストアを消す」が成立しなくなる。
        retiring.append(current)
        if retiring.count > Self.retiringLimit { retiring.removeFirst() }
        task = nil
        generation &+= 1
    }

    private func launch(_ body: @escaping () async -> Void, priority: TaskPriority? = nil) {
        generation &+= 1
        let mine = generation
        isRunning = true
        task = Task(priority: priority) { [weak self] in
            await body()
            guard let self, self.generation == mine else { return }   // 自分の世代のときだけ片付ける
            self.task = nil
            if let next = self.pending {
                self.pending = nil
                let nextPriority = self.pendingPriority
                self.pendingPriority = nil
                self.launch(next, priority: nextPriority)   // 予約を 1 回だけ拾い直す
            } else {
                self.isRunning = false
            }
        }
    }
}

/// **連続する要求を 1 回にまとめる**（静止するまで待って 1 回だけ走る・ADR-198）。
///
/// 実機（diagnostics-38）では 1 分間に 30 回 `loadPeople()` が走り、その 1 回ごとに前面が
/// 600〜1000ms 固まっていた（1 分あたりのハング数＝発行回数と完全に一致）。一覧のような
/// 「最終的に正しければよい」表示は、静止するまで待って 1 回だけ出す（ADR-95）。
@MainActor
@Observable
public final class DebouncedTask {

    public private(set) var isScheduled = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let quietNanoseconds: UInt64
    /// 世代。末尾の後片付けを「自分がまだ最新のとき」だけ行うための札。
    @ObservationIgnored private var generation = 0

    /// - Parameter quietMilliseconds: 最後の要求からこの時間だけ静止したら実行する。
    public init(quietMilliseconds: UInt64) {
        self.quietNanoseconds = quietMilliseconds * 1_000_000
    }

    /// 要求する。前の予約は取り消され、静止時間が測り直される。
    ///
    /// ⚠️ **前の実行が body の途中なら、終わるまで待ってから静止時間を測る**（レビュー指摘）。
    /// ハンドルを保持するだけでは重複実行は防げない——`cancel()` は「降りてくれ」と伝えるだけで、
    /// `loadPeople()` のように取り消しを見ないコードは最後まで走る。待って初めて
    /// 「同時に 1 本」が成立する（ADR-95・diagnostics-38 の 600〜1000ms ハングの重なり）。
    ///
    /// ⚠️ **末尾の `task = nil` は世代で守る**（レビュー指摘）。守らないと、終わりかけの古い
    /// 実行が**新しい予約のハンドルを消す**。消えると次の `schedule()` の `cancel()` が空振りし、
    /// 取り消せない実行が 2 本並ぶ——間引きのために入れた仕組みが重複実行を作っていた。
    public func schedule(_ body: @escaping () async -> Void) {
        let previous = task
        previous?.cancel()
        isScheduled = true
        generation &+= 1
        let mine = generation
        task = Task { [weak self] in
            guard let self else { return }
            // 前の実行が走っている間は順番を待つ（取り消し済みなら即座に返る）。
            await previous?.value
            try? await Task.sleep(nanoseconds: self.quietNanoseconds)
            guard !Task.isCancelled, self.generation == mine else { return }
            self.isScheduled = false
            await body()
            guard self.generation == mine else { return }
            self.task = nil
        }
    }

    /// 予約を取り消す。
    public func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1        // 走行中のものに末尾の後片付けをさせない
        isScheduled = false
    }

    /// 予約された作業が終わるまで待つ（テスト用）。
    public func waitUntilIdle() async {
        while let current = task { await current.value }
    }
}
