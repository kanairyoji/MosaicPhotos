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
    /// ⚠️ 12 万件の refKey で約 12MB。期限（`canReuseCandidates`）が切れたら「使わない」だけでなく
    /// **捨てる**（ADR-226 追補）。持っていても作り直すので、抱えているぶんが丸ごと無駄。
    private var candidateCache: (candidates: AnalysisCandidateSet, at: Date)?
    private var lastKickAt = Date.distantPast
    /// 起こしても何も始まらなかった回数（＝残作業なし）。連続するほど間隔を空ける。
    private var emptyStreak = 0
    private var idleTicker: Task<Void, Never>?
    private var kicking = false
    /// 走行中に来た契機（1 つだけ畳んで拾い直す）。
    private var pendingTrigger: Trigger?
    /// 前回この枠で起こしたもの（ADR-237）。顔とタグ/埋め込みを**交互に**する札。
    /// ⚠️ 起動を跨いで覚えなくてよい（飢えないための交互で、公平さの厳密な保証は要らない）。
    private var lastTurn: AnalysisTurn.Choice = .none

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
        // ⚠️⚠️ **顔とタグ/埋め込みを同じ枠で同時に起こさない**（ADR-237・diagnostics-97）。
        // 以前はタグ/埋め込みを起こした直後に顔スキャンも起こしていた。ANE ゲートが**推論**を
        // 直列化するので動作は正しいが、**モデルは両方載ったまま**になる——CLIP の画像塔と
        // 顔モデルと Vision が同時に常駐し、14 秒で +248MB・最大 823MB まで上がっていた。
        // ANE ゲートは「同時に 1 つ推論しない」ための仕掛けで、「同時に 1 つ**載せる**」は
        // 誰も見ていなかった（ADR-223/226/228 は手放す側で、使い始めを重ねない側が抜けていた）。
        // 両方に残作業があるときは**前回と違う方**にして、どちらも飢えないようにする。
        // ⚠️⚠️ **残作業の数で顔を止めてはいけない**（自分で一度そう書いて気づいた）。
        // `faceBacklog` は `measureBacklogIfUnknown` が **nil のときだけ**測り、あとはスキャン側が
        // 更新する。つまり 1 度 0 になると、新しい写真が入っても 0 のままで——
        // それを「仕事が無い」と読むと**顔スキャンが永久に走らなくなる**。
        // 見るのは「もう片方が走っているか」だけにする（それがこの決まりの目的そのもの）。
        let turn = AnalysisTurn.next(facesRunning: people.isScanning,
                                    tagsRunning: engine.isTagging,
                                    faceScanPossible: people.isFaceModelAvailable,
                                    lastChoice: lastTurn)
        if turn != .none { lastTurn = turn }
        // ⚠️ **判断は必ず記録に出す**（実機ログ diagnostics-98 で踏んだ）。この行を書いたあと
        // 実装を整理する過程で消してしまい、実機確認の手順（G8「`driver: turn=` で交互に
        // なっている」）が**確かめられない状態**になっていた。
        // 見る手順が指している文字列は、消してはいけない。
        Diagnostics.mark("driver: turn=\(turn.rawValue) "
                         + "(scanning=\(people.isScanning) tagging=\(engine.isTagging))")

        // タグ → 埋め込み。処理枠は滞留した前面の実行を明け渡させてから始める（ADR-95）——
        // 眠ったまま実行中フラグを握られていると、窓が丸ごと空転する（diagnostics-38）。
        // ブーストの終了も同じ：`stop()` が直前にキャンセルした実行がまだフラグを持っている
        // （`scheduleBackgroundFill` は `isTagging` を見て素通りするので、起こし直せない）。
        let privileged = (trigger == .window || trigger == .boostEnded)
        if turn == .tags {
            if privileged {
                engine.restartBackgroundFill()
            } else {
                engine.scheduleBackgroundFill()
            }
        } else if AnalysisTurn.preemptsStalledTags(isPrivilegedTrigger: privileged, turn: turn,
                                                   tagsRunning: engine.isTagging) {
            // ⚠️ **明け渡しは順番の外**（レビューで見つけた・2026-09-29）。`next` はタグが
            // 走っていれば `.none` を返すので、`turn == .tags` でだけ restart していると
            // 「眠ったままフラグを握っている実行を明け渡させる」という窓の逃げ道が
            // **まさにその状況で消える**——枠（約 77 秒）が丸ごと空転する（diagnostics-38 の再来）。
            // 明け渡しは**置き換え**なので、モデルが 2 つ載ることはない（ADR-237 と矛盾しない）。
            engine.restartBackgroundFill()
            Diagnostics.mark("driver: 滞留していたタグ/埋め込みを明け渡させた（順番の外・窓/ブースト終了）")
        }

        // 顔（候補の列挙は短時間だけ使い回す）。
        // ⚠️ **順番が顔でなければ、候補の列挙もしない**。列挙は 8.5 万件・約 11 秒で、
        // 走らせない回にやると丸ごと無駄（しかも 8 万件級のコレクションが一時的に積み上がる）。
        if turn == .faces, people.isFaceModelAvailable, !people.isScanning {
            // ⚠️⚠️ **列挙する前に「変わり得たか」を見る**（ADR-247・実機ログ diagnostics-102）。
            // 下の列挙は 8.6 万件で約 11 秒・12 万件の refKey（約 12MB）を積むのに、解析が
            // 終わった端末では毎回「やることは無い」と知るためだけに払われていた。
            // 指紋は**母集合が動いたら必ず動く**ものだけ（クラウドの版・端末の枚数・
            // スキャン済み・候補から外した数）。⚠️ `faceBacklog` は入れない（ADR-237 の罠）。
            let fp = await currentCandidateFingerprint()
            if CandidateEnumerationGate.canSkip(fp, last: Self.storedCandidateFingerprint()) {
                Diagnostics.mark("driver: 候補の列挙を見送る（前回から変わっていない）")
                return engine.isTagging || people.isScanning
            }
            let candidates = await candidatesReusingCache(now: now)
            let allowSim = BackgroundYield.exemption == .debug
                || UserDefaults.standard.bool(forKey: AppSettingsKeys.faceScanOnSimulator)
            // ⚠️⚠️ **始める直前にもう一度見る**（実機ログ diagnostics-98 で踏んだ・ADR-196 と同じ形）。
            // 順番を決めた時点ではタグ/埋め込みは止まっていたが、この下の候補の列挙に**11 秒**
            // かかるので、その間に向こうが始まっていることがある。実機ではまさにそうなり、
            // 顔モデルと CLIP が同時に載って footprint が **942MB** まで上がった。
            // ADR-196 が言っている「入口の判定と 1 単位ごとの譲り判定は同じ式を使う」の通り
            // ——入口で「入ってよい」と言われたまま、長い準備のあとに確かめずに踏み込んでいた。
            if !Task.isCancelled, BackgroundYield.allows(.localTrickle), !engine.isTagging {
                people.startScan(candidateRefKeys: candidates.ordered, allowSimulator: allowSim)
            } else if engine.isTagging {
                Diagnostics.mark("driver: 顔の開始を見送る（列挙中にタグ/埋め込みが始まった）")
            }
            // ⚠️ **起こせなかった回こそ、残作業を測っておく**（ADR-207）。測らないと
            // 「終わったから 0」と「始められなかったから 0」が区別できず、完了の表示が嘘になる。
            // 取り消し・ゲートの再判定で降りた場合もここへ来る。
            // 測るのは**この起動で一度も測っていないとき**だけ（以後はスキャン側が更新する）。
            //
            // ⚠️ ただし**この構成では一生スキャンしない**ぶんは数えない（レビュー 5 周目）。
            // シミュレータは既定で顔スキャンを走らせないので、そこで残作業を数えると
            // ブーストが**永久に完了しない**（残りがあるのに誰も減らせない）。
            // 「まだ終わっていない」ではなく「ここでは行わない」なので、0 が正しい。
            if canScanFacesHere(allowSimulator: allowSim) {
                await people.measureBacklogIfUnknown(candidateRefKeys: candidates.ordered)
            }
            // ⚠️ 札を立てるのは「**本当にやることが無かった**」ときだけ（ADR-247）
            // （判断は `CandidateEnumerationGate.shouldRecord` ＝純ロジック・テスト対象）。
            // 判断は **DB の実数**で行う——⚠️⚠️ `faceBacklog` は使わない（ADR-237 の罠。
            // スキャン側しか更新しないので 0 に張り付き、札を立てたら永久に走らなくなる）。
            // 指紋は**列挙のあとに取り直す**（列挙中に写真が増えていたら、その版では覚えない）。
            let pending = await people.pendingCount(candidateRefKeys: candidates.ordered)
            if CandidateEnumerationGate.shouldRecord(pending: pending) {
                Self.storeCandidateFingerprint(await currentCandidateFingerprint())
                Diagnostics.mark("driver: 候補の札を立てた（残り 0・次からは列挙を飛ばせる）")
            } else {
                // ⚠️⚠️ **「効いた回数」だけでは足りなかった**（ADR-254・実機ログ 3 本ぶん）。
                // ADR-250 で「ゲートを足したら効いた回数が見えるログを付ける」と決めたが、
                // このゲートは**札が立っていないと絶対に効かない**種類で、
                // 「立たなかった」が記録に出ないため *なぜ* 効かないかが 2 回分からなかった。
                // 立たなかった回とその理由（残り枚数）も出す。
                Diagnostics.mark("driver: 候補の札を立てない（残り \(pending) 枚）")
            }
        }
        return engine.isTagging || people.isScanning
    }

    /// この端末・この設定で顔スキャンが**そもそも走り得るか**（ADR-207）。
    /// シミュレータは既定で走らせない（CLIP が cpuOnly で 1 枚数秒かかり検証の妨げになる）。
    private func canScanFacesHere(allowSimulator: Bool) -> Bool {
        #if targetEnvironment(simulator)
        return allowSimulator
        #else
        return true
        #endif
    }

    /// 背面で手放せるものを捨てる（ADR-226 追補）。次の窓で作り直す。
    func releaseCachesForBackground() {
        let had = candidateCache != nil
        candidateCache = nil
        people.releaseCachesForBackground()
        if had { Diagnostics.mark("driver: candidate cache released (background)") }
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
                // ⚠️ **前面で誰も使っていないモデルも手放す**（常駐メモリの棚卸し）。
                // 専用のタイマーは足さない——「アイドル中は定期的に方針を見直す」ための
                // 刻みが既にここにあるので、相乗りする（上のコメントと同じ理由）。
                self.releaseModelsIfIdle()
            }
        }
    }

    func stopIdleWatch() {
        idleTicker?.cancel()
        idleTicker = nil
    }

    /// **前面で一定時間まったく使われていないモデルを手放す**（常駐メモリの棚卸し）。
    ///
    /// ⚠️ ADR-223／ADR-226 追補の解放点は「窓の終わり」「顔スキャン 1 巡」「背面化」の 3 つで、
    /// どれも**前面にいる限り発火しない**。検索を 1 回すれば CLIP テキスト塔（実測 footprint
    /// 505MB）が載り、あとは critical 圧迫まで載りっぱなしになる。アプリを開いたまま置いて
    /// あるだけの時間は珍しくないので、ここが常駐の山として一番大きかった。
    ///
    /// ⚠️ **走っている解析からは取り上げない**。取り上げると、その場で 10〜35 秒の再ロードが
    /// 始まり、ANE ゲートの中なのでほかの推論も巻き添えで止まる。判断は背面側と**同じ場所**
    /// （`HeavyWorkScheduler`）に置く——2 つの解放点で条件が食い違うと、どちらが効いているのか
    /// 実機ログから切り分けられなくなる。
    private func releaseModelsIfIdle() {
        HeavyWorkScheduler.releaseModelsIfIdleInForeground()
    }

    // MARK: - 候補

    /// いまの候補の指紋（ADR-247・安い＝列挙を伴わない）。
    private func currentCandidateFingerprint() async -> CandidateEnumerationGate.Fingerprint {
        let photos = await analysisCandidateFingerprint(dropboxStore: dropboxStore)
        let ledger = await people.scanLedgerFingerprint()
        return .init(cloudRevision: photos.cloudRevision, localCount: photos.localCount,
                     scanned: ledger.scanned, unreadable: ledger.unreadable)
    }

    private static let fingerprintKey = "analysisCandidateFingerprint"

    static func storedCandidateFingerprint() -> CandidateEnumerationGate.Fingerprint? {
        guard let data = UserDefaults.standard.data(forKey: fingerprintKey) else { return nil }
        return try? JSONDecoder().decode(CandidateEnumerationGate.Fingerprint.self, from: data)
    }

    static func storeCandidateFingerprint(_ fp: CandidateEnumerationGate.Fingerprint) {
        guard let data = try? JSONEncoder().encode(fp) else { return }
        UserDefaults.standard.set(data, forKey: fingerprintKey)
    }

    private func candidatesReusingCache(now: Date) async -> AnalysisCandidateSet {
        if let cached = candidateCache {
            if AnalysisDriverPolicy.canReuseCandidates(cachedAt: cached.at, now: now) {
                PerfTrace.count("driver.candidates.reused")
                return cached.candidates
            }
            candidateCache = nil   // 期限切れ＝もう使わないので抱えない
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
