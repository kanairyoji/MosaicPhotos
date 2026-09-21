import AutoAlbumCore
import BackgroundTasks
import DropboxKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// 解析の**ブースト**（ADR-182 → ADR-195）: 利用者が「今すぐ解析」で始める、顔・タグ・埋め込みの全力実行。
///
/// ## 位置づけ
/// 自動の解析は常設の方針（`AnalysisDriver`＝条件が揃っていれば進める）が担う。
/// ブーストはその方針を**一時的に上書きする**だけ——電源・回線・アイドルの条件を無視して全力で進め、
/// iOS 26 の継続タスク（`BGContinuedProcessingTask`・利用者が始めた作業をアプリを閉じても続ける・
/// 進捗は Live Activity に出る）を試す。OS が受けてくれない場面は前面のみで走る。
///
/// ## 永続化しない・再開しない
/// ブーストは**メモリ上だけ**の存在で、終わったら（完了・停止・OS の期限切れ・電池・アプリを離れた）
/// 単に方針に戻る。以前はここに「押した事実の永続化と自動再開」（ADR-189）があり、
/// 電源・画面・継続タスク・手動/自動・クールダウンの 5 軸が絡んで 9 周壊れ続けた。
/// 方針が前面でも進めるようになった今、ブーストが死んでも進捗は止まらないので、再開は要らない。
///
/// ## 処理枠（HeavyWorkScheduler）・駆動役（AnalysisDriver）との関係
/// - 走らせるのは同じトリクル（`PeopleEngine.startScan` / `AutoAlbumEngine.scheduleBackgroundFill`）。
///   ゲートは `BackgroundYield.exemption = .boost` で開ける（熱・電池・一括ロード保護・生成との相互排他・
///   前面での UI への譲りは残る）。
/// - ブースト中は処理枠も駆動役も解析を重ねて起こさない（`isActive` を見て飛ばす）。
/// - 一枚岩（生成・AI アルバムの本番化）は起こさない——始まると解析が止まる。
///
/// ## 進捗
/// OS は**進捗を報告しないタスクから殺す**。写真が 1 枚も終わらないモデルロードの間も
/// 「準備中」の目盛りを進める（`AnalysisSessionPolicy.warmupUnits`）。
///
/// ## 既知の制約（2026-09 時点）
/// 端末を本当にロックすると継続タスクが止まる iOS のバグ（FB19916760・DTS が認めた）。
/// 直るまでは「画面を点けたままにする」（既定 ON・ブースト中だけ）が命綱。止まっても差分は残り、
/// 方針（充電中に開けば前面で進む／処理枠）が続きを進める。
@MainActor
@Observable
final class AnalysisSession {

    static let taskIdentifier = "com.kanai.MosaicPhotos.analyze"

    enum Mode: Equatable {
        /// OS の継続タスクに載っている（アプリを閉じても続く）。
        case continued
        /// 前面のみ（OS が受けなかった／シミュレータ）。アプリを離れると止まる。
        case foregroundOnly
    }

    enum StopReason: Equatable {
        case finished        // 残作業ゼロ
        /// 残作業はあるが、ゲートが閉じていてこれ以上進めない（熱・メモリ・生成中・回線…）。
        /// ⚠️ ここを `.finished` に丸めると「すべて解析済みです」と嘘を表示し、
        /// OS には `setTaskCompleted(success: true)` を返す（レビュー指摘）。
        case blocked([BackgroundYield.Blocker])
        /// 残作業はあるが、**止めている条件は無い**（スキャンが畳まれた・この構成では
        /// 走らせられない）。⚠️ ここを `.finished` に丸めると、また「すべて解析済みです」に
        /// 戻る——`.blocked([])` も同じ穴だったので、理由を持つ形にして塞ぐ（ADR-207）。
        case incomplete(remaining: Int)
        case user            // 停止ボタン・Live Activity の×
        case expired         // OS が止めた（熱・資源・ロック）
        case lowBattery      // 電源なしで電池が下限
        case leftApp         // 前面のみモードでアプリを離れた
    }

    enum State: Equatable {
        case idle
        case running(Mode)
        case stopped(StopReason)
    }

    private(set) var state: State = .idle
    /// 進捗（表示用）。`peakRemaining` はこのセッションで観測した残作業の最大値。
    private(set) var remaining = 0
    private(set) var peakRemaining = 0

    var isActive: Bool { if case .running = state { return true } else { return false } }
    var mode: Mode? { if case .running(let m) = state { return m } else { return nil } }

    /// アプリを離れても「今すぐ解析」を続けるか（既定 ON・ADR-197）。
    ///
    /// ⚠️ OFF は「解析を止める設定」ではない——**OS の継続タスクを使わない**という意味で、
    /// 結果としてロック画面と Dynamic Island の進捗インジケータが出なくなる（あの表示は
    /// アプリからは消せない。そもそも進捗を報告しないタスクは OS が殺す）。
    /// 夜間の自動解析はどちらでも動く。
    var continueAfterLeaving: Bool {
        get { UserDefaults.standard.object(forKey: AppSettingsKeys.analysisContinueAfterLeaving) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettingsKeys.analysisContinueAfterLeaving)
            // ⚠️ **その場で効かせる**（レビュー指摘）。このトグルの目的はロック画面と
            // Dynamic Island のインジケータを消すことなので、走行中に切ったときに
            // 次回まで出たままだと「効かない設定」に見える。継続タスクだけ降ろして
            // 前面のみモードで走り続ける（解析は止めない）。
            if !newValue, mode == .continued { downgradeToForegroundOnly() }
        }
    }

    /// 継続タスクを降りて前面のみモードにする（解析は続ける）。
    private func downgradeToForegroundOnly() {
        if let task {
            task.setTaskCompleted(success: false)
            self.task = nil
        }
        state = .running(.foregroundOnly)
        Diagnostics.mark("analyze: downgraded to foreground-only (setting)")
    }

    /// 画面を消灯させない（既定 ON・ブースト中だけ効く）。設定として永続化。
    var keepScreenOn: Bool {
        get { UserDefaults.standard.object(forKey: AppSettingsKeys.analysisKeepScreenOn) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettingsKeys.analysisKeepScreenOn)
            if isActive { applyIdleTimer() }
        }
    }

    /// 終わったときに呼ばれる（駆動役が方針へ戻すために使う）。
    @ObservationIgnored var onStopped: (() -> Void)?
    /// 始めるときに呼ばれる。**残作業を起こす前口上は駆動役が持つ唯一のもの**（ADR-196）。
    /// 以前はここにも同じ 4 手（候補列挙 → 掃除 → 顔スキャン → タグ/埋め込み）が書いてあり、
    /// 駆動役・処理枠と合わせて 3 コピーが微妙に違っていた。
    @ObservationIgnored var onStart: (() async -> Void)?

    private let engine: AutoAlbumEngine
    /// ⚠️ スキャンの**断面**だけを持つ（ADR-198）。
    private let people: FaceScanControl
    private let dropboxStore: DropboxPhotoStore

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var task: BGContinuedProcessingTask?
    @ObservationIgnored private var warmupTicks = 0
    @ObservationIgnored private var lastFillScheduledAt = Date.distantPast
    @ObservationIgnored private var tagsPending = 0
    @ObservationIgnored private var embedPending = 0
    /// 同じ識別子を 2 回登録するとアプリが殺されるので、プロセス内で 1 回に絞る。
    @ObservationIgnored private static var registered = false

    init(engine: AutoAlbumEngine, people: FaceScanControl, dropboxStore: DropboxPhotoStore) {
        self.engine = engine
        self.people = people
        self.dropboxStore = dropboxStore
    }

    // MARK: - 開始・停止

    /// 「今すぐ解析」。利用者の明示操作なので、電源・回線・アイドルの条件は見ない。
    func start() {
        guard !isActive else { return }
        warmupTicks = 0
        remaining = 0
        peakRemaining = 0
        BackgroundYield.setExemption(.boost)
        let mode: Mode = submitContinuedTask() ? .continued : .foregroundOnly
        state = .running(mode)
        applyIdleTimer()
        UIDevice.current.isBatteryMonitoringEnabled = true
        Diagnostics.mark("analyze: boost start (\(mode))")
        RunTimeline.record("boost start (\(mode))")
        RunTimeline.noteState("session", active: true)
        loop = Task { [weak self] in
            // 前口上 → 進捗の監視。前口上を待ってから監視に入るので、
            // 「顔スキャンがまだ始まっていない」状態で完了判定が走ることはない。
            await self?.onStart?()
            await self?.watchProgress()
        }
    }

    func stop(_ reason: StopReason = .user) {
        guard isActive else { return }
        loop?.cancel()
        loop = nil
        people.stopScan()
        engine.stopBackgroundWork()
        BackgroundYield.setExemption(.none)
        UIApplication.shared.isIdleTimerDisabled = false
        state = .stopped(reason)
        Diagnostics.mark("analyze: boost stop (\(reason)) remaining=\(remaining)")
        RunTimeline.record("boost stop (\(reason)) remaining=\(remaining)")
        RunTimeline.noteState("session", active: false)
        if let task {
            // 期限切れでも完了でも、必ず 1 回だけ呼ぶ（呼ばないと OS が次を受けなくなる）。
            task.setTaskCompleted(success: reason == .finished)
            self.task = nil
        }
        onStopped?()
    }

    /// アプリが前面から外れたとき（`scenePhase == .background`）。
    /// 前面のみモードは**前面にいる間だけ**のもの。止めずに残すと免除（`.boost`）が残ったままになり、
    /// 電源・回線ポリシーの免除と画面消灯の抑止が効いたままになる。継続モードは OS が面倒を見る。
    func appLeftForeground() {
        if mode == .foregroundOnly { stop(.leftApp) }
    }

    // MARK: - BGContinuedProcessingTask

    /// OS の継続タスクに載せる。受けてもらえなければ false（前面のみで続ける）。
    private func submitContinuedTask() -> Bool {
        // 利用者が「アプリを開いている間だけ」を選んでいれば、継続タスクは取らない
        // ＝インジケータも出ない（ADR-197）。
        guard continueAfterLeaving else { return false }
        #if targetEnvironment(simulator)
        return false
        #else
        if !Self.registered {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                // DTS の勧め: 中で仕事はせず、タスクを捕まえて返す（仕事は runLoop が回している）。
                Task { @MainActor in
                    guard let session = HeavyWorkScheduler.stores?.analysisSession else {
                        task.setTaskCompleted(success: false); return
                    }
                    session.attach(task)
                }
            }
            Self.registered = ok
            guard ok else {
                Diagnostics.mark("analyze: continued task register failed (identifier not permitted?)")
                return false
            }
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: L("Analyzing photos"),
            subtitle: L("Faces, tags, and the search index"))
        // 今すぐ始められないなら受けない（待たせず前面のみに落ちる）。
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            Diagnostics.mark("analyze: continued task not accepted — \(error.localizedDescription)")
            return false
        }
        #endif
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        guard isActive else { task.setTaskCompleted(success: false); return }
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                // OS に止められたら、ブーストはここで終わり。続きは方針（駆動役・処理枠）が進める。
                Diagnostics.mark("analyze: continued task expired by the system")
                self?.stop(.expired)
            }
        }
        publishProgress()
    }

    private func applyIdleTimer() {
        // 画面が消えると（自動ロック）継続タスクが止まる iOS の既知の問題への備え。
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }

    // MARK: - 実行ループ

    /// 進捗を測って画面と Live Activity に出し、終わりを判定する。**起こす仕事は持たない**。
    private func watchProgress() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, isActive else { return }
            tick += 1
            // 分母（タグ・埋め込みの残数）は DB カウントなので 10 秒に 1 回だけ取る。
            if tick % 5 == 1 {
                let p = await engine.analysisProgress()
                guard !Task.isCancelled else { return }
                tagsPending = max(0, p.total - p.sceneTagged)
                embedPending = max(0, p.total - p.embedded)
            }
            // ⚠️ **2 つの「残り」を混ぜない**（ADR-207・レビュー 6 周目）。
            // - `runnableFaces`: **いま動かせる**顔の残り。止まれば 0 になるので、
            //   「この周でまだ何か走っているか」の判断に使う。これを本当の残作業に
            //   置き換えると、畳んだあと誰も減らせない数が残り続けて
            //   **ブーストが永久に終わらない**（進捗も止まったまま）。
            // - `faceBacklog`: **本当の残作業**。止める理由を決めるときに使う
            //   ——0 でないのに「すべて解析済み」と言わないため。
            let runnableFaces = people.isScanning ? people.remaining : 0
            let faces = runnableFaces
            let rem = AnalysisSessionPolicy.remaining(faces: faces, tagsPending: tagsPending,
                                                      embedPending: embedPending)
            if rem == remaining { warmupTicks += 1 }
            remaining = rem
            peakRemaining = max(peakRemaining, rem)
            publishProgress()

            // タグは 1 回の実行に上限があるので、止まっていて残りがあれば次を起こす。
            if tagsPending + embedPending > 0 { scheduleFillIfIdle() }

            // 電池の下限はゲートの表の行（ブーストでも外れない・ADR-196）。
            // 以前はここだけに下限があり、電源ポリシー「常に」だと停止直後に方針が
            // 同じ処理を再開していた（レビュー指摘）。
            let verdict = BackgroundYield.verdict(for: .cloudTrickle)
            if verdict.blocks(.lowBattery) { stop(.lowBattery); return }
            // ⚠️ 「いま順番を譲っている」だけの条件は完了判定に混ぜない（レビュー指摘）。
            // 混ぜると、写真を見ている最中に解析が終わったときに
            // 「写真を見ているので止まっています」と**嘘を表示する**。
            let blocking = verdict.persistentBlockers

            // 顔スキャンは 1 ブースト 1 回。畳んだあとに残作業が見えていれば、
            // **それは「終わった」ではなく「止められている」**——ゲートに理由を聞いて区別する。
            if AnalysisSessionPolicy.isFinished(remaining: rem, tagging: engine.isTagging,
                                                scanning: people.isScanning) {
                stop(AnalysisSessionPolicy.stopReason(blockers: blocking,
                                                      faceBacklog: people.faceBacklog ?? 0)); return
            }
        }
    }

    private func scheduleFillIfIdle() {
        guard !engine.isTagging, Date().timeIntervalSince(lastFillScheduledAt) > 5 else { return }
        lastFillScheduledAt = Date()
        engine.scheduleBackgroundFill()
    }

    private func publishProgress() {
        guard let task else { return }
        let units = AnalysisSessionPolicy.progressUnits(peakRemaining: peakRemaining, remaining: remaining,
                                                        warmupTicks: warmupTicks)
        task.progress.totalUnitCount = units.total
        task.progress.completedUnitCount = units.completed
    }
}
