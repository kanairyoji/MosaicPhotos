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
    /// CLIP 埋め込み・顔スキャンが使う。**アルバム生成中も譲る**（相互排他）：起動直後に
    /// generate（85k 件の SwiftData 処理）と ANE 推論・画像ロードが同時に走るとメモリが
    /// 跳ね（実測 668MB）システム全体がストールするため、重い処理は同時に 1 種類に絞る。
    /// ※ 生成側（refreshIfNeeded）は `uiBusy` を見る（この関数ではない）ので循環しない。
    /// TODO(予定): 「電源接続かつ一定時間アイドル」のゲートをここに追加する（重い処理の
    /// 開始条件を本判定に集約してあるため、追加はこの 1 箇所で済む）。
    public static func shouldPause(powerOK: Bool) -> Bool {
        !powerOK || uiBusy || BackgroundActivityMonitor.shared.isGeneratingAlbums
    }
}
