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

    /// 重い処理（アルバム生成・CLIP 埋め込み・顔スキャン）を許可するアイドル時間（秒）。
    /// 「人が使っている最中は背景でも重い処理を動かさない」方針（使用感優先）。
    public static var heavyWorkIdleSeconds: TimeInterval = 60

    /// 重い処理の**開始/継続の共通条件**：電源接続中・低電力 OFF・UI 非ビジー・
    /// 最後の操作から `heavyWorkIdleSeconds` 以上アイドル。
    /// 起動直後は非アイドル扱い（lastInteractionAt=起動時刻）＝起動スパイクも自然に防ぐ。
    public static var heavyWorkAllowed: Bool {
        PowerStateMonitor.shared.isOnPower
            && !PowerStateMonitor.shared.isLowPowerMode
            && !uiBusy
            && BackgroundActivityMonitor.shared.idleSeconds >= heavyWorkIdleSeconds
    }

    /// 重い処理（CLIP 埋め込み・顔スキャン）の譲り判定：`heavyWorkAllowed` を満たさない、
    /// またはアルバム生成中（相互排他）なら譲る。
    /// ※ 生成側（refreshIfNeeded）は `heavyWorkAllowed` を見る（自分のフラグは見ない）。
    public static func heavyShouldPause() -> Bool {
        !heavyWorkAllowed || BackgroundActivityMonitor.shared.isGeneratingAlbums
    }
}
