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
            .environment(\.photoInsight) { [autoAlbumEngine, peopleEngine] id in
                // CLIP 由来の insight（タグ/解析状態）に、顔クラスタ由来の People 名を合成する。
                var insight = await autoAlbumEngine.insight(forItemID: id) ?? PhotoInsight(status: .notIndexed)
                let names = await peopleEngine.names(forItemID: id)
                if !names.isEmpty { insight.people = names }
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
}
