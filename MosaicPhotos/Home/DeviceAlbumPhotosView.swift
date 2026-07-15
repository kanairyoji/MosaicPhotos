import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// 端末アルバムを開くビュー（ADR-39）。
/// PHAssetCollection の現存メンバー（ローカル）に、**オフロード台帳**にあるクラウド代替
/// （アプリが検証つきで端末から削除した写真の Dropbox パス）を合成して表示する。
/// PersonAlbumView / AutoAlbumPhotosView と同型のメンバー限定 MergedPhotoStore。
///
/// 台帳が空（＝オフロード機能が未使用）のときは cloudPathFilter が空集合になり、
/// クラウド写真は 1 枚も混ざらない＝従来の端末アルバム表示と完全に同じ。
/// 補完の条件を「台帳にある」に限定するのが要点：ユーザーが写真アプリで意図的に
/// 削除した写真まで Dropbox から蘇らせないため（metadata の albums 逆引きでは区別できない）。
struct DeviceAlbumPhotosView: View {
    @State private var store: MergedPhotoStore
    private let title: String

    init(album: LocalAlbumInfo, dropboxStore: DropboxPhotoStore, backupEngine: BackupEngine) {
        let localStore = LocalPhotoStore(localIdentifiers: album.localIdentifiers)
        let offloaded = backupEngine.offloadedPaths(inAlbum: album.name)
        _store = State(initialValue: MergedPhotoStore(
            dropboxStore: dropboxStore,
            localStore: localStore,
            cloudPathFilter: Set(offloaded)))
        title = album.name
    }

    var body: some View {
        PhotoSourceContentView(store: store, title: title)
    }
}
