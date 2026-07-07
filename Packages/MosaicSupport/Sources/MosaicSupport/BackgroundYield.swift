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
    public static var isAppActive = true

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

    /// 重い処理の**開始/継続の共通条件**：電源接続中・低電力 OFF・**Wi-Fi 接続中**・
    /// **アプリ非アクティブ（画面ロック/切替）**。手動ブースト中は非アクティブ/Wi-Fi を免除
    /// （明示操作＝フォアグラウンド実行を許可）。
    /// 旧方式（アイドル60秒）は「充電しながら閲覧中に走り出して操作が重くなる」ため廃止した。
    public static var heavyWorkAllowed: Bool {
        if debugForceHeavyWork { return true }
        let powerOK = PowerStateMonitor.shared.isOnPower && !PowerStateMonitor.shared.isLowPowerMode
        guard powerOK else { return false }
        if Date() < manualBoostUntil { return true }
        return !isAppActive && NetworkStateMonitor.shared.isOnWiFi && !uiBusy
    }

    /// 重い処理（CLIP 埋め込み・顔スキャン）の譲り判定：`heavyWorkAllowed` を満たさない、
    /// またはアルバム生成中（相互排他）なら譲る。
    /// ※ 生成側（refreshIfNeeded）は `heavyWorkAllowed` を見る（自分のフラグは見ない）。
    public static func heavyShouldPause() -> Bool {
        !heavyWorkAllowed || BackgroundActivityMonitor.shared.isGeneratingAlbums
    }
}
