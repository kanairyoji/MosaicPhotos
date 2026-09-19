import Foundation

/// 重い処理を「いま動かしてよいか」の**唯一の判定**（ADR-196）。
///
/// ## なぜ 1 つにしたか
/// 以前はここに 11 の述語が並んでいた（`heavyWorkAllowed` / `heavyWorkAllowedLocal` /
/// `monolithicHeavyWorkAllowed` / `heavyShouldPause` / `analysisShouldYieldToUI` / `uiBusy` …）。
/// どれも「条件の部分集合」で、**どれを使うかが呼び手側の知識**になっていた。結果:
/// - 入口（`PeopleEngine.startScan` ＝ `heavyWorkAllowedLocal`）と譲り（`heavyShouldPause`）が
///   **別の集合**を見ていて、「入ってよい」と言われて 75,000 行を読んでから「やっぱり譲れ」に
///   なる（diagnostics-62/63 の「入口代だけ払う」）。
/// - 画面の「なぜ進まないか」（旧 `AnalysisBlockerDiagnosis`）が**別実装**で、ゲートが閉じて
///   いるのに「すべての条件を満たしています」と言えてしまう。
/// - 「控えめ」の軸を外した（ADR-195）ときに `refinePlaceNames` → `generate` が前面で
///   到達可能になり、ADR-107 の一枚岩ゲートをすり抜けた。
///
/// ## 作り
/// 軸は 2 つだけ。**どの仕事か**（`HeavyWork`）と**誰が聞いているか**（`Exemption`）。
/// 条件は `Blocker` の**表**（`applies(to:)` と `skippableBy`）で、判定は純関数
/// `blockers(_:for:exemption:)` 1 つ。呼び手は `verdict(for:)` を呼ぶだけで、
/// 部分集合を選べない——**入口と譲りが同じ式になる**。
///
/// 表は `docs/architecture-note/records/background-behavior.md` の早見表と同じもの。
@MainActor
public enum BackgroundYield {

    // MARK: - 仕事の種類

    /// 重い処理の種類。違いは**2 つの軸**だけ——通信が要るか、始めたら譲れるか。
    ///
    /// ⚠️ この 2 つを 1 つに畳むと、通信の要らない一枚岩（AI アルバムの本番化・ドリフト
    /// 再評価＝台帳と埋め込みを読むだけ）まで Wi-Fi 待ちで止まる。
    public enum HeavyWork: String, Sendable, CaseIterable {
        /// 端末内写真の顔・タグ・埋め込み（回線不要・1 単位ごとに譲れる）。
        case localTrickle
        /// クラウド写真の解析（サムネ DL を伴うので回線が要る）。
        case cloudTrickle
        /// 通信の要らない一枚岩（AI アルバムの本番化・ドリフト再評価）。始まると譲れない。
        case localMonolith
        /// 通信の要る一枚岩（アルバム生成＝クラウド一覧・地名の高精度化＝CLGeocoder）。
        case cloudMonolith
        /// OS の処理枠（BGProcessingTask）そのものが来るか。画面の説明用。
        case window

        /// 通信が要るか。
        public nonisolated var requiresNetwork: Bool {
            self == .cloudTrickle || self == .cloudMonolith
        }
        /// 始まると譲れないか（前面では動かさない・ADR-107）。
        public nonisolated var isMonolith: Bool {
            self == .localMonolith || self == .cloudMonolith
        }
    }

    // MARK: - 誰が聞いているか

    /// 免除の段。強いほど多くを素通りできる。
    public enum Exemption: Int, Sendable, Comparable {
        /// 平常（自動の解析）。
        case none = 0
        /// 利用者が始めたブースト（「今すぐ解析」・ADR-182/195）。方針の条件を免除する。
        case boost = 1
        /// Developer Options の「重い処理のゲートを無効化」。検証用。
        case debug = 2

        public static func < (a: Exemption, b: Exemption) -> Bool { a.rawValue < b.rawValue }
    }

    /// アプリの画面状態（事実）。旧 `isAppActive` ＋ `isAppInBackground` を 1 つにしたもの。
    public enum ScenePhaseKind: String, Sendable {
        /// 前面でアクティブ（利用者が触れる状態）。
        case active
        /// 前面だが非アクティブ（通知センター・着信バナー・App スイッチャー）。
        case inactive
        /// 背面（ロック・アプリ切替）。処理枠が動くのはここ。
        case background
    }

    // MARK: - 止めている条件

    /// 重い処理を止めている条件。**並び順＝利用者が直しやすい順**（画面はこの順で出す）。
    public enum Blocker: String, Sendable, CaseIterable {
        /// 「自動で解析する」が OFF（設定 → アルバム → 処理のタイミング）。
        case automaticOff
        /// iOS の「App のバックグラウンド更新」が OFF／制限。処理枠そのものが来ない。
        case backgroundRefreshOff
        /// 低電力モード（どの設定でも重い処理は止まる・安全弁）。
        case lowPowerMode
        /// 電源ポリシーが「充電中のみ」なのに充電していない。
        case notCharging
        /// 電源ポリシーが「オフ」。
        case powerOff
        /// 電源なしで電池が下限（20%）を割った。**誰も素通りできない**。
        case lowBattery
        /// 回線ポリシーを満たしていない（クラウド写真の解析だけが止まる）。
        case networkBlocked
        /// 発熱で停止中（充電を優先する・ADR-118）。**誰も素通りできない**。
        case tooHot
        /// メモリ圧迫中。**誰も素通りできない**（jetsam の保護）。
        case memoryPressure
        /// 起動・復帰の一括ロード中（ADR-122）。**誰も素通りできない**（同上）。
        case heavyLoad
        /// アルバム生成中（相互排他・メモリ保護）。
        case generating
        /// 前面で利用者が見ている（写真表示・フル画像取得・表示サムネ取得）。
        case uiBusy
        /// 前面だが、最後のタッチから 20 秒経っていない（ADR-195）。
        case foregroundNotIdle
        /// 前面でアクティブ（一枚岩は始まると譲れないので非アクティブ限定・ADR-107）。
        case appActive
        /// ブースト実行中（一枚岩は起こさない——始まると解析が止まる）。
        case boostRunning

        /// この条件を素通りできる**最小の段**。nil＝誰も素通りできない（安全弁）。
        public nonisolated var skippableBy: Exemption? {
            switch self {
            // 熱・メモリ・一括ロード・電池は明示操作でも外さない。
            // 熱: 外すと iOS が「冷めてから充電」に入り、朝に充電が終わっていない（実フィードバック）。
            // 電池: 外すと「電池のため止めた」と言った直後に方針が同じ処理を再開する（レビュー指摘）。
            case .tooHot, .memoryPressure, .heavyLoad, .lowBattery:
                return nil
            // ブーストでも譲る（生成との相互排他＝メモリ保護、前面での UI への譲り）。
            case .generating, .uiBusy, .boostRunning:
                return .debug
            // 方針の条件。ブーストは利用者の明示操作なので免除する。
            default:
                return .boost
            }
        }

        /// この条件を課す仕事の種類。
        public nonisolated func applies(to work: HeavyWork) -> Bool {
            switch self {
            // 通信を要する作業だけ。端末内写真は Wi-Fi 無しでも進む（実障害の対処）。
            case .networkBlocked:
                return work.requiresNetwork
            // 一枚岩だけ（トリクルは 1 単位ごとに譲れるので前面アイドルでも安全）。
            case .appActive, .boostRunning:
                return work.isMonolith
            // 処理枠が来るかどうかの話。前面の解析には効かない。
            case .backgroundRefreshOff:
                return work == .window
            // 処理枠は OS が起こすかどうかなので、アプリ側の実行時条件は問わない。
            case .memoryPressure, .heavyLoad, .generating, .uiBusy, .foregroundNotIdle:
                return work != .window
            default:
                return true
            }
        }
    }

    /// 判定結果。空なら動いてよい。
    public struct Verdict: Sendable, Equatable {
        public let work: HeavyWork
        public let blockers: [Blocker]
        public nonisolated var allowed: Bool { blockers.isEmpty }
        /// この条件で止まっているか。**表の射影**（新しい規則ではない）。
        ///
        /// ⚠️ 「今回の対象にクラウド分を含めるか」のように**実行の最初に 1 回だけ決まる**
        /// 選択には、`allowed` 全体ではなくこれを使う。全体で見ると、UI ビジーのような
        /// 一時的な理由でクラウド候補が丸ごと対象外になってしまう。
        public nonisolated func blocks(_ blocker: Blocker) -> Bool { blockers.contains(blocker) }
        /// 診断ログ用の 1 行。
        public nonisolated var reason: String {
            blockers.isEmpty ? "ok" : blockers.map(\.rawValue).joined(separator: ",")
        }
        public nonisolated init(work: HeavyWork, blockers: [Blocker]) {
            self.work = work
            self.blockers = blockers
        }
    }

    // MARK: - 状態（2 つだけ）

    /// アプリの画面状態。`MosaicPhotosApp` が scenePhase から更新する。
    /// 処理枠は `withScenePhase(.background)` で**スコープとして**入る（手で戻さない）。
    public private(set) static var scenePhase: ScenePhaseKind = .active

    /// いまの免除の段。ブーストは `AnalysisSession` が、デバッグ全開は
    /// Developer Options と `withExemption` が設定する。
    public private(set) static var exemption: Exemption = .none

    /// 画面状態を更新する。
    /// ⚠️ ウォッチドッグへ伝える（背面の「ハング」は OS の throttle で体感とは無関係＝ADR-82）。
    /// 呼び出し側が別途伝える方式だと必ず忘れるので、唯一の出典であるここから同期する。
    public static func setScenePhase(_ phase: ScenePhaseKind) {
        scenePhase = phase
        MainThreadWatchdog.shared.setAppActive(phase == .active)
    }

    /// 免除の段を設定する（ブーストの開始・終了）。
    public static func setExemption(_ e: Exemption) { exemption = e }

    /// 画面状態を一時的に変える（処理枠の実行中など）。**戻し忘れが起きない形**。
    /// 旧実装は `isAppActive` / `isAppInBackground` を手で書き換え、`restoreAppActive` という
    /// 引数で後始末していた（戻し忘れがレビューで 1 回指摘されている）。
    public static func withScenePhase<T>(_ phase: ScenePhaseKind,
                                         _ body: () async -> T) async -> T {
        let previous = scenePhase
        setScenePhase(phase)
        defer { setScenePhase(previous) }
        return await body()
    }

    /// 免除の段を一時的に上げる（デバッグ実行）。
    public static func withExemption<T>(_ e: Exemption, _ body: () async -> T) async -> T {
        let previous = exemption
        exemption = e
        defer { exemption = previous }
        return await body()
    }

    // MARK: - 環境（判定の入力）

    /// 判定に要る端末・アプリの状態。**純ロジックに渡すための値**（テストはここを組み立てる）。
    public struct Environment: Sendable, Equatable {
        public var automaticEnabled: Bool
        public var backgroundRefreshAvailable: Bool
        public var lowPowerMode: Bool
        public var powerPolicy: BackgroundPowerPolicy
        public var onPower: Bool
        /// 電池残量（0〜1）。読めないときは nil＝電池では止めない。
        public var batteryLevel: Float?
        public var networkAllowed: Bool
        public var tooHot: Bool
        public var memoryPressure: Bool
        public var heavyLoadInFlight: Bool
        public var generatingAlbums: Bool
        public var uiBusy: Bool
        public var idleSeconds: TimeInterval
        public var scenePhase: ScenePhaseKind

        public nonisolated init(automaticEnabled: Bool = true,
                    backgroundRefreshAvailable: Bool = true,
                    lowPowerMode: Bool = false,
                    powerPolicy: BackgroundPowerPolicy = .whileCharging,
                    onPower: Bool = true,
                    batteryLevel: Float? = nil,
                    networkAllowed: Bool = true,
                    tooHot: Bool = false,
                    memoryPressure: Bool = false,
                    heavyLoadInFlight: Bool = false,
                    generatingAlbums: Bool = false,
                    uiBusy: Bool = false,
                    idleSeconds: TimeInterval = .greatestFiniteMagnitude,
                    scenePhase: ScenePhaseKind = .background) {
            self.automaticEnabled = automaticEnabled
            self.backgroundRefreshAvailable = backgroundRefreshAvailable
            self.lowPowerMode = lowPowerMode
            self.powerPolicy = powerPolicy
            self.onPower = onPower
            self.batteryLevel = batteryLevel
            self.networkAllowed = networkAllowed
            self.tooHot = tooHot
            self.memoryPressure = memoryPressure
            self.heavyLoadInFlight = heavyLoadInFlight
            self.generatingAlbums = generatingAlbums
            self.uiBusy = uiBusy
            self.idleSeconds = idleSeconds
            self.scenePhase = scenePhase
        }
    }

    /// 電源なしでこれを下回ったら重い処理を止める（ブーストでも外さない）。
    public nonisolated static let lowBatteryFloor: Float = 0.2

    /// 「App のバックグラウンド更新」が使えるか。**アプリ層が起動時に差す**
    /// （`UIApplication` を MosaicSupport へ持ち込まないための seam）。
    public nonisolated(unsafe) static var backgroundRefreshAvailableProvider: @MainActor () -> Bool = { true }

    /// テスト用の差し替え（本番は nil）。
    ///
    /// ⚠️ これが無いと、判定が**実行マシンの状態**（低電力モード・充電・回線）に左右される。
    /// 旧実装の述語は入力が狭かったので表面化しなかったが、条件を 1 つの表にまとめた以上、
    /// テストは環境を自分で組み立てる必要がある（規約「テスト用 seam（DI）」）。
    public static var environmentOverrideForTesting: Environment?

    /// いまの端末・アプリの状態を読む（各モニタに触るのはここだけ）。
    public static func currentEnvironment() -> Environment {
        if let override = environmentOverrideForTesting { return override }
        let power = PowerStateMonitor.shared
        let monitor = BackgroundActivityMonitor.shared
        return Environment(
            automaticEnabled: HeavyWorkTiming.current != .paused,
            backgroundRefreshAvailable: backgroundRefreshAvailableProvider(),
            lowPowerMode: power.isLowPowerMode,
            powerPolicy: power.policy,
            onPower: power.isOnPower,
            batteryLevel: power.batteryLevelIfKnown,
            networkAllowed: NetworkStateMonitor.shared.networkAllowed(),
            tooHot: ThermalGate.shared.shouldPause(),
            memoryPressure: MemoryPressureMonitor.shared.isUnderPressure,
            heavyLoadInFlight: HeavyLoad.isInFlight(),
            generatingAlbums: monitor.isGeneratingAlbums,
            uiBusy: monitor.isViewingPhoto || monitor.fullImageBusy || monitor.cloudThumbnailBusy,
            idleSeconds: monitor.idleSeconds,
            scenePhase: scenePhase)
    }

    // MARK: - 判定（純ロジック・テスト対象）

    /// この環境・この仕事・この段で、止めている条件を並べる。空なら動いてよい。
    public nonisolated static func blockers(_ env: Environment,
                                            for work: HeavyWork,
                                            exemption: Exemption) -> [Blocker] {
        var raw: [Blocker] = []
        if !env.automaticEnabled { raw.append(.automaticOff) }
        if !env.backgroundRefreshAvailable { raw.append(.backgroundRefreshOff) }
        if env.lowPowerMode { raw.append(.lowPowerMode) }
        switch env.powerPolicy {
        case .whileCharging: if !env.onPower { raw.append(.notCharging) }
        case .off:           raw.append(.powerOff)
        case .always:        break
        }
        if !env.onPower, let level = env.batteryLevel, level >= 0, level < lowBatteryFloor {
            raw.append(.lowBattery)
        }
        if !env.networkAllowed { raw.append(.networkBlocked) }
        if env.tooHot { raw.append(.tooHot) }
        if env.memoryPressure { raw.append(.memoryPressure) }
        if env.heavyLoadInFlight { raw.append(.heavyLoad) }
        if env.generatingAlbums { raw.append(.generating) }
        // UI への譲りとアイドルは**前面でアクティブなときだけ**見る（ADR-179）。
        // 背面では画面が無いのに、解析自身のサムネ取得で `uiBusy` が立ち続けて
        // 夜間の解析が丸ごと止まっていた（diagnostics-81）。
        if env.scenePhase == .active {
            if env.uiBusy { raw.append(.uiBusy) }
            if env.idleSeconds < HeavyWorkTiming.foregroundIdleSeconds { raw.append(.foregroundNotIdle) }
            raw.append(.appActive)
        }
        if exemption == .boost { raw.append(.boostRunning) }

        return raw.filter { b in
            guard b.applies(to: work) else { return false }
            guard let skip = b.skippableBy else { return true }   // 安全弁は誰も外せない
            return exemption < skip
        }
    }

    /// いまこの仕事を動かしてよいか。**入口も 1 単位ごとの譲りも、これを呼ぶ**。
    public static func verdict(for work: HeavyWork) -> Verdict {
        Verdict(work: work, blockers: blockers(currentEnvironment(), for: work, exemption: exemption))
    }

    /// `!verdict(for:).allowed` の言い換え（トリクルの譲り判定で読みやすくするため）。
    public static func shouldYield(_ work: HeavyWork = .localTrickle) -> Bool {
        !verdict(for: work).allowed
    }

    /// いま動かしてよいか（`verdict(for:).allowed` の言い換え）。
    public static func allows(_ work: HeavyWork) -> Bool {
        verdict(for: work).allowed
    }
}
