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
        /// 同じ Dropbox の人へ解析を公開するか（ADR-222・既定 ON）。
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
    enum Phase: Int, Comparable {
        /// 投げっぱなしで始める手（他の手の裏で走らせたいので最初）。
        case kick = 0
        /// 本体。
        case work = 1
        /// 期限まで待つ手（後ろに手は置けない）。
        case drain = 2
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    /// 手の種類（`Step` の付随値を落とした識別子。`after` の指定に使う）。
    enum Kind: String, CaseIterable {
        case analysis, stallCheck, indexSnapshot, reconcile, backup, generate
        case shareImport, publishAnalysis, captureDates, shareSync, drain
    }

    struct Spec {
        var phase: Phase = .work
        /// **上限（件数・秒・シャード数）を持つか。**
        /// ⚠️ `false`＝「始めたら窓の期限まで走り得る」。迷ったら `false`
        /// （上限があると偽ると、本当に上限のある手を飢えさせる）。
        var bounded: Bool
        /// 通信が要るか（⚠️ 要るなら回線が許可されない窓には**並べない**）。
        var needsNetwork: Bool
        /// ⚠️ **性質に還元できない前提**（資源の競合・意味の順序）。ここだけは明示する。
        var after: [Kind] = []
    }

    static func spec(for kind: Kind) -> Spec {
        switch kind {
        case .analysis:
            // 投げっぱなし（`kick` は背景の Task を起こすだけ）。他の手の裏で走らせたい。
            return Spec(phase: .kick, bounded: true, needsNetwork: false)
        case .stallCheck:
            return Spec(bounded: true, needsNetwork: false)
        case .indexSnapshot:
            // 16MB を 1 回書くだけ（鍵が同じなら書かない）。回線は要らない。
            return Spec(bounded: true, needsNetwork: false)
        case .reconcile:
            // Dropbox の全件一覧（ADR-206）＝上限なし。
            return Spec(bounded: false, needsNetwork: true)
        case .backup:
            // 毎窓・1 回あたりの上限なし＝窓の期限が上限（ADR-180）。
            // ⚠️ **照合の後**——`.startBackup` は `isRunning` を立て、照合は
            // `guard !isBusy` で門前払いされる（資源の競合・性質では表せない）。
            return Spec(bounded: false, needsNetwork: true, after: [.reconcile])
        case .generate:
            // 550〜880MB・数十秒（`minimumGenerateMB` が在る理由）。
            return Spec(bounded: false, needsNetwork: true)
        case .shareImport:
            // 共有ルート／家族フォルダごとに再帰一覧＋コピー＝上限なし。
            return Spec(bounded: false, needsNetwork: true)
        case .publishAnalysis:
            // 1 回 8 シャード（ADR-222）＝上限つき。
            // ⚠️ **取り込みの後**——受け取った解析が台帳に入ってから公開したい（意味の順序）。
            return Spec(bounded: true, needsNetwork: true, after: [.shareImport])
        case .captureDates:
            // 500 枚かつ 40 秒（ADR-257）＝上限つき。
            return Spec(bounded: true, needsNetwork: true)
        case .shareSync:
            // 実機でコピー待ち 9,265 件・1 回 500 件（ADR-222 追補）＝窓を使い切る。
            return Spec(bounded: false, needsNetwork: true)
        case .drain:
            return Spec(phase: .drain, bounded: false, needsNetwork: false)
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
        // 段（phase）ごとに「上限つき → 上限なし」で積む。同じ性質どうしは宣言順のまま。
        var out: [Step] = []
        for phase in [Phase.kick, .work, .drain] {
            let inPhase = candidates.filter { spec(for: $0.kind).phase == phase }
            out += inPhase.filter { spec(for: $0.kind).bounded }
            out += inPhase.filter { !spec(for: $0.kind).bounded }
        }

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
                    let reinsert = out.firstIndex { $0.kind == required }! + 1
                    out.insert(s, at: reinsert)
                    moved = true
                    break outer
                }
            }
        }
        return out
    }

    /// 解析を起こしたあとの手順。並びは `order(_:)` が性質の宣言から導く（ADR-272）。
    static func remainingSteps(_ i: Inputs) -> [Step] {
        order(applicableSteps(i))
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
        }
        out.append(.drainUntilIdle)
        return out
    }
}
