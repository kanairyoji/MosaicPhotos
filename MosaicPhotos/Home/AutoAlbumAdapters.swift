import AutoAlbumCore
import BackupKit
import CoreGraphics
import DropboxKit
import Foundation
import MobileCLIPKit
import UIKit

/// アプリのアダプタ（Dropbox / バックアップ / 人物 / Vision / CLIP）を結線して `AutoAlbumEngine` を
/// 生成する Composition Root。HomeView の init をスリムに保つ。
@MainActor
func makeAutoAlbumEngine(dropboxStore: DropboxPhotoStore, backupEngine: BackupEngine) -> AutoAlbumEngine {
    // クラウド path → CGImage（Dropbox サムネイル）。CLIP 埋め込みに使う。
    let cloudImage: @Sendable (String) async -> CGImage? = { path in
        let item = DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
        let image = await dropboxStore.thumbnail(for: item)
        return image?.cgImage
    }
    return AutoAlbumEngine(
        cloudProvider: DropboxCloudPhotoProvider(store: dropboxStore),
        backupLink: BackupLinkAdapter(engine: backupEngine),
        peopleProvider: PeopleProviderAdapter(),
        perception: CLIPEmbeddingProvider(cloudImage: cloudImage),
        textEmbedder: MobileCLIPTextEmbedder(),
        translator: AppQueryTranslator(),
        labelProvider: CLIPDisplayLabeler())
}

/// `DropboxPhotoStore.items` を AutoAlbumCore の中立メタデータへ写像する CloudPhotoProvider 実体。
struct DropboxCloudPhotoProvider: CloudPhotoProvider {
    let store: DropboxPhotoStore

    func cloudPhotos() async -> [CloudPhotoMeta] {
        // ⚠️ items は All Photos/Cloud を開くまで読み込まれない。フォルダ名アルバム生成や
        //    クラウドのエンリッチはナビゲーション前にも走るため、空ならキャッシュから読み込む
        //    （これを怠ると metas=0 → アルバム生成0、さらに再生成で既存アルバムを消してしまう）。
        if await MainActor.run(body: { store.items.isEmpty }) {
            await store.loadItems()
        }
        return await MainActor.run {
            store.items.map { item in
                CloudPhotoMeta(path: item.path, captureDate: item.captureDate,
                               latitude: item.latitude, longitude: item.longitude,
                               contentHash: item.contentHash)
            }
        }
    }
}

/// `BackupEngine` のバックアップ記録から localId→path 対応を供給する BackupLinkProvider 実体。
struct BackupLinkAdapter: BackupLinkProvider {
    let engine: BackupEngine

    func localToCloudPath() async -> [String: String] {
        await MainActor.run { engine.localToCloudPaths() }
    }
}

/// 顔認識（People）インデックスから localId→人物名 対応を供給する PeopleProvider 実体。
/// 実体は BackupKit の `BackupPeopleIndex`（写真ライブラリの People アルバムを走査）。
struct PeopleProviderAdapter: PeopleProvider {
    func peopleByLocalIdentifier() async -> [String: [String]] {
        await BackupPeopleIndex.build()
    }
}
