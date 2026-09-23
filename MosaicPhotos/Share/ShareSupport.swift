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
                    // Dropbox は 2019-12-02 以降、一覧系で `media_info` を返さないので `time_taken` は nil
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
            // ⚠️ 在るかどうかは `personExists`（＝`allPeople`）で見る。`people` は表示の線
            // （無名でフロア未満を隠す・ADR-125）なので、枚数が減っただけで孤児扱いになる。
            guard peopleEngine.personExists(clusterID: clusterID) else { return nil }
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
        // ⚠️ 表示用の `items` ではなく台帳の射影（ADR-224）。全列の実体化を避ける。
        let cloudItems = await dropboxStore.cloudPhotoRefs()
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
        let familyRoots = ShareSettingsKeys.currentFamilyFolders()
        guard case .connected = dropboxStore.auth.connectionStatus else { return }
        // ⚠️ **旗は `await` の前に立てる**（レビュー指摘）。トークンの更新は通信を伴うので
        // ここで実際に中断し、旗が立つ前に 2 本目が入口を通り抜けられた。2 本同時に走ると
        // 撮影日の表（読んで・混ぜて・書く）が**後勝ちで片方を丸ごと失い**、しかも先行分は
        // rev を「取り込み済み」にしてしまうので二度と取り直せない（ADR-199）。
        isRunning = true
        defer { isRunning = false }
        guard let token = try? await dropboxStore.auth.freshAccessToken() else { return }

        // 記録の置き場所を持つので、この実行のあいだ 1 つのインスタンスを使い回す。
        let fetcher = ShareAnalysisFetch()
        // 家族の共有フォルダ（コピーと対の解析）に加えて、**同じ Dropbox に繋がっている
        // 他の端末**が公開した解析（`<root>/<端末>/Analysis`）も見る（ADR-222）。
        // 写真そのものは接続した時点で相手からも見えているので、共有セットを作らなくても
        // 解析（タグ・埋め込み・顔・人物名・撮影日）が行き渡る。
        let discovered = await fetcher.accountAnalysisRoots(
            backupRoot: UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder)
                ?? BackupSettingsKeys.defaultDropboxFolder,
            ownDeviceFolder: BackupDeviceIdentity.currentFolderName(), token: token)
        let roots = familyRoots + discovered.roots
        guard !roots.isEmpty else { return }
        // 発見が途中で失敗した回は記録（rev）を掃除させない（取り直しの山を作らない）。
        let fetched = await fetcher.fetchUpdated(roots: roots, token: token,
                                                 discoveryComplete: discovered.listedAll)
        guard !fetched.isEmpty else { return }

        let versions = ShareImportPlanning.ReceiverVersions(
            tag: AutoAlbumEngine.shareTagVersion,
            perception: AutoAlbumEngine.sharePerceptionVersion,
            face: peopleEngine.effectiveScanVersion)

        // ⚠️ ここから先は **すべてオフメイン**（規約: 巨大コレクションを MainActor に通さない）。
        // 受信側の突合は 6.8 万件規模の走査＋文字列生成、さらに解析データごとの base64 デコード
        // （数千顔ぶん）を伴う。メインで回すとホーム描画・スクロールを直撃する。
        // メインへ戻すのは各ストアへ渡す Sendable なバッチだけにする。
        // ⚠️ **`items` から hash を拾わない**（レビュー指摘・公開側の diagnostics-84 と同じ罠）。
        // 表示用の `DropboxFileItem` は content_hash を**わざと持たない**ので、ここを `items` に
        // すると突合の鍵が 1 つも作れず、**取り込みが永久に 0 件**になる（しかも
        // `fullyMatched` が常に false なので rev も記録されず、毎晩同じシャードを取り直す）。
        // 台帳の表から取る＝公開側と同じ出典。
        let hashesByPath = await dropboxStore.cloudContentHashes()
        let prepared = await Task.detached(priority: .utility) { () -> [PreparedImport] in
            // 突合の対象は**手元のクラウド写真すべて**（ADR-222）。家族フォルダの外にも
            // 相手の写真はある——鍵は content_hash（同じ中身＝同じ写真）なので置き場所で絞らない。
            let localItems = hashesByPath.map { path, hash in
                ShareImportPlanning.LocalItem(refKey: PhotoRef.cloud(path).encoded,
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
        // ⚠️ 掃除の基準が信用できるのは、**手元の一覧が出そろっているとき**だけ。
        // 初回同期の途中だと「まだ手元に無いだけ」の写真が一覧から消えて見え、その記録を捨てる。
        // 捨てた写真の解析データは rev が記録済みなら二度と取り直せない（レビュー指摘）。
        let cacheSettled: Bool
        switch dropboxStore.syncState {
        case .initialSync, .error: cacheSettled = false
        case .idle, .polling, .fetchingDelta: cacheSettled = true
        }
        let fullyMatchedAll = cacheSettled && prepared.allSatisfy(\.fullyMatched)
        // 掃除の基準も突合と同じ広さ（クラウド写真すべて）にする。狭いままだと、
        // 共有フォルダの外の写真の撮影日を「もう無い写真のもの」と見て捨ててしまう。
        let syncedSharedPaths: Set<String>? = fullyMatchedAll ? Set(hashesByPath.keys) : nil
        let incomingDates = prepared.reduce(into: [String: Date]()) { acc, item in
            acc.merge(item.captureDates) { _, new in new }
        }
        // 保存そのものに失敗した回だけ「取り込み済み」を見送る（やり直す価値がある）。
        // ⚠️ 上限に当たって入らなかったぶんで見送ってはいけない——やり直しても同じ結果なので、
        // その解析データは永久に取り込み済みにならず、1 回あたりの取得上限を食い潰して
        // **その先のシャードが一つも取れなくなる**（レビュー指摘）。
        var captureDateSaveFailed = false
        if !incomingDates.isEmpty {
            let outcome = await Task.detached(priority: .utility) {
                SharedCaptureDateStore().record(incomingDates, keeping: syncedSharedPaths)
            }.value
            // ⚠️ 見送るのは**数回まで**。容量不足のように直らない失敗だと毎回見送られ、
            // 取り込みが一度も記録されないまま毎回同じシャードを取り直し続ける（レビュー指摘）。
            captureDateSaveFailed = outcome.saveFailed
                && fetcher.shouldRetryCaptureDateSave()
            if !outcome.saveFailed { fetcher.resetCaptureDateSaveFailures() }
            Diagnostics.mark("share import: capture dates — +\(incomingDates.count), "
                + "total \(outcome.table.count), overCap \(outcome.droppedByCap.count), "
                + "evicted \(outcome.evictedExisting), saveFailed \(outcome.saveFailed)")
            if !outcome.droppedByCap.isEmpty || outcome.evictedExisting > 0 {
                // 表の上限。押し出された既存ぶんは**既に取り込み済み＝再取得されない**ので、
                // その写真の並びは戻らない。黙って起きないよう必ず残す。
                Diagnostics.mark("share import: capture-date table is full "
                    + "(cap \(SharedCaptureDateStore.maxEntries)) — "
                    + "\(outcome.droppedByCap.count) incoming did not fit, "
                    + "\(outcome.evictedExisting) existing evicted (ordering lost for those)")
            }
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
            // 撮影日の**保存に失敗した**回は見送る（次回やり直せる）。
            let datesLanded = prepared.captureDates.isEmpty || !captureDateSaveFailed
            let committed = counts.saved && faces.saved
            if prepared.fullyMatched && committed && datesLanded {
                fetcher.markImported(prepared.analysisData)
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

// MARK: - 送信側: クラウド写真の解析を同じ Dropbox の人へ公開（ADR-222）

/// 手元のクラウド写真ぜんぶの解析結果を `<root>/<端末>/Analysis` へ公開する役
/// （本体は BackupKit の `AnalysisPublisher`。ここは「どの写真を渡すか」を決めるだけ）。
///
/// 共有セット（`Share/`）は**写真のコピーと対**なので、既に Dropbox にある写真には使えない。
/// 家族が同じ Dropbox に繋いだだけの状態でも解析（タグ・埋め込み・顔・人物名・撮影日）が
/// 行き渡るように、写真はコピーせず解析だけを置く。
@Observable
final class CloudAnalysisPublisher {
    private let dropboxStore: DropboxPhotoStore
    private let publisher: AnalysisPublisher
    private(set) var isRunning = false

    init(dropboxStore: DropboxPhotoStore, analysisSource: ShareAnalysisSource?) {
        self.dropboxStore = dropboxStore
        self.publisher = AnalysisPublisher(tokenProvider: dropboxStore.auth,
                                           analysisSource: analysisSource)
    }

    /// 1 回ぶん公開する（変わったシャードだけ・上限つき。続きは次の窓で）。
    /// - Returns: 画面に出す短い状態（診断ログにも同じ内容が残る）。
    ///
    /// ⚠️ **抜けるときも必ず 1 行残す**（実機ログ diagnostics-83）。黙って return すると、
    /// ログを見ても「順番が回ってこなかった」のか「回ってきたが抜けた」のか区別できない。
    @discardableResult
    func runIfNeeded() async -> String {
        guard !isRunning else { return mark("すでに実行中") }
        guard ShareSettingsKeys.isPublishAnalysisEnabled() else { return mark("設定がオフ") }
        guard case .connected = dropboxStore.auth.connectionStatus else {
            return mark("Dropbox に接続していない")
        }
        isRunning = true
        defer { isRunning = false }
        // ⚠️ 一覧が出そろう前に公開しない。途中の一覧で作ったシャードは「消えた写真」の
        // 掃除（stale）に引っかかり、次の窓で上げ直す空回りになる。
        switch dropboxStore.syncState {
        case .initialSync, .error: return mark("クラウドの一覧が同期中 — 出そろってから公開する")
        case .idle, .polling, .fetchingDelta: break
        }
        // ⚠️ **`dropboxStore.items` から hash を拾わない**（実機ログ diagnostics-84）。
        // 表示用の `DropboxFileItem` は content_hash を**わざと持たない**（67k 件の長寿命配列に
        // 64 桁の文字列を載せないため）ので、毎回 0 件になっていた。さらに `items` は
        // 画面を開いたときだけ作られるので、背景の窓では空のこともある。台帳から射影で取る。
        let hashes = await dropboxStore.cloudContentHashes()
        // ⚠️ 9.9 万件の map を**メインで回さない**（CLAUDE.md 性能原則 4）。ここはアプリ層＝
        // 既定 MainActor なので、書かないとホーム描画を直撃する。重い一括なので札も立てる（ADR-122）。
        let photos = await Task.detached(priority: .utility) {
            await HeavyLoad.span("share.publishAnalysis.photos") {
                hashes.map { path, hash in
                    AnalysisPublisher.CloudPhoto(refKey: PhotoRef.cloud(path).encoded,
                                                 contentHash: hash)
                }
            }
        }.value
        guard !photos.isEmpty else { return mark("クラウド写真が 0 件") }
        let outcome = await publisher.publish(photos: photos)
        blockedBy = outcome.blockedBy
        return outcome.message
    }

    /// **別の端末が公開している**ときの相手（設定画面が注意を出すために見る）。
    private(set) var blockedBy: AnalysisOwnership.Owner?

    /// 今 Dropbox に名乗っている端末を読む（設定画面を開いたときの確認用）。
    /// 自分が名乗っているなら nil を返す（注意は出さない）。
    func otherPublishingDevice() async -> AnalysisOwnership.Owner? {
        guard case .connected = dropboxStore.auth.connectionStatus else { return nil }
        let owner = await publisher.currentOwner()
        let decision = AnalysisOwnership.decide(
            remote: owner, myDeviceFolder: BackupDeviceIdentity.currentFolderName(),
            acknowledgedDeviceFolder:
                UserDefaults.standard.string(forKey: ShareSettingsKeys.acknowledgedAnalysisOwner))
        blockedBy = { if case .otherDevice(let o) = decision { return o } else { return nil } }()
        return blockedBy
    }

    /// 「この端末で公開する」（引き継ぎ）。⚠️ 相手の公開は止まらない——**止める手立ては無い**ので、
    /// 相手の端末でも設定を切ってもらう必要がある。承諾は**その相手に対してだけ**効く。
    func takeOverPublishing() {
        guard let owner = blockedBy else { return }
        UserDefaults.standard.set(owner.deviceFolder, forKey: ShareSettingsKeys.acknowledgedAnalysisOwner)
        blockedBy = nil
        Diagnostics.mark("share.publishAnalysis: 引き継ぎを承諾（前の端末 \(owner.deviceFolder)）")
    }

    private func mark(_ reason: String) -> String {
        Diagnostics.mark("share.publishAnalysis: \(reason)")
        return reason
    }
}
