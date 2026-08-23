import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import MapKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// 自動アルバム（時間＋場所）を開くビュー。メンバーをローカル ID とクラウド path に分解し、
/// `MergedPhotoStore`（ローカル絞り込み＋Dropbox パスフィルタ）でローカル・クラウド混在を表示する。
/// 上部に旅行の概要（期間・訪問地・人物・地図）ヘッダーを置く。
struct AutoAlbumPhotosView: View {
    @State private var store: MergedPhotoStore
    private let album: AutoAlbumInfo
    /// 画面内「…」メニューの削除アクション（AI アルバムのみ・nil なら「…」を出さない）。
    private let onDelete: (() -> Void)?
    /// 家族共有（ADR-112）。未注入（nil）なら共有メニューを出さない。
    @Environment(ShareSyncEngine.self) private var shareEngine: ShareSyncEngine?
    @AppStorage(ShareSettingsKeys.provideEnabled) private var shareProvideEnabled = true
    @State private var showingShareSheet = false
    /// クラウド共有の停止対象（共有中のときだけメニューに出す）。
    @State private var stoppingShare: StopSharingTarget?

    init(album: AutoAlbumInfo, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex,
         onDelete: (() -> Void)? = nil) {
        _store = State(initialValue: .forMembers(
            localIDs: album.localIdentifiers, cloudPaths: album.cloudPaths,
            dropboxStore: dropboxStore, assetIndex: assetIndex))
        self.album = album
        self.onDelete = onDelete
    }

    var body: some View {
        PhotoSourceContentView(store: store, title: album.placesLabel) {
            AutoAlbumDetailHeader(album: album)
        }
        // アルバム画面内の「…」メニュー（ホームカードの「…」/長押しと同じ操作を画面内でも）。
        .environment(\.sourceMenuContent, menuContent)
        .sheet(isPresented: $showingShareSheet) {
            if let shareEngine {
                ShareSetCreationSheet(suggestedName: album.placesLabel,
                                      refKeys: album.memberRefs,
                                      shareEngine: shareEngine,
                                      sourceKey: ShareSourceKey.album(album.id).encoded)
            }
        }
        .stopSharingConfirmation($stoppingShare, shareEngine: shareEngine)
    }

    /// 共有中ならそのセット ID（メニューを「共有…」から「停止」へ入れ替える）。
    private var sharedSetID: UUID? {
        shareEngine?.sharedSetID(sourceKey: ShareSourceKey.album(album.id).encoded,
                                 name: album.placesLabel)
    }

    private var menuContent: (@MainActor () -> AnyView)? {
        let canShare = shareEngine != nil && shareProvideEnabled
        guard onDelete != nil || canShare else { return nil }
        return { AnyView(
            Menu {
                // 共有中なら「停止」、していなければ「共有…」——同じ場所で対になるようにする。
                if canShare {
                    if let setID = sharedSetID {
                        Button(role: .destructive) {
                            stoppingShare = StopSharingTarget(setID: setID,
                                                              name: album.placesLabel)
                        } label: {
                            Label("Stop Cloud Sharing…", systemImage: "icloud.slash")
                        }
                    } else {
                        Button { showingShareSheet = true } label: {
                            Label("Cloud Share…", systemImage: "icloud.and.arrow.up")
                        }
                    }
                }
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete Album", systemImage: "trash")
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(Text("Album options"))
        ) }
    }
}

/// 旅行アルバムの概要ヘッダー。訪問地（場所）と日付範囲をどちらも明確に見せ、
/// 滞在日数・件数・人物、座標があれば地図スナップショットを添える。
private struct AutoAlbumDetailHeader: View {
    let album: AutoAlbumInfo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let region {
                Map(initialPosition: .region(region), interactionModes: [])
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 3) {
                // 場所を主役（太字）に。
                Text("\(album.placesLabel)\(album.country.map { ", \($0)" } ?? "")")
                    .font(.headline)
                    .lineLimit(1)
                // 日付範囲＋滞在日数。取れない（カメラ既定の 1980 等・1990 未満）なら「日時不明」。
                Label(dateLine, systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // 件数＋（あれば）人物。
                Text(peopleAndCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 日付行。開始/終了が「意味のある日付」なら範囲＋滞在日数、取れなければ「日時不明」。
    /// カメラ既定値の 1980 等（1990 未満）や欠落は `DisplayDate.meaningful` で無意味として弾く。
    private var dateLine: String {
        guard let start = DisplayDate.meaningful(album.startDate),
              let end = DisplayDate.meaningful(album.endDate) else {
            return L("Date unknown")
        }
        return "\(DisplayDate.range(start, end)) · \(album.durationLabel)"
    }

    private var peopleAndCountText: String {
        var parts = ["\(album.photoCount) photos"]
        if !album.people.isEmpty { parts.append(album.people.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var region: MKCoordinateRegion? {
        guard let lat = album.latitude, let lon = album.longitude else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4))
    }
}
