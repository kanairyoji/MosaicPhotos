import AutoAlbumCore
import BackupKit
import CoreGraphics
import DropboxKit
import Foundation
import MobileCLIPKit
import MosaicSupport
import UIKit

/// アプリのアダプタ（Dropbox / バックアップ / 人物 / Vision / CLIP）を結線して `AutoAlbumEngine` を
/// 生成する Composition Root。HomeView の init をスリムに保つ。
@MainActor
func makeAutoAlbumEngine(dropboxStore: DropboxPhotoStore, backupEngine: BackupEngine,
                         peopleEngine: PeopleEngine) async -> AutoAlbumEngine {
    // クラウド path → CGImage（Dropbox サムネイル）。CLIP 埋め込みに使う。
    let cloudImage: @Sendable (String) async -> CGImage? = { path in
        let image = await dropboxStore.thumbnail(for: dropboxFileItem(path: path))
        return image.flatMap(orientationNormalizedCGImage)   // EXIF 回転を正規化（座標ズレ防止）
    }
    let warmCloud = makeCloudThumbnailWarmer(dropboxStore: dropboxStore)
    // ⚠️ @ModelActor は「init したスレッド」で実行される（SwiftData の罠）。MainActor で
    // 生成すると全 SwiftData 処理（85k fetch/prune/upsert）がメインスレッドで走り
    // 実測 14.5s ハングの真因になったため、オフメイン生成ファクトリを使う。
    let engine = await AutoAlbumEngine.makeWithOffMainStore(
        cloudProvider: DropboxCloudPhotoProvider(store: dropboxStore),
        backupLink: BackupLinkAdapter(engine: backupEngine),
        peopleProvider: FacePeopleProvider(engine: peopleEngine),
        perception: CLIPEmbeddingProvider(cloudImage: cloudImage, warmCloud: warmCloud),
        textEmbedder: MobileCLIPTextEmbedder(),
        translator: AppQueryTranslator(),
        labelProvider: CLIPDisplayLabeler(),
        tagProvider: VisionTagAdapter(cloudImage: cloudImage, warmCloud: warmCloud))
    // 顔スキャンの実測を AI アルバム評価に結線（「人が写っていない」等の除外を確実にする）。
    engine.setFaceCountsProvider { await peopleEngine.scannedFaceCounts() }
    // 名前付き人物の一覧を AI アルバムの人物名検索に結線（「太郎と花子」→ 木村太郎/木村花子 等）。
    engine.setNamedPeopleProvider { await peopleEngine.namedClusterNames() }
    // ⚠️ 語彙接地（ADR-101）は**まだ結線しない**。機構（VocabularyGrounding）と seam は入っているが、
    //    近さの計算を CLIP の**テキスト同士**の類似度で行う実装（CLIPConceptExpander）は
    //    実測で不十分だった: CLIP テキスト塔は異方性が強く、どの語も語彙全体と 0.67〜0.83 で並ぶ。
    //    z スコアで見ると pizza 6.07 / dog 4.31 は接地できる一方、**必要だった food → pizza が
    //    z=1.64 で判別できず**、逆に outdoor → cup が z=2.62 で誤接地する。
    //    正しい近さは text↔image（CLIP の学習目的そのもの）＝各タグを「そのタグが付いた写真の
    //    CLIP 画像埋め込みの重心」で表し、クエリ文と比べる。実装は次段階。
    // engine.setConceptExpander(CLIPConceptExpander())
    // 人物条件の評価は焼き込みでなく**現在の**顔クラスタ名で live 照合（命名/統合を即反映）。
    engine.setPeopleByRefKeyProvider { await peopleEngine.peopleNamesByRefKey() }
    // VLM キャプション（重い文章生成）をお気に入り限定にするため、お気に入り集合（PHAsset）を結線。
    engine.setFavoriteRefKeysProvider { await favoriteImageRefKeys(dropboxStore: dropboxStore) }

    // バックアップ metadata v2（ADR-38）: 端末を削除すると再生成できない情報の保全を結線する。
    // 人物名（顔クラスタのユーザー命名）— refKey "L-<id>" を localIdentifier キーに変換して渡す。
    backupEngine.peopleNamesProvider = { [weak peopleEngine] in
        guard let peopleEngine else { return [:] }
        let byRefKey = await peopleEngine.peopleNamesByRefKey()
        var out: [String: [String]] = [:]
        for (key, names) in byRefKey {
            if let id = PhotoRef.decode(key)?.localIdentifier { out[id] = names }
        }
        return out
    }
    // VLM キャプション（生成済みのテキストのみ・再生成はしない）。
    backupEngine.captionsProvider = { [weak engine] ids in
        guard let engine else { return [:] }
        let byRefKey = await engine.captions(forRefKeys: ids.map { PhotoRef.local($0).encoded })
        var out: [String: String] = [:]
        for (key, caption) in byRefKey {
            if let id = PhotoRef.decode(key)?.localIdentifier { out[id] = caption }
        }
        return out
    }
    return engine
}

/// ピープル（顔クラスタ）エンジンを組み立てる。顔検出/埋め込み実体は Vision+CoreML（MobileCLIPKit）。
/// 顔モデル未同梱なら無効（空表示）になる。代表写真の自動選択用にお気に入り集合（PhotoKit）を注入する。
/// クラウド写真の顔検出用に Dropbox のキャッシュ済みサムネ（128px・追加DL無し）を注入する。
func makePeopleEngine(dropboxStore: DropboxPhotoStore) async -> PeopleEngine {
    let cloudImage: @Sendable (String) async -> CGImage? = { path in
        let image = await dropboxStore.thumbnail(for: dropboxFileItem(path: path))
        return image.flatMap(orientationNormalizedCGImage)   // EXIF 回転を正規化（座標ズレ防止）
    }
    let warmCloud = makeCloudThumbnailWarmer(dropboxStore: dropboxStore)
    // FaceStore も同様にオフメイン生成（@ModelActor は init したスレッドで実行される）。
    return await PeopleEngine.makeWithOffMainStore(
        faceProvider: FacePerceptionAdapter(
            cloudImage: cloudImage, warmCloud: warmCloud,
            // 顔解析だけ 1024px をバッチ取得する（ADR-90）。ディスクには保存しない。
            //
            // ⚠️ **閲覧中は取りに行かない**（ADR-92）。この取得は表示用サムネと同じ回線を使うが、
            // 表示用バッチャ（可視セル優先・先読みは低優先）の**優先度制御を通らない**ため、
            // 素通しだと閲覧中のサムネを押しのける。実測 diag-36 で `thumb.missWaitMs` が
            // 1 件 8.6 秒に達し、前面ハングが 2 件→19 件（最大 10.3 秒）に悪化した。
            // 判定は既存の `BackgroundYield.uiBusy`（写真ビュー表示中・フル画像取得中・
            // 表示サムネ取得中・メモリ圧迫）に一元化する。譲った回は空を返すだけで、
            // 顔スキャンは次のバッチで拾い直す（差分処理なので取りこぼさない）。
            cloudAnalysisImages: { [weak dropboxStore] paths in
                guard await !MainActor.run(body: { BackgroundYield.uiBusy }) else {
                    PerfTrace.count("faceAnalysis.yield")
                    return [:]
                }
                return await dropboxStore?.faceAnalysisThumbnails(paths: paths) ?? [:]
            }),
        favoriteRefKeysProvider: { await favoriteImageRefKeys(dropboxStore: dropboxStore) })
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

/// クラウドサムネの**一括先行取得**クロージャを作る（ADR-83）。
///
/// 解析（顔・タグ・CLIP）はバッチ単位でこれを呼び、次に処理する写真のサムネをまとめて
/// 要求する。取得自体は `DropboxThumbnailBatcher` の低優先プール（25 枚/リクエスト・並列）で
/// 進むため、1 枚ずつ `thumbnail(for:)` を待つより往復が大幅に減る。
/// 回線ポリシーは `prefetch` 側（`speculativeFetchAllowed`＝ADR-81）が守る。
@MainActor
func makeCloudThumbnailWarmer(dropboxStore: DropboxPhotoStore) -> @Sendable ([String]) -> Void {
    { paths in
        Task { @MainActor in
            dropboxStore.prefetch(paths.map { dropboxFileItem(path: $0) }, targetSize: .zero)
        }
    }
}
