import Foundation

/// 背景の重い処理（CLIP 埋め込み・顔スキャン）が「今は譲るべきか」の共通判定。
/// 以前は CLIP（`AutoAlbumEngine`）と顔スキャン（`PeopleEngine`）が同じ条件式を並列に持っており、
/// 条件を足すとき（例: フル画像取得中を追加）に片方だけ直る恐れがあった。ここに一元化する。
///
/// 電源条件だけは用途で異なる（CLIP＝ユーザーのポリシー設定 / 顔スキャン＝電源接続固定）ため、
/// `powerOK` として呼び出し側が渡す。
@MainActor
public enum BackgroundYield {
    /// UI・リソースの共通譲り条件：メモリ圧迫中・写真ビュー表示中（タップ直後の遷移含む）・
    /// フル画像取得中・クラウドのサムネ取得中。
    public static var uiBusy: Bool {
        MemoryPressureMonitor.shared.isUnderPressure
            || BackgroundActivityMonitor.shared.isViewingPhoto
            || BackgroundActivityMonitor.shared.fullImageBusy
            || BackgroundActivityMonitor.shared.cloudThumbnailBusy
    }

    /// 標準判定（電源条件込み）。`powerOK` が false なら常に譲る。
    /// **アルバム生成中も譲る**（相互排他）：起動直後に generate（85k 件の SwiftData 処理）と
    /// ANE 推論・画像ロードが同時に走るとメモリが跳ね（実測 668MB）システム全体がストールする。
    public static func shouldPause(powerOK: Bool) -> Bool {
        !powerOK || uiBusy || BackgroundActivityMonitor.shared.isGeneratingAlbums
    }

    // MARK: - 重い処理の実行方針（ユーザー指定・全アプリ共通）

    /// アプリがフォアグラウンドでアクティブか（`MosaicPhotosApp` が scenePhase から更新する）。
    /// 方針: **ユーザーが操作している間（＝アクティブ）は重い処理を一切動かさない**。
    /// 画面ロック・アプリ切替で非アクティブになったときだけ動かす（実行の主役は夜間 BGTask）。
    /// ⚠️ `didSet` でウォッチドッグへ伝える。背面の「ハング」は OS の throttle であって体感とは
    /// 無関係なので、計測から外す必要がある（ADR-82）。呼び出し側が別途伝える方式だと必ず
    /// 忘れるため、唯一の出典であるこの変数から自動で同期する。
    public static var isAppActive = true {
        didSet { MainThreadWatchdog.shared.setAppActive(isAppActive) }
    }

    /// デバッグ（Developer Options）: 重い処理のゲート（電源・低電力・アイドル・UIビジー）を
    /// **全面的に無効化**する。バックグラウンドでしか動かない処理（アルバム生成・CLIP 埋め込み・
    /// 顔スキャン・ドリフト再評価）をその場で動かして検証するためのもの。アプリ再起動でリセット。
    /// ※ 生成との相互排他（isGeneratingAlbums）だけは維持する（メモリ保護）。
    public static var debugForceHeavyWork = false

    /// 手動ブースト（設定の「今すぐ処理」）。期限内は**非アクティブ条件と Wi-Fi 条件**を免除する
    /// （明示操作なのでフォアグラウンドでも実行。電源接続・低電力 OFF は維持）。
    public static var manualBoostUntil = Date.distantPast

    /// 「今すぐ処理」を有効化する（既定 30 分・電源接続中のみ効く）。
    public static func boostHeavyWork(minutes: Double = 30) {
        manualBoostUntil = Date().addingTimeInterval(minutes * 60)
    }

    /// 重い処理の**開始/継続の共通条件**（回線を要する作業向け＝クラウド分を含む）。判定は 4 軸の
    /// 独立した設定に従う（ADR-80）＝自動処理の有無・控えめ（前面で動かすか）・電源・回線。
    /// 既定は「自動処理あり＋控えめ ON＋充電中のみ＋Wi-Fi のみ」＝アプリ使用中は一切動かない（ADR-25）。
    /// 手動ブースト中は使用状況/回線条件を免除（明示操作＝フォアグラウンド実行を許可。電源系の安全弁は維持）。
    public static var heavyWorkAllowed: Bool { heavyWorkAllowed(requiresNetwork: true) }

    /// **ローカル専用**の重い処理（端末内写真の顔スキャン・CLIP 埋め込み）向けの許可判定。
    /// 通信を要しないため **Wi-Fi 条件を課さない**（電源＋非使用＋低電力OFF だけで走る）。
    /// これが無いと、Wi-Fi 未接続/未検出の夜間に端末内写真の解析まで止まっていた（実障害）。
    /// クラウド分（サムネDL）は各処理が `NetworkStateMonitor.networkAllowed()` で個別に守る。
    public static var heavyWorkAllowedLocal: Bool { heavyWorkAllowed(requiresNetwork: false) }

    private static func heavyWorkAllowed(requiresNetwork: Bool) -> Bool {
        // ⚠️ **熱はデバッグ全開・手動ブーストより優先**する。夜間の解析で端末が温まると
        // iOS が「冷めてから充電します」に入り、朝に充電が終わっていない（実フィードバック）。
        // 充電されなければ翌晩も進まないので、ここだけは明示操作でも免除しない。
        if ThermalGate.shared.shouldPause() { return false }
        if debugForceHeavyWork { return true }
        if Date() < manualBoostUntil {
            return PowerStateMonitor.shared.isOnPower && !PowerStateMonitor.shared.isLowPowerMode
        }
        guard !uiBusy else { return false }
        // 低電力モードはどの設定でも常時ブロック（安全弁）。電源ポリシーの whileCharging にも
        // 含まれるが、`always` を選んでいても低電力モードは尊重する。
        guard !PowerStateMonitor.shared.isLowPowerMode else { return false }
        let idle = BackgroundActivityMonitor.shared.idleSeconds >= HeavyWorkTiming.foregroundIdleSeconds
        return HeavyWorkTiming.current.allows(
            isConservative: HeavyWorkTiming.isConservative,
            isAppActive: isAppActive,
            foregroundIdle: idle,
            powerAllowed: PowerStateMonitor.shared.backgroundAllowed(),
            networkAllowed: NetworkStateMonitor.shared.networkAllowed(),
            requiresNetwork: requiresNetwork)
    }

    /// **中断できない一枚岩の重い処理**の許可判定（AI アルバムの本番化＝FM 解釈＋フル検索＋
    /// 重心構築、ドリフト再評価、アルバム自動生成）。
    ///
    /// トリクル系（埋め込み・顔・タグ）は 1 単位ごとに `heavyShouldPause()` で譲れるので
    /// 前面アイドル（控えめ OFF＋20 秒放置）でも安全だが、一枚岩はいったん始まると
    /// 数十秒〜数十分 ANE・CPU・ModelActor を占有し、**ユーザーが戻ってきても途中で譲れない**
    /// （diagnostics-46: 前面 finalize 中の操作が毎回引っかかる＝「いちいち固まる」の正体）。
    /// よって前面アイドルでは動かさず、**非アクティブ（画面ロック・アプリ切替＝主役は夜間 BGTask）
    /// に限定**する。手動ブースト/デバッグ全開は明示操作なので免除（従来どおり前面でも動く）。
    public static var monolithicHeavyWorkAllowed: Bool {
        guard heavyWorkAllowed else { return false }
        if debugForceHeavyWork || Date() < manualBoostUntil { return true }
        return !isAppActive
    }

    /// 重い処理（CLIP 埋め込み・顔スキャン・Vision タグ）の譲り判定：**ローカル許可**を満たさない、
    /// またはアルバム生成中（相互排他）なら譲る。ローカル処理は回線条件を課さない（Wi-Fi 不要）。
    /// クラウド分（サムネDL）は各処理側が `NetworkStateMonitor.networkAllowed()` で別途ゲートする。
    /// ※ 生成側（refreshIfNeeded）は回線ありの `heavyWorkAllowed` を見る（自分のフラグは見ない）。
    /// ※ **デバッグ全開時（debugForceHeavyWork）は生成との相互排他も外す**。「夜間ルーチンを今すぐ実行」
    ///   で検証するとき、generate のフラグ滞留で顔/埋め込みが一切動かないのを避ける（メモリは検証者が承知）。
    public static func heavyShouldPause() -> Bool {
        // 熱はデバッグ全開でも効かせる（上の注記と同じ理由）。
        if ThermalGate.shared.shouldPause() { return true }
        // ⚠️ 起動・復帰の一括ロード中も譲る（`HeavyLoad`）。単体では健全な処理でも、
        // 73k 件の実体化・68k 件のパスアルバム・86k 件のマージ・モデルのロードが重なると
        // footprint が 569MB まで伸びる（実機 diagnostics-66・背面 568MB で jetsam 実績あり）。
        // 生成との相互排他と同じ**メモリ保護**なので、デバッグ全開でも外さない。
        if HeavyLoad.isInFlight() { return true }
        if debugForceHeavyWork { return false }
        return !heavyWorkAllowedLocal || BackgroundActivityMonitor.shared.isGeneratingAlbums
    }
}
