import Foundation
import SwiftData
import DropboxCore

/// `BackupEngine` の SwiftData 由来 API（アルバム集計・ローカル↔クラウド対応表）。
/// 実体はすべて `BackupStore`（@ModelActor・オフメイン）へ委譲する薄い層（A1/B1）。
extension BackupEngine {

    /// バックアップ済みの「ローカル localIdentifier → Dropbox path」対応。
    /// 自動アルバムのローカル↔クラウド重複排除（BackupLinkProvider）に使う。
    /// fetch は store actor（オフメイン）で実行される。
    public func localToCloudPathsDetached() async -> [String: String] {
        await store().localToCloudPaths()
    }

    // MARK: - Album query

    /// BackupAssetRecord からアルバム集計を読み込み、albumInfos / recordCount を更新する。
    /// ビュー表示時とバックアップ完了後に呼び出す。集計は store actor（オフメイン）。
    public func loadAlbums() async {
        await Task.yield()   // 呼び出し元の初回レンダリングを先に通す
        let (count, built) = await store().albumSummary()
        recordCount = count
        albumInfos = built
        isAlbumsLoaded = true
        addLog("[albums] records: \(count), built \(built.count) album(s)")
    }
}
