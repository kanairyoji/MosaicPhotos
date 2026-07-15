import AutoAlbumCore
import BackupKit
import DropboxKit
import MosaicSupport
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Source host view

/// dismissToHome と showSettings を環境に注入するラッパー。
/// 各ソース（All / Photos / Cloud / アルバム / 場所）のフルスクリーン表示で共通利用する。
struct SourceHostView<Content: View>: View {
    /// ストア／エンジン一式。個別引数だと SettingsView へ渡し忘れが起きる（実績あり）ため一括で受け取る。
    let stores: HomeStores
    let dismissToHome: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var showingSettings = false

    var body: some View {
        let autoAlbumEngine = stores.autoAlbumEngine
        let peopleEngine = stores.peopleEngine
        content()
            .environment(\.dismissToHome, dismissToHome)
            .environment(\.showSettings, { showingSettings = true })
            .environment(\.photoInsight) { [autoAlbumEngine, peopleEngine, backupEngine = stores.backupEngine] id in
                // CLIP 由来の insight（タグ/解析状態）に、顔クラスタ由来の People 名と顔数を合成する。
                // 3 つの照会は**並行**で走らせる（顔照会が遅くても insight 表示を遅らせない）。
                async let base = autoAlbumEngine.insight(forItemID: id)
                async let names = peopleEngine.names(forItemID: id)
                async let faces = peopleEngine.faceCount(forItemID: id)
                var insight = await base ?? PhotoInsight(status: .notIndexed)
                let resolvedNames = await names
                if !resolvedNames.isEmpty { insight.people = resolvedNames }
                insight.faceCount = await faces
                // バックアップ状態のバッジ（端末写真のみ）。id は "L-…"/"C-…"（refKey）または
                // 生の localIdentifier / Dropbox パス。クラウド写真は対象外（nil＝非表示）。
                if let localID = Self.localIdentifier(fromItemID: id) {
                    insight.isBackedUp = await backupEngine.isBackedUp(localIdentifier: localID)
                }
                return insight
            }
            // スクラブ等の操作中は背景 CLIP 埋め込みを譲る（G）。操作はアイドル判定にも記録する。
            .environment(\.photoInteraction) { [autoAlbumEngine] interacting in
                autoAlbumEngine.setInteracting(interacting)
                if interacting { BackgroundActivityMonitor.shared.noteUserInteraction() }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView(stores: stores)
                }
            }
            // Developer Options が ON のとき、最上部に Dropbox 通信アクティビティを重ねる。
            .dropboxActivityBar()
    }

    /// PhotoItem.id → 端末写真の localIdentifier。
    /// id の形式: MergedPhotoItem は "L-…"/"C-…"（PhotoRef.encoded）、LocalPhotoItem は生の
    /// localIdentifier、DropboxFileItem は生の Dropbox パス（"/" 始まり）。クラウドは nil。
    nonisolated static func localIdentifier(fromItemID id: String) -> String? {
        if let ref = PhotoRef.decode(id) { return ref.localIdentifier }   // "L-…" → id / "C-…" → nil
        if id.hasPrefix("/") { return nil }                               // 生の Dropbox パス
        return id                                                         // 生の localIdentifier
    }

}
