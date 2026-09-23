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

    static func generateDecision(embedBacklog: Int, faceBacklog: Int,
                                 deferrals: Int, maxDeferrals: Int) -> GenerateDecision {
        let hasBacklog = embedBacklog > 0 || faceBacklog > 0
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
        var faceBacklog: Int
        var generateDeferrals: Int
        var maxGenerateDeferrals: Int
        /// 空きメモリ（MB）。generate はピークが大きい（実測 550〜880MB）。
        var availableMB: Int
        var networkAllowed: Bool
        var provideShareEnabled: Bool
        /// バックアップ台帳の週次照合の期限が来ているか（ADR-206）。
        /// ⚠️ **手順の位置がこれで変わる**（来ている週だけバックアップの前に出す）。
        var backupReconcileDue: Bool
        /// 同じ Dropbox の人へ解析を公開するか（ADR-222・既定 ON）。
        var publishAnalysisEnabled: Bool

        init(boostActive: Bool = false, embedBacklog: Int = 0, faceBacklog: Int = 0,
             generateDeferrals: Int = 0, maxGenerateDeferrals: Int = 4,
             availableMB: Int = 2048, networkAllowed: Bool = true,
             provideShareEnabled: Bool = false, backupReconcileDue: Bool = false,
             publishAnalysisEnabled: Bool = false) {
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
        /// バックアップ台帳と実体の照合（週 1・内部で期限を見る）。
        case reconcileBackup
        /// 残作業が続く限り待つ（期限切れ＝キャンセルで抜ける）。
        case drainUntilIdle

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
            case .reconcileBackup:                 return "reconcile"
            case .drainUntilIdle:                  return "drain"
            }
        }
    }

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

    /// 解析を起こしたあとの手順。
    static func remainingSteps(_ i: Inputs) -> [Step] {
        var out: [Step] = []
        out.append(.logStalledPasses)
        // ⚠️ **照合はバックアップより前**（ADR-206）。`.startBackup` は投げっぱなしで
        // `isRunning` を立て、照合は `guard !isBusy` で門前払いされる。ADR-180 で 1 回あたりの
        // 上限を外してから、積み残しのある端末では窓いっぱい busy のままになり——
        // **照合がいちばん要る端末で、照合だけが永久に走らなかった**。
        // 照合はオフロードの緊急停止（ADR-202）の唯一の発火点なので、走らないと
        // 「唯一のコピーが消えた」ことに誰も気づけない。
        // 期限が来た週だけ前へ出す（52 回に 1 回なので、ふだんの手順は変えない）。
        if i.networkAllowed && i.backupReconcileDue { out.append(.reconcileBackup) }
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
        if i.networkAllowed {
            out.append(.shareImport)
            if i.provideShareEnabled { out.append(.shareSync) }
            // ⚠️ **公開は取り込みのあと**（ADR-222）。先に取り込むと、受け取った解析が
            // 自分の台帳に入ってから公開されるので、同じ写真を 2 人が別々に解析し直す
            // 空回りが早く止まる。
            if i.publishAnalysisEnabled { out.append(.publishAnalysis) }
            // ⚠️ **週次の照合も回線の中**（レビュー 11 周目）。Dropbox の全件一覧を引くので
            // 通信が要るのに、ここだけ外にあった——「Wi-Fi のみ」でもセルラーで
            // 全件一覧を引き得た（ADR-198 で撤回した「ブーストは回線を免除」と同じ、
            // 利用者の実費の問題）。`background-behavior.md` の表も回線 ○ と書いている。
            // 位置は上へ移した（ADR-206）。回線の条件はそちらにも書いてある。
        }
        out.append(.drainUntilIdle)
        return out
    }
}
