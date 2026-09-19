import AutoAlbumCore
import BackupKit
import DropboxKit
import PhotosFeatureKit
import MosaicSupport
import SwiftUI

// MARK: - 送信側: 解析データの供給（ADR-112）

/// AutoAlbumCore（タグ・CLIP）と FaceCore（顔シグナル）の解析を、BackupKit の
/// 解析データ DTO へ橋渡しする Composition Root アダプタ。
final class ShareAnalysisAdapter: ShareAnalysisSource {
    private let autoAlbumEngine: AutoAlbumEngine
    private let peopleEngine: PeopleEngine

    init(autoAlbumEngine: AutoAlbumEngine, peopleEngine: PeopleEngine) {
        self.autoAlbumEngine = autoAlbumEngine
        self.peopleEngine = peopleEngine
    }

    func analysisEntries(forRefKeys refKeys: [String]) async
        -> (versions: ShareAnalysisData.Versions, entries: [String: ShareAnalysisData.Entry]) {
        let analysis = await autoAlbumEngine.analysisExport(forRefKeys: refKeys)
        // 人物名を載せるかは設定（既定 ON・ADR-167）。OFF なら顔だけを送る。
        let includeNames = ShareSettingsKeys.isShareNamesEnabled()
        let faces = await peopleEngine.exportFaceSignals(forRefKeys: refKeys,
                                                         includeNames: includeNames)
        let versions = ShareAnalysisData.Versions(tag: AutoAlbumEngine.shareTagVersion,
                                             perception: AutoAlbumEngine.sharePerceptionVersion,
                                             face: peopleEngine.effectiveScanVersion)

        // base64 変換・辞書構築は数千枚規模になり得るのでオフメインで組み立てる。
        let entries = await Task.detached(priority: .utility) { () -> [String: ShareAnalysisData.Entry] in
            var entries: [String: ShareAnalysisData.Entry] = [:]
            for key in refKeys {
                var entry = ShareAnalysisData.Entry()
                if let a = analysis[key] {
                    entry.tags = a.tags.isEmpty ? nil : a.tags
                    entry.ocr = a.ocrText
                    entry.human = a.humanCount
                    entry.aes = a.aesthetic
                    entry.clip = a.clipHalf?.base64EncodedString()
                    // 撮影日（ADR-199）。受信側は Dropbox の日付しか見えず、共有コピーは
                    // サーバーサイドコピーなので EXIF 由来の `time_taken` が付かないことが多い
                    // ——載せないと**アップロード順**に並ぶ。
                    entry.d = a.captureDate?.timeIntervalSince1970
                }
                if let f = faces[key], !f.isEmpty {
                    entry.faces = f.map { signal in
                        ShareAnalysisData.Face(x: signal.boundingBox.origin.x,
                                          y: signal.boundingBox.origin.y,
                                          w: signal.boundingBox.width,
                                          h: signal.boundingBox.height,
                                          e: signal.embedding.base64EncodedString(),
                                          q: signal.quality,
                                          s: signal.hasSmile,
                                          d: signal.captureDate?.timeIntervalSince1970,
                                          n: signal.personName)
                    }
                }
                if entry != ShareAnalysisData.Entry() { entries[key] = entry }
            }
            return entries
        }.value
        return (versions, entries)
    }
}

// MARK: - 送信側: 作成元（人物・グループ・アルバム）の現在メンバー解決

/// 共有セットを「今の内容」に合わせ直すための解決役（ADR-112）。
/// BackupKit は人物・アルバムを知らないので、アプリ側がこの seam を埋める。
final class ShareSourceMemberResolver: ShareSourceResolver {
    private let peopleEngine: PeopleEngine
    private let autoAlbumEngine: AutoAlbumEngine
    private let dropboxStore: DropboxPhotoStore

    init(peopleEngine: PeopleEngine, autoAlbumEngine: AutoAlbumEngine, dropboxStore: DropboxPhotoStore) {
        self.peopleEngine = peopleEngine
        self.autoAlbumEngine = autoAlbumEngine
        self.dropboxStore = dropboxStore
    }

    func currentMembers(for key: ShareSourceKey) async -> [String]? {
        let raw: [String]
        switch key {
        case .group(let id):
            // 現存するグループだけ解決する（解除済みなら nil＝孤児セット）。
            guard peopleEngine.peopleGroups.contains(where: { $0.id == id }) else { return nil }
            raw = await peopleEngine.memberRefKeys(forGroup: id)
        case .person(let clusterID):
            guard peopleEngine.people.contains(where: { $0.clusterID == clusterID }) else { return nil }
            raw = await peopleEngine.memberRefKeys(forPerson: clusterID)
        case .album(let id):
            let all = autoAlbumEngine.albums + autoAlbumEngine.aiAlbums + autoAlbumEngine.pathAlbums
            guard let album = all.first(where: { $0.id == id }) else { return nil }
            raw = album.memberRefs
        }
        return await shareable(raw)
    }

    /// 共有に載せない refKey を落とす（解析候補の除外と同じ規則・ADR-183 C）。
    /// - 端末に原本があるバックアップコピー（原本の L- が既にメンバー）——同じ写真を 2 度コピーし、
    ///   宛先名が衝突して autorename と掃除の空回りになる。
    /// - 自分の共有ルート配下のコピー——共有の中へ共有をコピーすることになる。
    /// 幽霊（消えた写真の顔）は別途 `pruneMissingPhotos` が消す。
    private func shareable(_ refKeys: [String]) async -> [String] {
        let cloudItems = dropboxStore.items
        let excluded = await AnalysisCandidates.hiddenBackupCopyRefKeys(
            cloudItems: cloudItems, localRefKeys: refKeys.filter { $0.hasPrefix("L-") })
        guard !excluded.isEmpty else { return refKeys }
        let kept = refKeys.filter { !excluded.contains($0) }
        if kept.count != refKeys.count {
            Diagnostics.mark("share: source members — dropped \(refKeys.count - kept.count) backup/share copies")
        }
        return kept
    }
}

// MARK: - 受信側: 解析データの取り込み

/// 家族の共有フォルダから解析データを取得し、受信側の各ストア
/// （タグ台帳・CLIP 埋め込み・顔）へ取り込む。取り込み済み写真は夜間の自前解析
/// （サムネ DL＋推論）がスキップされる。
@Observable
final class SharedAnalysisImporter {
    private let dropboxStore: DropboxPhotoStore
    private let autoAlbumEngine: AutoAlbumEngine
    private let peopleEngine: PeopleEngine
    /// 受信した撮影日が増えたときに呼ぶ（表示中の一覧へ反映させる・ADR-199）。
    private let onCaptureDatesChanged: (@MainActor () async -> Void)?
    private(set) var isRunning = false

    init(dropboxStore: DropboxPhotoStore, autoAlbumEngine: AutoAlbumEngine,
         peopleEngine: PeopleEngine,
         onCaptureDatesChanged: (@MainActor () async -> Void)? = nil) {
        self.dropboxStore = dropboxStore
        self.autoAlbumEngine = autoAlbumEngine
        self.peopleEngine = peopleEngine
        self.onCaptureDatesChanged = onCaptureDatesChanged
    }

    /// 家族フォルダが設定されていれば、更新された解析データを取得して取り込む。
    func runIfNeeded() async {
        guard !isRunning else { return }
        // 「受ける」が OFF なら何もしない（提供・バックアップとは独立・ADR-112 追記）。
        guard ShareSettingsKeys.isReceiveEnabled() else { return }
        let roots = ShareSettingsKeys.currentFamilyFolders()
        guard !roots.isEmpty else { return }
        guard case .connected = dropboxStore.auth.connectionStatus,
              let token = try? await dropboxStore.auth.freshAccessToken() else { return }
        isRunning = true
        defer { isRunning = false }

        let fetched = await ShareAnalysisFetch().fetchUpdated(roots: roots, token: token)
        guard !fetched.isEmpty else { return }

        let versions = ShareImportPlanning.ReceiverVersions(
            tag: AutoAlbumEngine.shareTagVersion,
            perception: AutoAlbumEngine.sharePerceptionVersion,
            face: peopleEngine.effectiveScanVersion)

        // ⚠️ ここから先は **すべてオフメイン**（規約: 巨大コレクションを MainActor に通さない）。
        // 受信側の突合は 6.8 万件規模の走査＋文字列生成、さらに解析データごとの base64 デコード
        // （数千顔ぶん）を伴う。メインで回すとホーム描画・スクロールを直撃する。
        // メインへ戻すのは各ストアへ渡す Sendable なバッチだけにする。
        let itemsSnapshot = dropboxStore.items.map { (path: $0.path, hash: $0.contentHash) }
        let rootsLower = roots.map { $0.lowercased() }
        let prepared = await Task.detached(priority: .utility) { () -> [PreparedImport] in
            // 家族フォルダ配下 かつ content_hash があるものだけを突合対象にする。
            let localItems: [ShareImportPlanning.LocalItem] = itemsSnapshot.compactMap { item in
                guard let hash = item.hash else { return nil }
                let lower = item.path.lowercased()
                guard rootsLower.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") })
                else { return nil }
                return ShareImportPlanning.LocalItem(refKey: PhotoRef.cloud(item.path).encoded,
                                                     contentHash: hash)
            }
            // 索引は 1 回だけ作って解析データ間で使い回す。
            let index = ShareImportPlanning.index(of: localItems)
            let hashSet = Set(index.keys)

            return fetched.map { analysisData in
                let batch = ShareImportPlanning.plan(analysisData: analysisData.file, index: index,
                                                     versions: versions)
                let tags = batch.tags.map {
                    (refKey: $0.refKey,
                     info: PhotoSenseInfo(tags: $0.entry.tags ?? [], ocrText: $0.entry.ocr,
                                          humanCount: $0.entry.human, aesthetic: $0.entry.aes))
                }
                var faces: [(refKey: String, faces: [DetectedFaceSignal])] = []
                for (refKey, rawFaces) in batch.faces {
                    let signals = rawFaces.compactMap { face -> DetectedFaceSignal? in
                        guard let embedding = Data(base64Encoded: face.e) else { return nil }
                        return DetectedFaceSignal(
                            boundingBox: CGRect(x: face.x, y: face.y, width: face.w, height: face.h),
                            embedding: embedding, quality: face.q, hasSmile: face.s,
                            captureDate: face.d.map { Date(timeIntervalSince1970: $0) },
                            personName: face.n)
                    }
                    if !signals.isEmpty { faces.append((refKey, signals)) }
                }
                // まだ同期されていない写真が残っている解析データは rev を記録しない
                // （次回の実行で残りを取り込む。取り込みは既存レコードをスキップするので冪等）。
                let fullyMatched = analysisData.file.entries.keys.allSatisfy { hashSet.contains($0) }
                // 撮影日は refKey（"C-<path>"）で来るので、表示側が引く形（パス小文字）へ戻す。
                var captureDates: [String: Date] = [:]
                for (refKey, date) in batch.captureDates {
                    guard case .cloud(let path)? = PhotoRef.decode(refKey) else { continue }
                    captureDates[path.lowercased()] = date
                }
                return PreparedImport(analysisData: analysisData, tags: tags,
                                      embeddings: batch.embeddings, faces: faces,
                                      captureDates: captureDates, fullyMatched: fullyMatched)
            }
        }.value

        // ⚠️ **撮影日はここで先に確定させる**（ADR-199）。取り込み（タグ/埋め込み/顔）とは
        // 独立した表示用の事実で、モデル版が合わず本体の取り込みが 1 件も起きない相手でも、
        // 並び順だけは直せる。
        //
        // ⚠️ 掃除は**全部の解析データが突合できた回だけ**。同期が途中だと「まだ手元に無いだけ」の
        // 写真まで一覧から消えて見え、その記録を捨ててしまう（解析データの rev は突合が済むまで
        // 記録されないので再取得はされるが、それまでの間、並びが黙って壊れる）。
        let fullyMatchedAll = prepared.allSatisfy(\.fullyMatched)
        let syncedSharedPaths: Set<String>? = fullyMatchedAll
            ? Set(itemsSnapshot.map { $0.path.lowercased() }.filter { lower in
                rootsLower.contains { lower == $0 || lower.hasPrefix($0 + "/") }
            })
            : nil
        let incomingDates = prepared.reduce(into: [String: Date]()) { acc, item in
            acc.merge(item.captureDates) { _, new in new }
        }
        if !incomingDates.isEmpty {
            let table = await Task.detached(priority: .utility) {
                SharedCaptureDateStore().record(incomingDates, keeping: syncedSharedPaths)
            }.value
            Diagnostics.mark("share import: capture dates — +\(incomingDates.count), total \(table.count)")
            // 開きっぱなしの一覧にも効かせる（次に開き直すまで古い並びのままにしない）。
            await onCaptureDatesChanged?()
        }

        for prepared in prepared {
            let counts = await autoAlbumEngine.importSharedAnalysis(
                tags: prepared.tags, embeddings: prepared.embeddings)
            let faces = await peopleEngine.importFaceScans(prepared.faces)
            Diagnostics.mark("share import: \(prepared.analysisData.setFolderPathLower) — "
                + "tags \(counts.tags), embeddings \(counts.embeddings), faces \(faces.photos) photos")
            // ⚠️ 「取り込み済み」を記録するのは、**全部コミットできたとき**だけ。
            // 保存に失敗した回に記録すると、同じ解析データは以後ダウンロードされず、
            // 欠けた解析結果を再取得できない（レビュー指摘）。
            // 未同期の写真が残っている場合（fullyMatched=false）も同様に記録しない。
            let committed = counts.saved && faces.saved
            if prepared.fullyMatched && committed {
                ShareAnalysisFetch.markImported(prepared.analysisData)
            } else if !committed {
                Diagnostics.mark("share import: \(prepared.analysisData.setFolderPathLower) — "
                    + "not marked imported (persistence failed); will retry")
            }
        }
    }
}

/// オフメインで組み立てた取り込み材料（メインへはこれだけ返す）。
private struct PreparedImport: Sendable {
    let analysisData: ShareAnalysisFetch.Fetched
    let tags: [(refKey: String, info: PhotoSenseInfo)]
    let embeddings: [(refKey: String, vectorHalf: Data)]
    let faces: [(refKey: String, faces: [DetectedFaceSignal])]
    /// Dropbox パス（小文字）→ 撮影日（ADR-199・表示の並び替え用）。
    let captureDates: [String: Date]
    /// 解析データの全エントリが手元の写真に突合できたか（rev 記録の可否）。
    let fullyMatched: Bool
}

// MARK: - 共有の表示ポリシー（送信側の二重表示対策）

enum ShareVisibility {
    /// 自分の共有ルートを Cloud/All の表示から除外する（原本と共有コピーの重複表示を防ぐ）。
    /// ただしそのパスが「家族フォルダ」として登録されている場合は除外しない（受信側）。
    ///
    /// ⚠️ ADR-175 で共有ルートは `<backup root>/<端末>/Share` になった。バックアップルートは
    /// 同期対象（ADR-44）なので、除外しないと**自分の共有コピーが必ず一覧に出る**。
    /// 旧配置（`/MosaicShare`）が設定に残っていれば、そちらも引き続き隠す（旧フォルダは
    /// 移行せず残す方針なので、片付けるまで二重表示になるのを防ぐ）。
    static func apply(to store: DropboxPhotoStore) {
        let family = ShareSettingsKeys.currentFamilyFolders().map { $0.lowercased() }
        var roots = [ShareSettingsKeys.currentShareRoot().lowercased()]
        if let legacy = ShareSettingsKeys.legacyShareRootIfAny()?.lowercased() { roots.append(legacy) }
        store.setExcludedPathPrefixes(roots.filter { !family.contains($0) })
    }
}
