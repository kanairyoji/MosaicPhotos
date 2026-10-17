#if canImport(UIKit)
import SwiftUI

/// フィルタボタン（下部バー中央）から開く、絞り込み条件の指定シート。
/// 条件は `PhotoFilter`（現状はお気に入りのみ）。変更は Binding で即時にグリッドへ反映される。
struct PhotoFilterSheet: View {
    @Binding var filter: PhotoFilter
    /// ソース（端末/クラウド）の絞り込み欄を出すか。混在ソースのビュー（MergedPhotoStore）のみ true。
    /// 単一ソース（写真タブ・クラウドタブ等）では意味がないため欄ごと出さない。
    let showsSourceOptions: Bool
    /// 写真／動画の絞り込み欄を出すか。動画を含み得るソース（`PhotoStore.includesVideos`）のみ true。
    let showsMediaOptions: Bool
    /// ベストショット欄を出すか。判定プロバイダ（AI 台帳）が注入されているビューのみ true。
    var showsQualityOption: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $filter.favoritesOnly) {
                        Label {
                            Text(L("Favorites only"))
                        } icon: {
                            Image(systemName: "heart.fill").foregroundStyle(.pink)
                        }
                    }
                } footer: {
                    Text(L("Show only photos marked as favorites. Cloud photos have no favorites and will be hidden."))
                }
                if showsMediaOptions {
                    Section {
                        Picker(selection: $filter.media) {
                            Text(L("All")).tag(PhotoFilter.Media.all)
                            Label(L("Photos"), systemImage: "photo").tag(PhotoFilter.Media.photosOnly)
                            Label(L("Videos"), systemImage: "video").tag(PhotoFilter.Media.videosOnly)
                        } label: {
                            Label {
                                Text(L("Type"))
                            } icon: {
                                Image(systemName: "photo.on.rectangle").foregroundStyle(.green)
                            }
                        }
                    } footer: {
                        Text(L("Show only photos or only videos."))
                    }
                }
                if showsQualityOption {
                    Section {
                        Toggle(isOn: $filter.beautifulOnly) {
                            Label {
                                Text(L("Best shots only"))
                            } icon: {
                                Image(systemName: "sparkles").foregroundStyle(.yellow)
                            }
                        }
                    } footer: {
                        Text(L("Show only well-shot photos with a high aesthetic score. Photos are scored automatically during nightly analysis."))
                    }
                }
                if showsSourceOptions {
                    Section {
                        Picker(selection: $filter.source) {
                            Text(L("All")).tag(PhotoFilter.Source.all)
                            Label(L("On-device"), systemImage: "iphone").tag(PhotoFilter.Source.localOnly)
                            Label(L("Cloud"), systemImage: "cloud").tag(PhotoFilter.Source.cloudOnly)
                        } label: {
                            Label {
                                Text(L("Source"))
                            } icon: {
                                Image(systemName: "externaldrive").foregroundStyle(.blue)
                            }
                        }
                    } footer: {
                        Text(L("Show only photos from your device or from Dropbox."))
                    }
                }
            }
            .navigationTitle(L("Filter Photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif
