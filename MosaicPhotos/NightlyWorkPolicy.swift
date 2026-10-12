import Foundation

/// 夜間ウィンドウで「この窓は何をする窓か」を決める純ロジック（ADR-163/166）。
///
/// ⚠️ 判定を `HeavyWorkScheduler` に直書きすると、**BGTask を起こさないと確かめられない**
/// ＝実質テストできない。窓の使い方は実機で 2 度失敗している（生成と解析の共倒れ・
/// バックアップの飢餓）ので、条件はここに出してテストで固定する。
enum NightlyWorkPolicy {

    // MARK: - アルバム生成を見送るか（ADR-163）

    /// 解析（顔・埋め込み）の残作業があるうちは生成を見送る。ただし**連続見送りの上限**で
    /// 順番を回す——生成も飢えさせない（バックアップの公平性ルール＝ADR-72 と同じ形）。
    enum GenerateDecision: Equatable {
        /// 見送る（値は「これで連続何回目か」＝記録する値）。
        case defer_(streak: Int)
        /// 実行する（値は直前までの連続見送り回数＝ログ用。実行時は 0 に戻す）。
        case run(afterDeferrals: Int)
    }

    /// - Parameter faceBacklog: 顔の残作業。**nil＝分からない**（ADR-252）。
    ///   ⚠️ nil を 0 に丸めてはいけない。以前 `gatherInputs` が
    ///   `faceBacklog ?? scanProgressRemaining` と書いていて、`scanProgressRemaining` は
    ///   スキャン中以外 0 なので——**「分からない」が「終わった」になっていた**。
    ///   分からないときは「あるかもしれない」側に倒す（見送りには上限があるので飢えない）。
    static func generateDecision(embedBacklog: Int, faceBacklog: Int?,
                                 deferrals: Int, maxDeferrals: Int) -> GenerateDecision {
        let hasBacklog = embedBacklog > 0 || (faceBacklog ?? 1) > 0
        guard hasBacklog, deferrals < maxDeferrals else { return .run(afterDeferrals: deferrals) }
        return .defer_(streak: deferrals + 1)
    }

    // MARK: - 週 1 回の照合（ADR-166）

    /// 前回からの経過が `interval` を超えたか。**記録が無ければ実行する**
    /// （初回は必ず 1 回走らせて基準時刻を作る）。
    static func isReconcileDue(lastRun: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}

// MARK: - 窓の手順（ADR-196）

/// 処理枠（BGProcessingTask）で「何を・どの順でやるか」の**判断**（純ロジック・テスト対象）。
///
/// ⚠️ 以前は `HeavyWorkScheduler.runHeavyWork` が 142 行の直列手続きで、9 つの責務と
/// `Task.isCancelled` の確認 4 か所を抱え、**テストが 1 本も無かった**。窓の使い方は実機で
/// 繰り返し失敗している（生成と解析の共倒れ＝diagnostics-72、バックアップの飢餓＝ADR-72、
/// 顔/埋め込みが開始すらしない＝Fix C）ので、順序と条件はここに出して固定する。
enum NightlyPlan {

    /// 判断に要る入力（すべて呼び出し側が測って渡す）。
    struct Inputs: Equatable {
        /// ブースト（「今すぐ解析」）が走っているか。走っていれば解析は重ねて起こさない。
        var boostActive: Bool
        var embedBacklog: Int
        /// 顔の残作業。**nil＝分からない**（この起動で一度も測っておらず、前の起動の記録も無い）。
        /// ⚠️ 0 と混ぜない（ADR-207/252）。
        var faceBacklog: Int?
        var generateDeferrals: Int
        var maxGenerateDeferrals: Int
        /// 空きメモリ（MB）。generate はピークが大きい（実測 550〜880MB）。
        var availableMB: Int
        var networkAllowed: Bool
        var provideShareEnabled: Bool
        /// バックアップ台帳の週次照合の期限が来ているか（ADR-206）。
        /// ⚠️ **手順の位置がこれで変わる**（来ている週だけバックアップの前に出す）。
        var backupReconcileDue: Bool
        /// 同じ Dropbox の人へ解析を公開するか（ADR-222）。
        /// ⚠️ **既定は OFF**（`ShareSettingsKeys.publishAnalysisDefault == false`）。
        /// 以前ここと早見表に「既定 ON」と書いてあった（ADR-222 追補 3 で変えたのに直し忘れ）。
        var publishAnalysisEnabled: Bool
        /// 撮影日時を**まだ訊いていない**クラウド写真の枚数（ADR-257）。
        /// ⚠️ 材料の約束: `exifProbedAt == nil` の `fetchCount` ＝**訊いていない**ものだけ。
        /// 「訊いたが無かった」は含めない（含めると毎晩同じ写真を訊き続ける）。
        var captureDateBacklog: Int

        init(boostActive: Bool = false, embedBacklog: Int = 0, faceBacklog: Int? = 0,
             generateDeferrals: Int = 0, maxGenerateDeferrals: Int = 4,
             availableMB: Int = 2048, networkAllowed: Bool = true,
             provideShareEnabled: Bool = false, backupReconcileDue: Bool = false,
             publishAnalysisEnabled: Bool = false, captureDateBacklog: Int = 0) {
            self.boostActive = boostActive
            self.embedBacklog = embedBacklog
            self.faceBacklog = faceBacklog
            self.generateDeferrals = generateDeferrals
            self.maxGenerateDeferrals = maxGenerateDeferrals
            self.availableMB = availableMB
            self.networkAllowed = networkAllowed
            self.provideShareEnabled = provideShareEnabled
            self.backupReconcileDue = backupReconcileDue
            self.publishAnalysisEnabled = publishAnalysisEnabled
            self.captureDateBacklog = captureDateBacklog
        }
    }

    /// 窓の 1 手。**見送り・スキップも手として残す**（何を決めたかが台帳に出る）。
    enum Step: Equatable {
        /// 解析（顔・タグ・埋め込み）を起こす＝駆動役へ委譲。
        case startAnalysis
        /// ブーストが同じトリクルを全力で回しているので重ねない。
        case skipAnalysisBoostActive
        /// 「動くべきなのに動いていない」パスを診断ログへ（ADR-87）。
        case logStalledPasses
        /// 夜間バックアップ（ADR-180: 毎窓・解析と並行）。
        case startBackup
        case generate
        case deferGenerate(streak: Int)
        case skipGenerateLowMemory(availableMB: Int)
        case shareImport
        case shareSync
        /// クラウド写真の解析を `<root>/<端末>/Analysis` へ公開（ADR-222）。
        case publishAnalysis
        /// クラウド写真の**撮影日時**を少しずつ訊く（ADR-257）。値は この枠の上限（枚）。
        case probeCaptureDates(limit: Int)
        /// バックアップ台帳と実体の照合（週 1・内部で期限を見る）。
        case reconcileBackup
        /// クラウドの軽い表の控えを、いまの表で書き直す（ADR-266/270）。
        /// ⚠️ **毎回入れる**（崩す経路が 2 つあるので、崩れたかを条件にしない）。
        /// ⚠️ 回線は要らない／**窓を使い切る手より前**に置く。
        case refreshCloudIndexSnapshot
        /// 残作業が続く限り待つ（期限切れ＝キャンセルで抜ける）。
        case drainUntilIdle

        /// 手の種類（付随値を落とした識別子・ADR-272）。性質の宣言と `after` の指定に使う。
        var kind: Kind {
            switch self {
            case .startAnalysis, .skipAnalysisBoostActive:          return .analysis
            case .logStalledPasses:                                 return .stallCheck
            case .refreshCloudIndexSnapshot:                        return .indexSnapshot
            case .reconcileBackup:                                  return .reconcile
            case .startBackup:                                      return .backup
            case .generate, .deferGenerate, .skipGenerateLowMemory:  return .generate
            case .shareImport:                                      return .shareImport
            case .publishAnalysis:                                  return .publishAnalysis
            case .probeCaptureDates:                                return .captureDates
            case .shareSync:                                        return .shareSync
            case .drainUntilIdle:                                   return .drain
            }
        }

        /// 台帳・診断ログ用の短い名前。
        var label: String {
            switch self {
            case .startAnalysis:                   return "analysis"
            case .skipAnalysisBoostActive:         return "analysis(skip:boost)"
            case .logStalledPasses:                return "stallCheck"
            case .startBackup:                     return "backup"
            case .generate:                        return "generate"
            case .deferGenerate(let s):            return "generate(defer:\(s))"
            case .skipGenerateLowMemory(let mb):   return "generate(skip:\(mb)MB)"
            case .shareImport:                     return "shareImport"
            case .shareSync:                       return "shareSync"
            case .publishAnalysis:                 return "publishAnalysis"
            case .probeCaptureDates(let n):        return "captureDates(\(n))"
            case .reconcileBackup:                 return "reconcile"
            case .refreshCloudIndexSnapshot:       return "indexSnapshot"
            case .drainUntilIdle:                  return "drain"
            }
        }
    }

    /// **1 つの枠で訊く撮影日時の上限**（ADR-257）。
    ///
    /// ⚠️ 1 枚 1 往復（`get_metadata`・実測 200ms 前後）で 4 並列なので、500 枚＝約 25 秒。
    /// 枠は数分あるが、ここは**解析・バックアップと同じ枠を分け合う**ので欲張らない。
    /// 実機の残り 105,662 枚なら 1 晩 3〜4 枠で 1,500〜2,000 枚＝**2 か月ほどで一巡**する。
    /// ⚠️ それでも遅いが、1 枚ずつしか訊けない API（ADR-201）なので上限は通信量の問題。
    /// 増やすなら Dropbox のレート制限を実測してからにする。
    static let captureDateProbeLimit = 500

    /// generate を動かすのに要る空きメモリ（MB）。
    /// 足りないと BG の厳しい jetsam 上限に触れてアプリごと kill され、進捗が振り出しに戻る。
    static let minimumGenerateMB = 900

    /// この窓の手順を決める。
    ///
    /// 順序の根拠（どれも実機の失敗が出典・動かすときは対応するテストを見ること）:
    /// 1. **解析を先に起こす**。窓は短く（数秒〜数分で expire）、generate を先に await すると
    ///    窓を食い潰して顔/埋め込みが開始すらしない（Fix C）。
    /// 2. **バックアップは解析と並行**。ディスク読み＋通信で CPU/ANE をほぼ使わないので
    ///    資源が重ならない（ADR-180・以前の「見送り」は事実上始まらなかった＝diagnostics-20）。
    /// 3. **generate は残作業があるうちは見送る**。生成は `isGeneratingAlbums` を立て、
    ///    解析がそれを見て譲るので、同じ窓で両方やると窓が丸ごと空転する（diagnostics-72）。
    ///    ただし連続見送りの上限で順番を回す（生成も飢えさせない・ADR-163）。
    /// 窓の先頭の 1 手（解析を起こす）。**残りの手順より先に実行する**——顔の残作業は
    /// 起こしたあとでないと測れない（`PeopleEngine.scanProgressRemaining` はスキャン中しか更新されない）。
    static func analysisStep(boostActive: Bool) -> Step {
        boostActive ? .skipAnalysisBoostActive : .startAnalysis
    }

    static func steps(_ i: Inputs) -> [Step] {
        [analysisStep(boostActive: i.boostActive)] + remainingSteps(i)
    }

    // MARK: - 手の性質（並びは「宣言」から導く・ADR-272）

    /// ⚠️⚠️ **なぜ並べるのをやめたか**: 並びの誤りで**同じ形の欠陥が 4 回**出た
    /// （ADR-206 照合・ADR-222 追補 公開・ADR-257 撮影日時・ADR-270 控え）。
    /// どれも「**上限のない手の後ろに、上限のある軽い手を置いた**」——後ろの手は
    /// 窓が尽きて**一度も順番が回ってこない**。⚠️ うち 2 回は「ここに置くな」を
    /// 自分で書いた直後に自分が踏んだ。`out.append` の行はどれも同じ見た目で、
    /// 制約はコメントにしか無かったから（注意力では直らない）。
    ///
    /// だから**手に性質を宣言させ、並びを導く**。新しい手は `bounded: true` と書くだけで
    /// 正しい位置に入る——作者が「どの手が窓を食うか」を思い出す必要がない。
    ///
    /// ⚠️ 宣言するのは**仕事の性質**（上限があるか・通信するか）で、
    /// **環境の数値**（窓は何秒か）ではない。窓が 30 秒でも 10 分でも規則は変わらないので、
    /// iOS の変更に強い。⚠️ 時間割り当て（所要を見積って詰め込む）は**採らない**
    /// ——iOS は残り時間を教えず（`expirationHandler` だけ）、窓は実測 21〜284 秒（13.5 倍）、
    /// 1 手の所要も 3〜10 倍振れる。測れない数に依存する設計は、
    /// テストできる並びの誤りを**テストできない見積りの誤り**に取り替えるだけ（ADR-272）。
    /// **その手が窓をどれだけ塞ぐか**（ADR-272 追補・独立レビューの指摘で 2 段 → 3 段）。
    ///
    /// ⚠️⚠️ 最初は `bounded: Bool` の 2 段にして、`backup` を「上限なし」と宣言した。
    /// **間違い**だった——`startBackup` は `backupEngine.startNightlyIfEnabled()` を呼ぶだけで
    /// **即座に返る**（仕事は engine が裏で続ける）。
    /// つまり「**仕事が長い**」と「**手が窓を塞ぐ**」を混同していた。並びに効くのは後者。
    /// その結果 40 秒かかる撮影日時の問い合わせが `backup` の**前**に出て、
    /// 短い窓（実測 21 秒）ではバックアップが**その晩まったく進まない**ところだった（ADR-180「毎窓」）。
    enum Cost: Int, CaseIterable {
        /// 投げっぱなし＝即座に返る（仕事は裏で続く）。**窓を塞がないので最初に出す**。
        case nonblocking = 0
        /// 上限つき（件数・秒・シャード数）。
        case bounded = 1
        /// 窓の期限まで走り得る。
        case unbounded = 2
    }

    /// ⚠️ `Comparable` は持たない（並びは比較子ではなく**分割**で作る＝`order(_:)`）。
    /// 以前は `<` を書いていたが、分割に変えた時点で**誰も使っていない死んだ実装**になっていた
    /// （独立レビューの指摘）。
    enum Phase: Int, CaseIterable {
        /// 投げっぱなしで始める手（他の手の裏で走らせたいので最初）。
        case kick = 0
        /// 本体。
        case work = 1
        /// 期限まで待つ手（後ろに手は置けない）。
        case drain = 2
    }

    /// 手の種類（`Step` の付随値を落とした識別子。`after` の指定に使う）。
    enum Kind: String, CaseIterable {
        case analysis, stallCheck, indexSnapshot, reconcile, backup, generate
        case shareImport, publishAnalysis, captureDates, shareSync, drain
    }

    struct Spec {
        var phase: Phase = .work
        /// **その手が窓をどれだけ塞ぐか**（`Cost` に理由を詳述）。
        /// ⚠️ 迷ったら `.unbounded`（短く偽ると、本当に短い手を飢えさせる）。
        /// ⚠️ 見るのは「**手が返るまで**」で、仕事が裏で続く長さではない。
        var cost: Cost
        /// **回線が許可されない窓では、この手を並べないか**（ADR-272 追補）。
        ///
        /// ⚠️ 「通信するか」ではない。`backup` と `generate` は通信を**する**が、
        /// 回線の可否は**それぞれの engine が内部で見る**（早見表の回線 ○ はその内部判定のこと）。
        /// 計画から落とすのは「回線が無いと**やることが何も無い**手」だけ
        /// ——落とすべきでない手を落とすと、ローカルにできる仕事まで止まる。
        /// ⚠️ **この値を読むのは `applicableSteps` の最後の filter だけ**で、
        /// 回線の判定は**ここが唯一の出典**（同じ判断を 2 か所に書かない・ADR-196）。
        /// 名付けの経緯と、読まれない宣言を置いてしまった失敗は ADR-272 追補に書いてある。
        var dropWhenOffline: Bool
        /// ⚠️ **性質に還元できない前提**（資源の競合・意味の順序）。ここだけは明示する。
        var after: [Kind] = []

        /// **どんなに短い窓でも、この手には順番が回らなければならないか**（ADR-274）。
        ///
        /// ⚠️ これは**製品の要件**で、性質（`cost`）から導けない
        /// ——「毎窓バックアップする」（ADR-180）「毎窓控えを書き直す」（ADR-266）は
        /// 速さの話ではなく「そうでないと機能が成り立たない」という決めだから。
        /// ⚠️ 逆に**速さの話はここに入れない**。撮影日時（ADR-257）は
        /// 「2 か月で一巡する**見込み**」＝throughput なので `false` にして、
        /// 「残作業が減り続ける」側で測る（ADR-274 追補 2・独立レビューの指摘で降格）。
        /// ⚠️⚠️ **既定値を置かない**（ADR-196）——置いた版では 11 の手のうち 6 つが
        /// 「答えずに済む」ことになり、実際その穴から `publishAnalysis` が漏れた。
        /// ⚠️ 読み手は 2 つ——`requiredEveryWindowKinds` 経由で
        /// **本番の飢餓ログ**（`HeavyWorkScheduler`・ADR-250 の「効いた回数が見えるログ」）と
        /// `NightlyWindowSimulator`（テスト）。
        /// ⚠️ 当初は「読むのはテストだけ」にしていたが、**本番が読まない宣言は
        /// 実態とずれても検出できない**（ADR-273 で消した `needsNetwork` と同じ形）。
        /// ⚠️ ただし
        /// **「`after` の相手が上限なしで、同じ窓に居る」ときは免除**される
        /// （＝照合の週のバックアップ・ADR-206 が認めた遅れ）。免除は `after` と `cost` から
        /// **導出**するので、ここに例外のリストを書き足さない（ADR-196）。
        var everyWindow: Bool
    }

    #if DEBUG
    /// ⚠️ **テスト専用の差し替え**（Release には存在しない）。
    /// `BackgroundYield.environmentOverrideForTesting` と同じ作法で、
    /// `NightlyWindowSimulator.withSpecOverride` のスコープからだけ入れる。
    ///
    /// ⚠️⚠️ **`spec(for:)` の中に置くのが要点**。模型の側に「宣言を読む別の口」を作った版では、
    /// 偽りが `order` / `applicableSteps` に**届かず並びが変わらなかった**ため、
    /// 「過去の欠陥を再現する」はずのテストが**別の仕組みで通っていた**
    /// （ADR-274 追補 2・独立レビュー 2 件が同時に指摘）。宣言を読む口は 1 つ（ADR-196）。
    static var specOverrideForTesting: ((Kind) -> Spec?)?
    #endif

    static func spec(for kind: Kind) -> Spec {
        #if DEBUG
        if let overridden = specOverrideForTesting?(kind) { return overridden }
        #endif
        return declaredSpec(for: kind)
    }

    /// 宣言の**唯一の出典**。⚠️ 直接呼ぶのは `spec(for:)` だけ
    /// （ここを直接読むと、テストの偽りが届かない口がもう 1 つできる）。
    private static func declaredSpec(for kind: Kind) -> Spec {
        switch kind {
        case .analysis:
            // 投げっぱなし（`kick` は背景の Task を起こすだけ）。他の手の裏で走らせたい。
            // 毎窓（解析が進まなければアプリの売りが成り立たない）。⚠️ ただし `phase: .kick` で
            // **常に先頭**なので、飢餓としては原理的に出ない——「宣言したから守られている」のではなく
            // 「段で守られている」。模型側は宣言の集合を**そのまま**assert する（数ではなく集合）。
            return Spec(phase: .kick, cost: .nonblocking, dropWhenOffline: false, everyWindow: true)
        case .stallCheck:
            // 毎回（ADR-87）。「動くべきなのに動いていない」を見つける唯一の経路。
            return Spec(cost: .bounded, dropWhenOffline: false, everyWindow: true)
        case .indexSnapshot:
            // 16MB を 1 回書くだけ（鍵が同じなら書かない）。回線は要らない。
            // **毎窓**（ADR-266: 鍵を崩す経路が 2 つあるので「崩れたか」を条件にしない）。
            return Spec(cost: .bounded, dropWhenOffline: false, everyWindow: true)
        case .reconcile:
            // Dropbox の全件一覧（ADR-206）＝上限なし。回線が無ければやることが無い。
            // 週 1 なので毎窓ではない（内部で期限を見る）。
            return Spec(cost: .unbounded, dropWhenOffline: true, everyWindow: false)
        case .backup:
            // 毎窓・1 回あたりの上限なし＝窓の期限が上限（ADR-180）。
            // ⚠️ **照合の後**——`.startBackup` は `isRunning` を立て、照合は
            // `guard !isBusy` で門前払いされる（資源の競合・性質では表せない）。
            // ⚠️ **回線が無くても並べる**。転送の可否は `BackupEngine` が内部で見る
            // （落とすと、読み取り・spool・台帳の整合などローカルにできる仕事まで止まる）。
            // ⚠️⚠️ **投げっぱなし**（`startNightlyIfEnabled()` は即座に返り、engine が裏で続ける）。
            // 窓を塞がないので最初に出す——ここを `.unbounded` と偽ったせいで、
            // 40 秒の撮影日時の問い合わせが前に出て、短い窓（21 秒）では
            // バックアップが**その晩まったく進まない**ところだった（独立レビューの指摘）。
            return Spec(cost: .nonblocking, dropWhenOffline: false, after: [.reconcile],
                        everyWindow: true)   // 毎窓（ADR-180）
        case .generate:
            // 550〜880MB・数十秒（`minimumGenerateMB` が在る理由）。
            // ⚠️ **回線が無くても並べる**（クラウド一覧はキャッシュから読める・内部で判定）。
            // 毎窓ではない——ADR-163 が「`maxGenerateDeferrals + 1` 窓以内に順番が来る」
            // という**順番の公平さ**で保証する（毎窓は要件でない）。
            return Spec(cost: .unbounded, dropWhenOffline: false, everyWindow: false)
        case .shareImport:
            // 共有ルート／家族フォルダごとに再帰一覧＋コピー＝上限なし。
            // 毎窓ではない（ADR-166 の要件は「開かない日が続いても夜に走る」）。
            return Spec(cost: .unbounded, dropWhenOffline: true, everyWindow: false)
        case .publishAnalysis:
            // 1 回 8 シャード（ADR-222）＝上限つき。
            // ⚠️ **取り込みの後**——受け取った解析が台帳に入ってから公開したい（意味の順序）。
            // ⚠️⚠️ `everyWindow: false` は**消極的な決め**。ADR-222 追補は「反映の後では
            // 一度も順番が回ってこなかった」ので取り込みの後・反映の前へ移した＝要件は
            // 「ふだん順番が回る」。だが `after: [.shareImport]` が**上限なしの手の後ろ**へ
            // 連れて行くので、構造的には飢え得る（模型では 21〜284 秒のどの窓でも走らない）。
            // ⚠️ ここを `true` にすると模型は落ちる。それは**本物の設計の問いで、実機でしか
            // 答えが出ない**（`shareImport` は空なら即返るので、模型の悲観が過剰かもしれない）。
            // 答えが出るまでの間、宣言を偽らずに「上限つきなのに上限なしの後ろに居る唯一の手」
            // として`NightlyWindowSimulationTests` が**集合で固定**する（新しく増えたら落ちる）。
            // 実機の手順は `device-verification.md` 章 J-2。
            return Spec(cost: .bounded, dropWhenOffline: true, after: [.shareImport],
                        everyWindow: false)
        case .captureDates:
            // 500 枚かつ 40 秒（ADR-257）＝上限つき。1 枚 1 往復なので回線が無ければ何も進まない。
            // ⚠️ `everyWindow: false`——ADR-257 が述べたのは「1 晩 3〜4 枠で 2 か月ほどで
            // 一巡する**見込み**」＝throughput で、「毎窓でないと機能が成り立たない」ではない
            // （独立レビューの指摘で降格）。要件は「残作業が減り続ける」側で測る。
            // ⚠️ この手は**上限つきなのに 40 秒**＝実測最短の窓（21 秒）より長い唯一の手。
            // 後ろに置かれた毎窓の手は実際に飢えるが、並びのテストは `windowEating` に
            // この手が入っていないので素通りする——模型がそこを見る（ADR-274 追補 2）。
            return Spec(cost: .bounded, dropWhenOffline: true, everyWindow: false)
        case .shareSync:
            // 実機でコピー待ち 9,265 件・1 回 500 件（ADR-222 追補）＝窓を使い切る。
            // 窓を使い切るのが仕事なので毎窓ではない。
            return Spec(cost: .unbounded, dropWhenOffline: true, everyWindow: false)
        case .drain:
            // 残作業が続く限り待つ＝最後の段。毎窓ではない（順番が回れば回るだけ）。
            return Spec(phase: .drain, cost: .unbounded, dropWhenOffline: false, everyWindow: false)
        }
    }

    /// 並びを導く（ADR-272）。
    /// 1. `(phase, 上限つきが先)` で**安定**ソート（同じ性質の中の並びは宣言順）
    /// 2. `after` の前提を満たすまで入れ替える
    ///
    /// ⚠️ 2 は `after` が**性質より強い**（公開は上限つきだが、取り込みの後でなければならない）。
    /// ⚠️ 回り続けないよう上限を置く。収束は `NightlyPlanOrderingTests` が全組み合わせで確かめる。
    static func order(_ candidates: [Step]) -> [Step] {
        // ⚠️ 比較子ではなく**分割**で並べる（`filter` は順序を保つので安定性が自明）。
        // 段（phase）ごとに「投げっぱなし → 上限つき → 上限なし」で積む。
        // 同じ性質どうしは宣言順のまま。
        // ⚠️⚠️ `Phase.allCases` を使う（リテラルの配列を書くと、段を足したときに
        // **宣言した手が黙って計画から落ちる**＝この設計が防ごうとしている飢餓そのもの）。
        var out: [Step] = []
        for phase in Phase.allCases {
            let inPhase = candidates.filter { spec(for: $0.kind).phase == phase }
            for cost in Cost.allCases {
                out += inPhase.filter { spec(for: $0.kind).cost == cost }
            }
        }
        // ⚠️ **1 手も落としていないこと**（段や性質を足したときの取りこぼしを捕まえる）。
        assert(out.count == candidates.count,
               "並びの導出で手が落ちた（段か性質の列挙に漏れがある）: \(out.count)/\(candidates.count)")

        let limit = out.count * out.count + 1
        var passes = 0
        var moved = true
        while moved, passes < limit {
            moved = false
            passes += 1
            outer: for (idx, step) in out.enumerated() {
                for required in spec(for: step.kind).after {
                    guard let at = out.firstIndex(where: { $0.kind == required }), at > idx
                    else { continue }
                    let s = out.remove(at: idx)
                    // ⚠️ **同じ相手を待つ手の後ろ**に入れる。素朴に `required + 1` へ入れると、
                    // 同じ `after` を持つ手が 2 つあるとき**先に動いた方が後ろになる**（順序が反転）。
                    var reinsert = out.firstIndex { $0.kind == required }! + 1
                    while reinsert < out.count,
                          spec(for: out[reinsert].kind).after.contains(required) {
                        reinsert += 1
                    }
                    out.insert(s, at: reinsert)
                    moved = true
                    break outer
                }
            }
        }
        // ⚠️ **収束しなかったことを黙って通さない**（ADR-250 の「効いた回数が見えるログ」と同じ）。
        // 循環した前提（A after B・B after A）を宣言すると、上限で打ち切って
        // **宣言に反する並び**を返す——`window plan:` の行を誰も差分で見ないので気づけない。
        // ⚠️ ここは `Foundation` だけに依存する純ロジックなので、記録は持ち込まない
        // （`Diagnostics` を import すると、窓を起こさずに試せる性質が崩れる）。
        // 本番の安全網は **CI の総当たりテスト**
        // （`NightlyPlanOrderingTests.testEveryDeclaredPrerequisiteIsSatisfiedInEveryConfiguration`）
        // ——循環は「宣言の書き間違い」なので、出荷前に落ちれば足りる。
        assert(!moved, "`after` の前提が収束しない（循環している可能性）: \(out.map(\.label))")
        return out
    }

    /// 解析を起こしたあとの手順。並びは `order(_:)` が性質の宣言から導く（ADR-272）。
    static func remainingSteps(_ i: Inputs) -> [Step] {
        order(applicableSteps(i))
    }

    /// この窓で**順番が回らなければならない**手（`everyWindow` の宣言から導く）。
    ///
    /// ⚠️⚠️ **「計画に載った手」から引かない。** 手が計画から黙って落ちたら飢餓に数えられず、
    /// ADR-266（条件つきで落ちる）と ADR-273 #3（段のリテラル配列から落ちる）が
    /// まるごと死角になる——`out.append(.refreshCloudIndexSnapshot)` を 1 行消すと
    /// 「計画基準」の版は黙って green になった（ADR-274 追補 2・独立レビューの実証）。
    /// だから**宣言から導いて**、そこから走った手を引く。
    ///
    /// ⚠️ `after` の相手が**上限なしで同じ窓に居る**なら免除する——照合の週は
    /// バックアップの**開始が遅れる**（ADR-206 が認めた 52 回に 1 回の代償）。
    /// 免除は `after` と `cost` から**導出**する（例外のリストを書かない・ADR-196）。
    ///
    /// ⚠️⚠️ **読み手は 2 つ**——`HeavyWorkScheduler` の飢餓ログ（実機）と
    /// `NightlyWindowSimulator`（テスト）。だからここが**唯一の出典**でなければならない。
    /// 以前は模型の側だけに同じ導出を持っていて、**本番のログには照合週の免除が無く**、
    /// 「毎窓なのに回らなかった」を照合の週に毎回出すところだった（ADR-196 の形）。
    static func requiredEveryWindowKinds(in plan: [Step], networkAllowed: Bool) -> Set<Kind> {
        let planned = Set(plan.map(\.kind))
        var required: Set<Kind> = []
        for kind in Kind.allCases {
            let s = spec(for: kind)
            guard s.everyWindow else { continue }
            // 回線が無い窓で落とす手は、落ちていて正しい。
            if !networkAllowed, s.dropWhenOffline { continue }
            let blockedByPrerequisite = s.after.contains { prerequisite in
                planned.contains(prerequisite) && spec(for: prerequisite).cost == .unbounded
            }
            if blockedByPrerequisite { continue }
            required.insert(kind)
        }
        return required
    }

    /// この窓で**当てはまる**手（順不同）。
    ///
    /// ⚠️⚠️ **ここは「並べる」場所ではなく「どの手が当てはまるか」を書く場所**（ADR-272）。
    /// 並びは `order(_:)` が**性質の宣言から導く**ので、`append` の順番そのものに意味は無い
    /// （**同じ性質どうし**の並びだけがここで決まる）。
    /// 新しい手を足すときは `Kind` と `spec(for:)` に 1 行ずつ足す——
    /// 「窓を使い切る手より前に置かねば」を思い出す必要はない。
    ///
    /// ⚠️ 回線が要る手は、許可されない窓には**並べない**（「Wi-Fi のみ」を破らない・ADR-198）。
    private static func applicableSteps(_ i: Inputs) -> [Step] {
        var out: [Step] = []
        out.append(.logStalledPasses)
        // ⚠️ **照合はバックアップより前**（ADR-206）。`.startBackup` は投げっぱなしで
        // `isRunning` を立て、照合は `guard !isBusy` で門前払いされる。ADR-180 で 1 回あたりの
        // 上限を外してから、積み残しのある端末では窓いっぱい busy のままになり——
        // **照合がいちばん要る端末で、照合だけが永久に走らなかった**。
        // 照合はオフロードの緊急停止（ADR-202）の唯一の発火点なので、走らないと
        // 「唯一のコピーが消えた」ことに誰も気づけない。
        // 期限が来た週だけ前へ出す（52 回に 1 回なので、ふだんの手順は変えない）。
        // ⚠️⚠️ **控えの書き直しは毎回・かつ早いうちに**（ADR-266/270）。
        // 控え（ADR-258）の鍵を崩す経路は **2 つ**ある——撮影日の問い合わせと**差分の取り込み**。
        // 「撮影日を訊いた回」だけ書き直していた頃は、差分だけ入った晩に控えが古いまま残り、
        // 次の起動で 10.8 万行を作り直していた（実機で 6 起動中 1 回・8.9 秒）。
        // 条件にしないのが正解——**崩れたかは控え側が鍵で判断する**（同じ鍵なら書かない）。
        //
        // ⚠️⚠️ **位置が本質**（独立レビューの指摘）。最初は `drain` の直前＝
        // `shareSync` の**後ろ**に置いていた。だがこの関数は 2 か所で
        // 「`shareSync` は窓を使い切る」「後ろに置いた手は一度も順番が回ってこない」と
        // **自分で書いている**（それを理由に公開と撮影日を前へ出した）。
        // つまり提供がオンでコピー待ちのある端末では、**この手は一度も走らず
        // ADR-266 が何もしない**。回線は要らない（ローカルの書き出しだけ）ので、
        // 回線の網の**外**かつ窓を食う手より**前**に置く。
        out.append(.refreshCloudIndexSnapshot)
        if i.backupReconcileDue { out.append(.reconcileBackup) }
        out.append(.startBackup)

        switch NightlyWorkPolicy.generateDecision(embedBacklog: i.embedBacklog,
                                                  faceBacklog: i.faceBacklog,
                                                  deferrals: i.generateDeferrals,
                                                  maxDeferrals: i.maxGenerateDeferrals) {
        case .defer_(let streak):
            out.append(.deferGenerate(streak: streak))
        case .run:
            out.append(i.availableMB > minimumGenerateMB
                       ? .generate
                       : .skipGenerateLowMemory(availableMB: i.availableMB))
        }

        // 家族共有は回線が要る（ADR-166: 夜間にも回す。アプリを開かない日が続くと
        // 反映も自己修復も走らなかった）。
        out.append(.shareImport)
        // ⚠️ **公開は取り込みの後・反映の前**（ADR-222 追補・実機ログ diagnostics-83）。
        // 「後」なのは、受け取った解析が自分の台帳に入ってから公開したいから
        // （同じ写真を 2 人が別々に解析し直す空回りが早く止まる）。
        // 「反映の前」なのは、反映（`syncNow`）が**窓を使い切る**から——実機では
        // コピー待ちが 9,265 件あり、1 回 500 件ずつ進む。最後に置いた公開は
        // **一度も順番が回ってこなかった**（窓は 5 分で期限切れ）。公開は上限つき
        // （8 シャード）で軽いので、長く走る手より前に出す。
        if i.publishAnalysisEnabled { out.append(.publishAnalysis) }
        // ⚠️ **撮影日時は反映（`shareSync`）より前**（ADR-257・ADR-222 追補と同じ理由）。
        // `shareSync` は窓を使い切る（実機でコピー待ち 9,265 件・1 回 500 件）。
        // 後ろに置いた手は**一度も順番が回ってこない**ので、上限つきで軽いものを前へ出す。
        // ⚠️ 撮影日時が無いとクラウド写真で顔の時期グループ（ADR-218）と
        // Time&Place が機能しない＝**他の機能の前提**なので、飢えさせない。
        if i.captureDateBacklog > 0 {
            out.append(.probeCaptureDates(limit: captureDateProbeLimit))
        }
        if i.provideShareEnabled { out.append(.shareSync) }
        // ⚠️ **週次の照合も回線の中**（レビュー 11 周目）。Dropbox の全件一覧を引くので
        // 通信が要るのに、ここだけ外にあった——「Wi-Fi のみ」でもセルラーで
        // 全件一覧を引き得た（ADR-198 で撤回した「ブーストは回線を免除」と同じ、
        // 利用者の実費の問題）。`background-behavior.md` の表も回線 ○ と書いている。
        // 位置は上へ移した（ADR-206）。回線の条件はそちらにも書いてある。
    
        out.append(.drainUntilIdle)
        // ⚠️⚠️ **回線の判定はここだけ**（ADR-272 追補）。以前は `if i.networkAllowed { … }` の
        // 入れ子で書いていて、宣言側にも**読まれないままの項目**があって二重だった
        // ——「同じ判断を 2 か所に書かない」（ADR-196）を、それを直す改修で破っていた。
        // ⚠️ 落とすのは「回線が無いとやることが何も無い手」だけ（`dropWhenOffline`）。
        // `backup` / `generate` は通信するが**内部で判定する**ので落とさない。
        guard !i.networkAllowed else { return out }
        return out.filter { !spec(for: $0.kind).dropWhenOffline }
    }
}
