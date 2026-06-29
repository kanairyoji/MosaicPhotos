import Foundation
import Observation

/// バックグラウンド処理（AI 埋め込み・自動アルバム生成・場所/アルバム走査）の稼働状況を集約する
/// ライブ計測。`DropboxActivityMonitor`（Dropbox 通信）/ `PowerStateMonitor`（電源）と並ぶ系列で、
/// 画面最上部のアクティビティバーが購読して 1 行で可視化する。
///
/// 各処理（`AutoAlbumEngine` / `PlaceScanner` / `LocalAlbumScanner`）が状態を報告し、UI は
/// `@Observable` として追従する。報告は MainActor 上の Bool/Int 代入のみで軽量。
@MainActor
@Observable
public final class BackgroundActivityMonitor {
    public static let shared = BackgroundActivityMonitor()

    // MARK: - AI 画像埋め込み（CLIP）
    /// 背景 CLIP 埋め込みが稼働中か。
    public var isEmbedding = false
    /// 残り未埋め込み枚数（おおよそ）。0 で非表示扱い。
    public var embedRemaining = 0

    // MARK: - 自動アルバム生成
    public var generatingTimePlace = false
    public var generatingFolder = false
    public var isGeneratingAlbums: Bool { generatingTimePlace || generatingFolder }

    // MARK: - スキャン
    public var isScanningPlaces = false
    public var isScanningAlbums = false

    // MARK: - 前景の重い処理（背景処理に譲らせる用）
    /// Dropbox サムネイルの取得（ドレイン）が稼働中か。クラウド閲覧中は CLIP 背景埋め込みを
    /// 一時停止させ、サムネのデコード/ネットと CPU を奪い合わないようにする（PhotoTagger が参照）。
    public var cloudThumbnailBusy = false

    private init() {}
}
