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
///   ゲートは `BackgroundYield.sessionActive` で開ける（熱・一括ロード保護・生成との相互排他・
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

    private let engine: AutoAlbumEngine
    private let people: PeopleEngine
    private let dropboxStore: DropboxPhotoStore

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var task: BGContinuedProcessingTask?
    @ObservationIgnored private var faceScanStarted = false
    @ObservationIgnored private var warmupTicks = 0
    @ObservationIgnored private var lastFillScheduledAt = Date.distantPast
    @ObservationIgnored private var tagsPending = 0
    @ObservationIgnored private var embedPending = 0
    /// 同じ識別子を 2 回登録するとアプリが殺されるので、プロセス内で 1 回に絞る。
    @ObservationIgnored private static var registered = false

    init(engine: AutoAlbumEngine, people: PeopleEngine, dropboxStore: DropboxPhotoStore) {
        self.engine = engine
        self.people = people
        self.dropboxStore = dropboxStore
    }

    // MARK: - 開始・停止

    /// 「今すぐ解析」。利用者の明示操作なので、電源・回線・アイドルの条件は見ない。
    func start() {
        guard !isActive else { return }
        faceScanStarted = false
        warmupTicks = 0
        remaining = 0
        peakRemaining = 0
        BackgroundYield.sessionActive = true
        let mode: Mode = submitContinuedTask() ? .continued : .foregroundOnly
        state = .running(mode)
        applyIdleTimer()
        UIDevice.current.isBatteryMonitoringEnabled = true
        Diagnostics.mark("analyze: boost start (\(mode))")
        RunTimeline.record("boost start (\(mode))")
        RunTimeline.noteState("session", active: true)
        loop = Task { [weak self] in await self?.runLoop() }
    }

    func stop(_ reason: StopReason = .user) {
        guard isActive else { return }
        loop?.cancel()
        loop = nil
        people.stopScan()
        engine.stopBackgroundWork()
        BackgroundYield.sessionActive = false
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
    /// 前面のみモードは**前面にいる間だけ**のもの。止めずに残すと `sessionActive` が立ちっぱなしになり、
    /// 電源・回線ポリシーの免除と画面消灯の抑止が効いたままになる。継続モードは OS が面倒を見る。
    func appLeftForeground() {
        if mode == .foregroundOnly { stop(.leftApp) }
    }

    // MARK: - BGContinuedProcessingTask

    /// OS の継続タスクに載せる。受けてもらえなければ false（前面のみで続ける）。
    private func submitContinuedTask() -> Bool {
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

    private func runLoop() async {
        let allowSim = UserDefaults.standard.bool(forKey: AppSettingsKeys.faceScanOnSimulator)
        if people.isFaceModelAvailable, !people.isScanning {
            let candidates = await analysisCandidates(dropboxStore: dropboxStore)
            guard !Task.isCancelled else { return }
            // 無くなった写真の顔を先に掃除する（サムネの出ない・開けない顔が一覧に残る）。
            // 候補から外したバックアップコピー（端末に原本あり）も「無い」扱いで消す。
            await people.pruneMissingPhotos(candidateRefKeys: candidates.ordered,
                                            knownGone: candidates.excludedBackupCopies)
            guard !Task.isCancelled else { return }
            people.startScan(candidateRefKeys: candidates.ordered, allowSimulator: allowSim)
        }
        faceScanStarted = true
        scheduleFillIfIdle()

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
            let faces = people.isScanning ? people.remaining : 0
            let rem = AnalysisSessionPolicy.remaining(faces: faces, tagsPending: tagsPending,
                                                      embedPending: embedPending)
            if rem == remaining { warmupTicks += 1 }
            remaining = rem
            peakRemaining = max(peakRemaining, rem)
            publishProgress()

            // タグは 1 回の実行に上限があるので、止まっていて残りがあれば次を起こす。
            if tagsPending + embedPending > 0 { scheduleFillIfIdle() }

            if AnalysisSessionPolicy.shouldStopForBattery(onPower: PowerStateMonitor.shared.isOnPower,
                                                          level: UIDevice.current.batteryLevel) {
                stop(.lowBattery); return
            }
            // 顔スキャンは 1 ブースト 1 回。空振りで畳んだ分（クラウドのサムネ未取得など）は
            // 方針（駆動役・処理枠）が次の機会に拾う——ここで「終わったか」を厳密に確定する必要は無い。
            // 早めに `.finished` になっても、失うものは無い（続きは方針が進める）。
            let faceSettled = !people.isFaceModelAvailable || (faceScanStarted && !people.isScanning)
            if AnalysisSessionPolicy.isFinished(remaining: rem, tagging: engine.isTagging,
                                                scanning: people.isScanning, faceScanSettled: faceSettled) {
                stop(.finished); return
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
