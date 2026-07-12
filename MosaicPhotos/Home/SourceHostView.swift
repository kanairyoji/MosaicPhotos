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
                // CLIP 由来の insight（タグ/解析状態）に、顔クラスタ由来の People 名と顔数を合成する。
                // 3 つの照会は**並行**で走らせる（顔照会が遅くても insight 表示を遅らせない）。
                async let base = autoAlbumEngine.insight(forItemID: id)
                async let names = peopleEngine.names(forItemID: id)
                async let faces = peopleEngine.faceCount(forItemID: id)
                var insight = await base ?? PhotoInsight(status: .notIndexed)
                let resolvedNames = await names
                if !resolvedNames.isEmpty { insight.people = resolvedNames }
                insight.faceCount = await faces
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
