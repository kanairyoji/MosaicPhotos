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
func makeAutoAlbumEngine(dropboxStore: DropboxPhotoStore, backupEngine: BackupEngine,
                         peopleEngine: PeopleEngine) async -> AutoAlbumEngine {
    // クラウド path → CGImage（Dropbox サムネイル）。CLIP 埋め込みに使う。
    let cloudImage: @Sendable (String) async -> CGImage? = { path in
        let image = await dropboxStore.thumbnail(for: dropboxFileItem(path: path))
        return image?.cgImage
    }
    // ⚠️ @ModelActor は「init したスレッド」で実行される（SwiftData の罠）。MainActor で
    // 生成すると全 SwiftData 処理（85k fetch/prune/upsert）がメインスレッドで走り
    // 実測 14.5s ハングの真因になったため、オフメイン生成ファクトリを使う。
    let engine = await AutoAlbumEngine.makeWithOffMainStore(
        cloudProvider: DropboxCloudPhotoProvider(store: dropboxStore),
        backupLink: BackupLinkAdapter(engine: backupEngine),
        peopleProvider: FacePeopleProvider(engine: peopleEngine),
        perception: CLIPEmbeddingProvider(cloudImage: cloudImage),
        textEmbedder: MobileCLIPTextEmbedder(),
        translator: AppQueryTranslator(),
        labelProvider: CLIPDisplayLabeler(),
        tagProvider: VisionTagAdapter(cloudImage: cloudImage))
    // 顔スキャンの実測を AI アルバム評価に結線（「人が写っていない」等の除外を確実にする）。
    engine.setFaceCountsProvider { await peopleEngine.scannedFaceCounts() }
    // 名前付き人物の一覧を AI アルバムの人物名検索に結線（「太郎と花子」→ 木村太郎/木村花子 等）。
    engine.setNamedPeopleProvider { await peopleEngine.namedClusterNames() }
    return engine
}

/// ピープル（顔クラスタ）エンジンを組み立てる。顔検出/埋め込み実体は Vision+CoreML（MobileCLIPKit）。
/// 顔モデル未同梱なら無効（空表示）になる。代表写真の自動選択用にお気に入り集合（PhotoKit）を注入する。
func makePeopleEngine() async -> PeopleEngine {
    // FaceStore も同様にオフメイン生成（@ModelActor は init したスレッドで実行される）。
    await PeopleEngine.makeWithOffMainStore(
        faceProvider: FacePerceptionAdapter(),
        favoriteRefKeysProvider: { await favoriteImageRefKeys() })
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
        // main では snapshot（COW の配列コピー＝軽い）だけ取り、67k 件の map は
        // オフメインで行う（generate から呼ばれるためメインを塞がない）。
        let items = await MainActor.run { store.items }
        return await Task.detached(priority: .utility) {
            items.map { item in
                CloudPhotoMeta(path: item.path, captureDate: item.captureDate,
                               latitude: item.latitude, longitude: item.longitude,
                               contentHash: item.contentHash)
            }
        }.value
    }
}

/// `BackupEngine` のバックアップ記録から localId→path 対応を供給する BackupLinkProvider 実体。
struct BackupLinkAdapter: BackupLinkProvider {
    let engine: BackupEngine

    func localToCloudPath() async -> [String: String] {
        // generate から呼ばれるためオフメイン版を使う（全件 materialize をメインでやらない）。
        await engine.localToCloudPathsDetached()
    }
}

/// 顔クラスタ（PeopleEngine）から localId→人物名 対応を供給する PeopleProvider 実体。
/// 旧実装（BackupPeopleIndex＝写真アプリの People アルバム走査）は subtype-1000 が非公開化され
/// **常に空**を返す死線だったため撤去し、自前の顔クラスタリング結果に置き換えた。
struct FacePeopleProvider: PeopleProvider {
    let engine: PeopleEngine

    func peopleByLocalIdentifier() async -> [String: [String]] {
        // FaceStore のキーは refKey（"L-<localId>"）。enrich 側は localIdentifier キーを期待する。
        let byRefKey = await engine.peopleNamesByRefKey()
        var out: [String: [String]] = [:]
        out.reserveCapacity(byRefKey.count)
        for (refKey, names) in byRefKey {
            if let localId = PhotoRef.decode(refKey)?.localIdentifier { out[localId] = names }
        }
        return out
    }
}
