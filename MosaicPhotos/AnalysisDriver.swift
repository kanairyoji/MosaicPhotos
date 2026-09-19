import AutoAlbumCore
import DropboxKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// `analysisCandidates(dropboxStore:)` が返す候補（処理順つき）と、除外したバックアップコピー。
typealias AnalysisCandidateSet = (ordered: [String], excludedBackupCopies: Set<String>)

/// **常設の方針を評価して、残作業を進める駆動役**（ADR-195 → ADR-196）。
///
/// ## なぜ要るか
/// 以前は前面で解析を起こす場所が無かった。起動時の 1 回と電源/回線の復帰時だけで、
/// 「充電してアプリを開いたまま」でも何も進まず、それを埋めるために「今すぐ解析」に
/// 自動再開（ADR-189）を足した結果、5 つの軸が絡んで 9 周壊れ続けた（case-studies）。
///
/// ## 何をするか
/// **条件が変わった瞬間**（起動・前面復帰・20 秒アイドル・電源・回線・処理枠・ブーストの
/// 開始/終了）にゲート（`BackgroundYield.verdict`）を見て、許されていれば既存のトリクル
/// （`scheduleBackgroundFill` / `startScan`）を起こす。それだけ。トリクルは差分処理で、
/// 操作されれば 1 単位ごとに譲り、60 秒開かなければ自分で畳む（ADR-95）。畳んだあとは、
/// 次に条件が変わったときにここがまた起こす。**「再開」という概念は無い**——残作業が状態。
///
/// ## 起こす前口上は**ここにしかない**（ADR-196）
/// 候補の列挙（8.5 万件）→ 消えた写真の掃除 → 顔スキャン → タグ/埋め込み、の 4 手は
/// かつて駆動役・ブースト（`AnalysisSession.runLoop`）・処理枠（`HeavyWorkScheduler`）の
/// **3 か所に別々に**書かれており、3 つとも微妙に違った（キャッシュの有無・`schedule` と
/// `restart` の違い）。いまはブーストも処理枠も `kick(_:)` を呼ぶ。
///
/// ## しないこと
/// - 一枚岩（生成・本番化）は起こさない（`HeavyWork.localMonolith` / `.cloudMonolith` の管轄）。
/// - すでに走っているなら何もしない（処理枠だけは例外＝明け渡させて始め直す・ADR-95）。
@MainActor
final class AnalysisDriver {

    /// 起こす契機。方針の再評価が要るのは「条件が変わった瞬間」だけ。
    enum Trigger: String {
        /// 起動直後（人物のロード後に 1 回）。
        case launch
        /// 前面復帰（`scenePhase == .active`）。
        case foreground
        /// 前面で 20 秒以上触っていない（アイドル監視）。
        case idle
        /// 電源・低電力モードの変化。
        case power
        /// 回線の変化。
        case network
        /// OS の処理枠（`HeavyWorkScheduler`）。**滞留した実行を明け渡させて始め直す**。
        case window
        /// 「今すぐ解析」を押した。
        case boost
        /// ブーストが終わった（方針に戻る）。
        case boostEnded
    }

    private let engine: AutoAlbumEngine
    /// ⚠️ スキャンの**断面**だけを持つ（ADR-198）。編集・レビュー API へは手を伸ばせない。
    private let people: FaceScanControl
    private let dropboxStore: DropboxPhotoStore
    private let session: AnalysisSession

    /// 顔スキャンの候補（8.5 万件の列挙＝数秒）は短時間だけ使い回す。
    private var candidateCache: (candidates: AnalysisCandidateSet, at: Date)?
    private var lastKickAt = Date.distantPast
    /// 起こしても何も始まらなかった回数（＝残作業なし）。連続するほど間隔を空ける。
    private var emptyStreak = 0
    private var idleTicker: Task<Void, Never>?
    private var kicking = false
    /// 走行中に来た契機（1 つだけ畳んで拾い直す）。
    private var pendingTrigger: Trigger?

    init(engine: AutoAlbumEngine, people: FaceScanControl,
         dropboxStore: DropboxPhotoStore, session: AnalysisSession) {
        self.engine = engine
        self.people = people
        self.dropboxStore = dropboxStore
        self.session = session
        // ブーストの開始/終了は、どちらもこの駆動役を通す（前口上はここにしかない・ADR-196）。
        session.onStart = { [weak self] in await self?.kick(.boost) }
        // 終わったら方針に戻る（電源＋アイドルなら続きをこちらが進める）。
        session.onStopped = { [weak self] in Task { @MainActor in await self?.kick(.boostEnded) } }
    }

    // MARK: - 契機

    /// 条件が変わったときに呼ぶ。方針が許していれば残作業を起こす。
    func kick(_ trigger: Trigger) async {
        let now = Date()
        let decision = AnalysisDriverPolicy.decide(
            trigger: trigger,
            scenePhase: BackgroundYield.scenePhase,
            verdict: BackgroundYield.verdict(for: .localTrickle),
            boostActive: session.isActive,
            workRunning: engine.isTagging || people.isScanning,
            sinceLastKick: now.timeIntervalSince(lastKickAt),
            emptyStreak: emptyStreak)
        guard decision == .kick else {
            // アイドルの契機は 5 秒ごとに来るので、見送りは静かに。
            if trigger != .idle { Diagnostics.mark("driver: \(trigger.rawValue) → \(decision)") }
            return
        }
        // ⚠️ 契機が重なっても前口上（8.5 万件の列挙）を 2 本走らせない。
        // 走行中に来た契機は**畳んで 1 回だけ拾い直す**（捨てると本物の条件変化が消える）。
        guard !kicking else { pendingTrigger = trigger; return }
        kicking = true
        lastKickAt = now

        PerfTrace.count("driver.prologue")
        let started = await runPrologue(trigger: trigger, now: now)
        if started {
            emptyStreak = 0
            Diagnostics.mark("driver: \(trigger.rawValue) → kick (started)")
            // ⚠️ 実行台帳は「1 日に数十行」の前提で数か月ぶんを保つ（diagnostics-81 の教訓）。
            // 空振りの起こしまで書くと、起動・窓の履歴を押し流してしまう。
            RunTimeline.record("driver kick (\(trigger.rawValue))")
        } else {
            emptyStreak += 1
            Diagnostics.mark("driver: \(trigger.rawValue) → kick (nothing to do, streak=\(emptyStreak))")
        }
        kicking = false

        if let next = pendingTrigger {
            pendingTrigger = nil
            await kick(next)
        }
    }

    /// 残作業を起こす**唯一の前口上**。戻り値＝実際に何かが走り始めたか。
    private func runPrologue(trigger: Trigger, now: Date) async -> Bool {
        // タグ → 埋め込み。処理枠は滞留した前面の実行を明け渡させてから始める（ADR-95）——
        // 眠ったまま実行中フラグを握られていると、窓が丸ごと空転する（diagnostics-38）。
        // ブーストの終了も同じ：`stop()` が直前にキャンセルした実行がまだフラグを持っている
        // （`scheduleBackgroundFill` は `isTagging` を見て素通りするので、起こし直せない）。
        if trigger == .window || trigger == .boostEnded {
            engine.restartBackgroundFill()
        } else {
            engine.scheduleBackgroundFill()
        }

        // 顔（候補の列挙は短時間だけ使い回す）。
        if people.isFaceModelAvailable, !people.isScanning {
            let candidates = await candidatesReusingCache(now: now)
            if !Task.isCancelled, BackgroundYield.allows(.localTrickle) {
                let allowSim = BackgroundYield.exemption == .debug
                    || UserDefaults.standard.bool(forKey: AppSettingsKeys.faceScanOnSimulator)
                people.startScan(candidateRefKeys: candidates.ordered, allowSimulator: allowSim)
            }
        }
        return engine.isTagging || people.isScanning
    }

    /// 前面にいる間、20 秒アイドルを検知して起こす（`scenePhase == .active` で始め、離れたら止める）。
    /// アイドル中は定期的に方針を見直すので、**熱の回復や写真の追加のような「変わった合図が
    /// 来ない条件」もここで拾う**（専用の契機を足すより、再評価が安いので 1 本に寄せる）。
    func startIdleWatch() {
        idleTicker?.cancel()
        idleTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                if BackgroundActivityMonitor.shared.idleSeconds >= HeavyWorkTiming.foregroundIdleSeconds {
                    await self.kick(.idle)
                }
            }
        }
    }

    func stopIdleWatch() {
        idleTicker?.cancel()
        idleTicker = nil
    }

    // MARK: - 候補

    private func candidatesReusingCache(now: Date) async -> AnalysisCandidateSet {
        if let cached = candidateCache,
           AnalysisDriverPolicy.canReuseCandidates(cachedAt: cached.at, now: now) {
            PerfTrace.count("driver.candidates.reused")
            return cached.candidates
        }
        // ⚠️ ここが規模に比例する（PHAsset の列挙＋クラウド 68k 件の並べ替え・ADR-119）。
        // 回数を数えられるようにしておく（`PerfTrace.takeCounts()`）。
        PerfTrace.count("driver.candidates.enumerated")
        let fresh = await analysisCandidates(dropboxStore: dropboxStore)
        candidateCache = (fresh, now)
        // 無くなった写真の顔を先に掃除する（サムネの出ない・開けない顔が一覧に残る）。
        // 候補を取り直したときだけ＝数分に 1 回以上は走らせない。
        await people.pruneMissingPhotos(candidateRefKeys: fresh.ordered, knownGone: fresh.excludedBackupCopies)
        return fresh
    }
}

/// 駆動役の判断（純ロジック・テスト対象）。
enum AnalysisDriverPolicy {

    enum Decision: Equatable {
        case kick
        /// 背面（処理枠の管轄）。
        case background
        /// ゲートが閉じている（電源・回線・アイドル・自動処理オフ・熱…）。
        case notAllowed
        /// ブースト中（重ねない）。
        case boostActive
        /// すでに走っている（前口上の代金を払わない）。
        case alreadyRunning
        /// 直前に起こしたばかり（アイドルの契機だけ間引く）。
        case throttled
    }

    /// アイドルの契機で起こす最小間隔。5 秒ごとの検知を、そのまま毎回起こさない。
    static let idleKickInterval: TimeInterval = 60
    /// 顔スキャンの候補の使い回し時間。
    static let candidateReuse: TimeInterval = 600

    /// 候補（8.5 万件の列挙）を使い回してよいか（純ロジック・テスト対象）。
    /// ⚠️ 列挙は PHAsset の走査＋クラウド 68k 件の並べ替えで、ライブラリ規模に比例する。
    /// 起こすたびに払うと ADR-119 の「1 回ぶんに見える呼び出しが、実は規模に比例していた」になる。
    static func canReuseCandidates(cachedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(cachedAt)
        return age >= 0 && age < candidateReuse
    }

    /// 空振りが続いたときの待ち時間（指数・上限 30 分）。
    ///
    /// ⚠️ 残作業が無いのに起こすと、毎回 86k 件（`enrichedRefKeysNewestFirst`）と
    /// 75k 件（`scannedRefKeys`）を読む。5 秒ごとの検知に素直に従うと、充電しながら
    /// アプリを開いているだけで 1 時間に数十回これを繰り返す（CLAUDE.md「無いものを
    /// 繰り返し探さない」）。解除は「条件が変わった」契機（`.power` / `.network` /
    /// `.window` / `.boostEnded` は間引かない）と、実際に仕事が始まったとき。
    static func idleInterval(emptyStreak: Int) -> TimeInterval {
        switch emptyStreak {
        case ..<1:  return idleKickInterval        // 60s
        case 1:     return 120
        case 2:     return 300
        case 3:     return 900
        default:    return 1800
        }
    }

    static func decide(trigger: AnalysisDriver.Trigger,
                       scenePhase: BackgroundYield.ScenePhaseKind,
                       verdict: BackgroundYield.Verdict,
                       boostActive: Bool,
                       workRunning: Bool,
                       sinceLastKick: TimeInterval,
                       emptyStreak: Int) -> Decision {
        // 処理枠とブーストの開始は、呼び出し側が文脈を持っている（背面・ゲート免除）。
        // ⚠️ 処理枠は**走行中でも**起こす——窓は特権時間なので、滞留した前面の実行を
        // 明け渡させてから始め直す（ADR-95・diagnostics-38 で窓 77 秒が丸ごと空転した）。
        if trigger == .window { return .kick }
        if trigger == .boost { return boostActive ? .kick : .notAllowed }

        guard scenePhase != .background else { return .background }
        guard !boostActive else { return .boostActive }
        // ⚠️ すでに走っているなら何もしない。前口上（候補列挙・`scannedRefKeys`）は
        // ライブラリ規模に比例するので、「起こすだけ」のつもりで毎回払ってはいけない。
        guard !workRunning else { return .alreadyRunning }
        guard verdict.allowed else { return .notAllowed }
        if trigger == .idle, sinceLastKick < idleInterval(emptyStreak: emptyStreak) { return .throttled }
        return .kick
    }
}
