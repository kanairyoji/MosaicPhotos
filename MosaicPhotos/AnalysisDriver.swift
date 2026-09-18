import AutoAlbumCore
import DropboxKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// `analysisCandidates(dropboxStore:)` が返す候補（処理順つき）と、除外したバックアップコピー。
typealias AnalysisCandidateSet = (ordered: [String], excludedBackupCopies: Set<String>)

/// **常設の方針を評価して、残作業を進める駆動役**（ADR-195）。
///
/// ## なぜ要るか
/// 以前は前面で解析を起こす場所が無かった。起動時の 1 回と電源/回線の復帰時だけで、
/// 「充電してアプリを開いたまま」でも何も進まず、それを埋めるために「今すぐ解析」に
/// 自動再開（ADR-189）を足した結果、5 つの軸が絡んで 9 周壊れ続けた（case-studies）。
///
/// ## 何をするか
/// **条件が変わった瞬間**（起動・前面復帰・20 秒アイドル・電源・回線・ブーストの終了。熱の回復や
/// 写真の追加のように合図が来ない条件は、アイドル中 120 秒ごとの再評価で拾う）に
/// 方針（`BackgroundYield.heavyWorkAllowedLocal`）を見て、許されていれば既存のトリクル
/// （`scheduleBackgroundFill` / `startScan`）を起こす。それだけ。トリクルは差分処理で、
/// 操作されれば 1 単位ごとに譲り、60 秒開かなければ自分で畳む（ADR-95）。畳んだあとは、
/// 次に条件が変わったときにここがまた起こす。**「再開」という概念は無い**——残作業が状態。
///
/// ## しないこと
/// - 背面（処理枠）では動かない。そこは `HeavyWorkScheduler` が同じトリクルを起こす。
/// - ブースト（「今すぐ解析」）中は動かない。重ねて起こす意味が無い。
/// - 一枚岩（生成・本番化）は起こさない（`monolithicHeavyWorkAllowed`＝ADR-107 の管轄）。
@MainActor
final class AnalysisDriver {

    /// 起こす契機。方針の再評価が要るのは「条件が変わった瞬間」だけ。
    enum Trigger: String {
        case launch, foreground, idle, power, network, boostEnded
    }

    private let engine: AutoAlbumEngine
    private let people: PeopleEngine
    private let dropboxStore: DropboxPhotoStore
    private let session: AnalysisSession

    /// 顔スキャンの候補（8.5 万件の列挙＝数秒）は短時間だけ使い回す。
    private var candidateCache: (candidates: AnalysisCandidateSet, at: Date)?
    private var lastKickAt = Date.distantPast
    private var idleTicker: Task<Void, Never>?
    private var kicking = false

    init(engine: AutoAlbumEngine, people: PeopleEngine,
         dropboxStore: DropboxPhotoStore, session: AnalysisSession) {
        self.engine = engine
        self.people = people
        self.dropboxStore = dropboxStore
        self.session = session
        // ブーストが終わったら方針に戻る（電源＋アイドルなら続きをこちらが進める）。
        session.onStopped = { [weak self] in Task { @MainActor in await self?.kick(.boostEnded) } }
    }

    // MARK: - 契機

    /// 条件が変わったときに呼ぶ。方針が許していれば残作業を起こす。
    func kick(_ trigger: Trigger) async {
        let now = Date()
        let decision = AnalysisDriverPolicy.decide(
            trigger: trigger,
            appActive: BackgroundYield.isAppActive,
            allowed: BackgroundYield.heavyWorkAllowedLocal,
            boostActive: session.isActive,
            sinceLastKick: now.timeIntervalSince(lastKickAt))
        guard decision == .kick else {
            if trigger != .idle {   // アイドルの契機は 5 秒ごとに来るので、静かに見送る
                Diagnostics.mark("driver: \(trigger.rawValue) → \(decision)")
            }
            return
        }
        guard !kicking else { return }
        kicking = true
        defer { kicking = false }
        lastKickAt = now
        Diagnostics.mark("driver: \(trigger.rawValue) → kick")
        RunTimeline.record("driver kick (\(trigger.rawValue))")

        // タグ → 埋め込み（実行中なら no-op・ゲート待ちは内部で行う）。
        engine.scheduleBackgroundFill()

        // 顔（候補の列挙は短時間だけ使い回す）。
        guard people.isFaceModelAvailable, !people.isScanning else { return }
        let candidates = await candidatesReusingCache(now: now)
        guard !Task.isCancelled, BackgroundYield.heavyWorkAllowedLocal else { return }
        let allowSim = UserDefaults.standard.bool(forKey: AppSettingsKeys.faceScanOnSimulator)
        people.startScan(candidateRefKeys: candidates.ordered, allowSimulator: allowSim)
    }

    /// 前面にいる間、20 秒アイドルを検知して起こす（`scenePhase == .active` で始め、離れたら止める）。
    /// アイドル中は 120 秒ごとに方針を見直すので、**熱の回復や写真の追加のような「変わった合図が
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
        if let cached = candidateCache, now.timeIntervalSince(cached.at) < AnalysisDriverPolicy.candidateReuse {
            return cached.candidates
        }
        let fresh = await analysisCandidates(dropboxStore: dropboxStore)
        candidateCache = (fresh, now)
        // 無くなった写真の顔を先に掃除する（サムネの出ない・開けない顔が一覧に残る）。
        // 候補を取り直したときだけ＝数秒〜数十秒に 1 回以上は走らせない。
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
        /// 方針が許していない（電源・回線・アイドル・自動処理オフ・熱）。
        case notAllowed
        /// ブースト中（重ねない）。
        case boostActive
        /// 直前に起こしたばかり（アイドルの契機だけ間引く）。
        case throttled
    }

    /// アイドルの契機で起こす最小間隔。5 秒ごとの検知を、そのまま毎回起こさない。
    static let idleKickInterval: TimeInterval = 120
    /// 顔スキャンの候補の使い回し時間。
    static let candidateReuse: TimeInterval = 10 * 60

    static func decide(trigger: AnalysisDriver.Trigger,
                       appActive: Bool,
                       allowed: Bool,
                       boostActive: Bool,
                       sinceLastKick: TimeInterval) -> Decision {
        guard appActive else { return .background }
        guard !boostActive else { return .boostActive }
        guard allowed else { return .notAllowed }
        if trigger == .idle, sinceLastKick < idleKickInterval { return .throttled }
        return .kick
    }
}
