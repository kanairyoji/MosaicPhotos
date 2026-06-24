import AutoAlbumCore
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

    init(album: AutoAlbumInfo, dropboxStore: DropboxPhotoStore) {
        let localStore = LocalPhotoStore(localIdentifiers: album.localIdentifiers)
        _store = State(initialValue: MergedPhotoStore(
            dropboxStore: dropboxStore,
            localStore: localStore,
            cloudPathFilter: Set(album.cloudPaths)))
        self.album = album
    }

    var body: some View {
        PhotoSourceContentView(store: store, title: album.placesLabel) {
            AutoAlbumDetailHeader(album: album)
        }
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
                // 日付範囲＋滞在日数。
                Label("\(DisplayDate.range(album.startDate, album.endDate)) · \(album.durationLabel)",
                      systemImage: "calendar")
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
