import AutoAlbumCore
import BackgroundTasks
import DropboxKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// 解析セッション（ADR-182）: 利用者が「今すぐ解析」で始める、顔・タグ・埋め込みの全力実行。
///
/// ## 入口は 1 つ
/// 旧「今すぐ解析（充電中・30 分）」と「この画面を開いている間、解析する」を統合した。
/// 中身は iOS 26 の `BGContinuedProcessingTask`（利用者が始めた作業をアプリを閉じても続け、
/// 進捗は Live Activity に出る）を軸にし、OS が受けてくれない場面は**前面のみ**に自動で落ちる。
///
/// ## 処理枠（HeavyWorkScheduler）との関係
/// - 走らせるのは同じトリクル（`PeopleEngine.startScan` / `AutoAlbumEngine.scheduleBackgroundFill`）。
///   ゲートは `BackgroundYield.sessionActive` で開ける（熱・一括ロード保護・生成との相互排他は残る）。
/// - セッション中に処理枠が開いても、解析の起動は重ねない（`isActive` を見て飛ばす）。
///   前面復帰の `stopForForeground` もセッションの作業は止めない。
/// - 一枚岩（生成・AI アルバムの本番化）は起こさない——始まると解析が止まる。
///
/// ## 進捗
/// OS は**進捗を報告しないタスクから殺す**。写真が 1 枚も終わらないモデルロードの間も
/// 「準備中」の目盛りを進める（`AnalysisSessionPolicy.warmupUnits`）。
///
/// ## 既知の制約（2026-09 時点）
/// 端末を本当にロックすると継続タスクが止まる iOS のバグ（FB19916760・DTS が認めた）。
/// 直るまでは「画面を点けたままにする」（既定 ON）が命綱。ロックで止まっても差分は残り、
/// 次の処理枠か次のタップで続きから進む。
@MainActor
@Observable
final class AnalysisSession {

    static let taskIdentifier = "com.kanai.MosaicPhotos.analyze"

    enum Mode: Equatable {
        /// OS の継続タスクに載っている（アプリを閉じても続く）。
        case continued
        /// 前面のみ（OS が受けなかった／シミュレータ）。画面を離れると止まる。
        case foregroundOnly
    }

    enum StopReason: Equatable {
        case finished        // 残作業ゼロ
        case user            // 停止ボタン・Live Activity の×
        case expired         // OS が止めた（熱・資源）
        case lowBattery      // 電源なしで電池が下限
        case leftScreen      // 前面のみモードで画面を離れた
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

    /// 画面を消灯させない（既定 ON）。設定として永続化。
    var keepScreenOn: Bool {
        get { UserDefaults.standard.object(forKey: AppSettingsKeys.analysisKeepScreenOn) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettingsKeys.analysisKeepScreenOn)
            if isActive { applyIdleTimer() }
        }
    }

    private let engine: AutoAlbumEngine
    private let people: PeopleEngine
    private let dropboxStore: DropboxPhotoStore

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var task: BGContinuedProcessingTask?
    @ObservationIgnored private var faceScanStarted = false
    @ObservationIgnored private var warmupTicks = 0
    @ObservationIgnored private var lastFillScheduledAt = Date.distantPast
    /// 同じ識別子を 2 回登録するとアプリが殺されるので、プロセス内で 1 回に絞る。
    @ObservationIgnored private static var registered = false

    init(engine: AutoAlbumEngine, people: PeopleEngine, dropboxStore: DropboxPhotoStore) {
        self.engine = engine
        self.people = people
        self.dropboxStore = dropboxStore
    }

    // MARK: - 開始・停止

    /// - Parameter autoResume: 中断されたセッションの自動再開か（画面を見ていない可能性がある）。
    ///   設定（`AnalysisContinuation`・ADR-193）が継続タスクを使う場面なのに **OS が受けなかった**
    ///   ときは、自動再開では走らせない——「使っている間は重い処理を動かさない」（ADR-25）を、
    ///   利用者が見ていないところで破らない。前面のみで走るのは、画面を開いているときだけ
    ///   （呼び出し側の `resumeIfPending(statusScreenOpen:)` が担保する）。
    func start(autoResume: Bool = false) {
        guard !isActive else { return }
        faceScanStarted = false
        warmupTicks = 0
        remaining = 0
        peakRemaining = 0
        didAutoResume = false
        BackgroundYield.sessionActive = true
        // 設定（ADR-193）が「アプリを離れても続ける」場面のときだけ、OS の継続タスクを要求する。
        // 要求しない段では最初から前面のみ＝インジケータは出ない。
        let level = AnalysisContinuation.current
        let wantsContinued = AnalysisContinuationPolicy.requestsContinuedTask(level, autoResume: autoResume)
        let mode: Mode = (wantsContinued && submitContinuedTask()) ? .continued : .foregroundOnly
        if autoResume, wantsContinued, mode == .foregroundOnly {
            // 継続タスクを使う設定なのに OS が受けなかった＝アプリを閉じたら止まる。自動再開で
            // それを始めると「見ていない前面」で重い処理が走り続ける。印は残して次の機会に譲る。
            BackgroundYield.sessionActive = false
            Diagnostics.mark("analyze: auto-resume deferred — the system did not accept a continued task")
            return
        }
        // ⚠️ **押した事実を永続化する**（diagnostics-81）。セッションはメモリ上の存在なので、
        // ロック（iOS の既知の問題）・OS の期限切れ・プロセス終了で消える。印が残っていれば
        // 次の前面復帰で自動再開でき、「夜に押したのに朝まで何も進んでいない」を防げる。
        Self.markPending(true)
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.analysisSessionInterruptedReason)
        state = .running(mode)
        applyModeGates()
        UIDevice.current.isBatteryMonitoringEnabled = true
        Diagnostics.mark("analyze: session start (\(mode)) continuation=\(level)")
        RunTimeline.record("session start (\(mode)・設定=\(level))\(autoResume ? " ＝自動再開" : "")")
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
        BackgroundYield.sessionYieldsToUI = false
        UIApplication.shared.isIdleTimerDisabled = false
        state = .stopped(reason)
        // 「終わった」「利用者が止めた」だけが完了。OS に止められた・電池・画面離脱は**未完**として
        // 印を残し、次の前面復帰で続きから再開する。
        // 本当に終わったときだけ、顔の残りを 0 として確定する（上の注記と対）。
        if reason == .finished { Self.lastKnownFaceRemaining = 0 }
        if AnalysisSessionPolicy.keepsPendingFlag(reason) {
            Self.markPending(true)
            let defaults = UserDefaults.standard
            defaults.set("\(reason)", forKey: AppSettingsKeys.analysisSessionInterruptedReason)
            defaults.set(Date(), forKey: AppSettingsKeys.analysisSessionInterruptedAt)
        } else {
            Self.markPending(false)
        }
        Diagnostics.mark("analyze: session stop (\(reason)) remaining=\(remaining)")
        RunTimeline.record("session stop (\(reason)) remaining=\(remaining)")
        RunTimeline.noteState("session", active: false)
        if let task {
            // 期限切れでも完了でも、必ず 1 回だけ呼ぶ（呼ばないと OS が次を受けなくなる）。
            task.setTaskCompleted(success: reason == .finished)
            self.task = nil
        }
    }

    /// OS が継続タスクを止めたときの受け身。**アプリが前面にあるなら止めない**——
    /// 電源につないで画面を見ている状況で「OS の都合」を理由に解析を終えるのは、
    /// 利用者から見れば「やりたい事ができない」だけ（実フィードバック）。前面のみモードへ
    /// 降格して走り続け、背面なら素直に止めて印を残す（次に開いたとき自動再開する）。
    private func continueInForegroundOrStop() {
        // 期限切れでも `setTaskCompleted` は必ず 1 回呼ぶ（呼ばないと OS が次を受けない）。
        if let task {
            task.setTaskCompleted(success: false)
            self.task = nil
        }
        // ⚠️ 降格してよいのは **AI 解析の状況を開いている**ときだけ（レビュー指摘）。
        // 前面のみモードを止められるのはその画面の `onDisappear`（`screenLeft`）だけなので、
        // 写真を見ている最中に降格すると**誰も止められないセッション**が残り、
        // `sessionActive` が立ちっぱなし＝電源・回線ポリシーが無効化され、画面も消えなくなる。
        guard isActive, BackgroundYield.isAppActive, statusScreenVisible else {
            stop(.expired)
            return
        }
        state = .running(.foregroundOnly)
        applyModeGates()
        Diagnostics.mark("analyze: continuing in the foreground (the system ended the continued task)")
        RunTimeline.record("session: 継続タスクが OS に止められた → 前面で続行")
    }

    /// モードに応じたゲートと画面消灯の設定。
    ///
    /// 前面のみモードでは **UI へ譲る**（スクロール・写真表示・サムネ取得中は休む）。
    /// 継続モードは画面が無い前提なので譲らない（全力）。前面で全力のまま走ると、
    /// 利用者が写真を見ている最中に ANE と CPU を奪ってカクつく（ADR-25 の趣旨）。
    private func applyModeGates() {
        BackgroundYield.sessionYieldsToUI = (mode == .foregroundOnly)
        applyIdleTimer()
    }

    /// AI 解析の状況が表示されているか（ビューが onAppear/onDisappear で報告する）。
    /// 前面のみモードが生きてよいのは、この画面が開いている間だけ。
    private(set) var statusScreenVisible = false

    /// AI 解析の状況が現れたとき（ビューの onAppear）。
    func screenAppeared() { statusScreenVisible = true }

    /// 前面のみモードで画面を離れたとき（ビューの onDisappear）。継続モードなら何もしない。
    func screenLeft() {
        statusScreenVisible = false
        if mode == .foregroundOnly { stop(.leftScreen) }
    }

    /// アプリが前面から外れたとき（`scenePhase` が active 以外）。
    ///
    /// ⚠️ 前面のみモードは**前面にいる間だけ**のもの。止めずに残すと `sessionActive` が
    /// 立ちっぱなしになり、電源・回線ポリシーの免除と画面消灯の抑止が効いたままになる
    /// （レビュー指摘）。やり残しの印は残るので、次に開いたときに続きから再開する。
    func appLeftForeground() {
        if mode == .foregroundOnly { stop(.leftScreen) }
    }

    // MARK: - 中断からの再開（diagnostics-81）

    /// 「今すぐ解析」を押したあと、まだ終わっていないか（プロセスを跨いで残る印）。
    static var isPending: Bool { UserDefaults.standard.bool(forKey: AppSettingsKeys.analysisSessionPending) }

    /// 中断の理由（表示用・未中断なら nil）。
    static var interruptedReason: String? {
        guard isPending else { return nil }
        return UserDefaults.standard.string(forKey: AppSettingsKeys.analysisSessionInterruptedReason)
    }

    /// 最後に観測した**顔スキャンの残り枚数**（プロセスを跨いで残す）。
    ///
    /// ⚠️ `PeopleEngine.remaining` はスキャン中しか更新されないので、新しいプロセスでは常に 0。
    /// かといって「モデルが同梱されているか」で代用すると、**残作業ゼロでも毎回セッションを
    /// 起こす**ことになり、8.5 万件の候補列挙・`sessionActive` による電源/回線ポリシーの無効化・
    /// ロック画面のインジケータまで無意味に走る（レビュー指摘）。観測できた値を持ち越す。
    /// ⚠️ **nil（未観測）と 0（残り無し）を区別する**（レビュー指摘）。`integer(forKey:)` は
    /// キーが無いときも 0 を返すので、それで判断すると「一度も観測していない端末」＝
    /// 「残っていない」になり、直そうとした不具合（顔だけ残った中断が再開されない）が戻る。
    private static var lastKnownFaceRemaining: Int? {
        get { UserDefaults.standard.object(forKey: AppSettingsKeys.analysisFaceRemaining) as? Int }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(max(0, newValue), forKey: AppSettingsKeys.analysisFaceRemaining)
        }
    }

    private static func markPending(_ pending: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(pending, forKey: AppSettingsKeys.analysisSessionPending)
        if !pending {
            defaults.removeObject(forKey: AppSettingsKeys.analysisSessionInterruptedReason)
            defaults.removeObject(forKey: AppSettingsKeys.analysisSessionInterruptedAt)
        }
    }

    /// 中断されたセッションを**自動で再開**する。アプリが前面に戻ったとき／起動直後に呼ぶ。
    ///
    /// 再開するのは「利用者が明示的に始めて、まだ終わっていない」ときだけ。止めたときは印を
    /// 下ろしてあるので再開しない。残作業ゼロなら再開せず印だけ下ろす（押したのに全部済んでいた場合）。
    /// - Parameter statusScreenOpen: AI 解析の状況を開いているか。継続タスクを使わない段では、
    ///   **開いているときだけ**自動再開する（見ていない前面で走らせないため）。
    func resumeIfPending(statusScreenOpen: Bool = false) async {
        guard !isActive, Self.isPending else { return }
        // プロセスが消えた場合は停止理由すら残らない。ここで「前回が終わっていない」ことを記録する。
        // ⚠️ 前面復帰のたびに呼ばれるので、記録はプロセスにつき 1 回だけ（ログを埋めない）。
        if !loggedUnfinished {
            loggedUnfinished = true
            Diagnostics.mark("analyze: previous session unfinished (\(Self.interruptedReason ?? "process ended"))")
        }
        // 自動再開は**電源接続が必須**（ADR-193）。外出先でアプリを開いただけで走り出し、
        // 電池を食う／インジケータが出るのを防ぐ。手動で押したときは従来どおり免除。
        let level = AnalysisContinuation.current
        guard AnalysisContinuationPolicy.allowsAutoResume(level,
                                                          onPower: PowerStateMonitor.shared.isOnPower,
                                                          statusScreenOpen: statusScreenOpen) else {
            Diagnostics.mark("analyze: auto-resume skipped — "
                             + "power=\(PowerStateMonitor.shared.isOnPower) "
                             + "screen=\(statusScreenOpen) continuation=\(level)")
            return
        }
        let progress = await engine.analysisProgress()
        let pending = max(0, progress.total - progress.sceneTagged) + max(0, progress.total - progress.embedded)
        // 顔の残りは**前回観測した値**で判断する（`people.remaining` は新しいプロセスでは 0 で、
        // 「残っていない」と「分からない」の区別が付かない）。一度も観測していない端末では
        // 「分からない」＝再開してセッション自身に終わりを判定させる。
        // 未観測（nil）は「分からない」＝再開してセッション自身に終わりを判定させる。
        let faceBacklog = people.isFaceModelAvailable ? (Self.lastKnownFaceRemaining ?? .max) : 0
        guard pending > 0 || faceBacklog > 0 else {
            Diagnostics.mark("analyze: nothing left — clearing pending session")
            Self.markPending(false)
            return
        }
        // ⚠️ ここまでに **DB カウントで待っている**（全件）。その間に利用者が画面を戻ると、
        // `onDisappear` → `screenLeft()` が先に走り、閉じた画面のために前面のみモードの
        // セッションが立ち上がる＝誰も止められない（レビュー指摘）。直前にもう一度見る。
        guard !Task.isCancelled,
              AnalysisContinuationPolicy.allowsAutoResume(level,
                                                          onPower: PowerStateMonitor.shared.isOnPower,
                                                          statusScreenOpen: statusScreenVisible) else {
            Diagnostics.mark("analyze: auto-resume aborted — the screen closed while counting")
            return
        }
        Diagnostics.mark("analyze: auto-resuming (pending=\(pending))")
        start(autoResume: true)
        didAutoResume = isActive    // start() が false に戻すので、その後に立てる
    }

    /// 直近の開始が**自動再開**だったか（画面の案内用）。
    private(set) var didAutoResume = false

    /// 「前回が終わっていない」をこのプロセスで既に記録したか（前面復帰のたびに書かない）。
    @ObservationIgnored private var loggedUnfinished = false

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
                Diagnostics.mark("analyze: continued task expired by the system")
                self?.continueInForegroundOrStop()
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
            // 観測できた残りを持ち越す（プロセスが死んでも次の起動で判断できる）。
            // ⚠️ **スキャンが終わった＝残り 0 ではない**（レビュー指摘）。顔スキャンは
            // クラウドのサムネ未取得や譲り待ちで**残作業を抱えたまま畳む**ので、そこで 0 を
            // 書くと次の起動で「もう無い」と誤判定する。0 を書くのは本当に終わったとき
            // （`stop(.finished)`）だけにする。
            if people.isScanning, people.remaining > 0 { Self.lastKnownFaceRemaining = people.remaining }
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
            // 顔スキャンは 1 セッション 1 回（空振りで畳んだ分＝クラウドのサムネ未取得は次回へ）。
            let faceSettled = !people.isFaceModelAvailable || (faceScanStarted && !people.isScanning)
            if AnalysisSessionPolicy.isFinished(remaining: rem, tagging: engine.isTagging,
                                                scanning: people.isScanning, faceScanSettled: faceSettled) {
                stop(.finished); return
            }
        }
    }

    @ObservationIgnored private var tagsPending = 0
    @ObservationIgnored private var embedPending = 0

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
