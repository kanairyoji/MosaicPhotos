import AutoAlbumCore
import BackupKit
import DropboxKit
import MosaicSupport
import SwiftUI

// MARK: - 送信側: 解析サイドカーの供給（ADR-112）

/// AutoAlbumCore（タグ・CLIP）と FaceCore（顔シグナル）の解析を、BackupKit の
/// サイドカー DTO へ橋渡しする Composition Root アダプタ。
final class ShareAnalysisAdapter: ShareAnalysisSource {
    private let autoAlbumEngine: AutoAlbumEngine
    private let peopleEngine: PeopleEngine

    init(autoAlbumEngine: AutoAlbumEngine, peopleEngine: PeopleEngine) {
        self.autoAlbumEngine = autoAlbumEngine
        self.peopleEngine = peopleEngine
    }

    func analysisEntries(forRefKeys refKeys: [String]) async
        -> (versions: ShareSidecar.Versions, entries: [String: ShareSidecar.Entry]) {
        let analysis = await autoAlbumEngine.analysisExport(forRefKeys: refKeys)
        let faces = await peopleEngine.exportFaceSignals(forRefKeys: refKeys)
        let versions = ShareSidecar.Versions(tag: AutoAlbumEngine.shareTagVersion,
                                             perception: AutoAlbumEngine.sharePerceptionVersion,
                                             face: peopleEngine.effectiveScanVersion)

        // base64 変換・辞書構築は数千枚規模になり得るのでオフメインで組み立てる。
        let entries = await Task.detached(priority: .utility) { () -> [String: ShareSidecar.Entry] in
            var entries: [String: ShareSidecar.Entry] = [:]
            for key in refKeys {
                var entry = ShareSidecar.Entry()
                if let a = analysis[key] {
                    entry.tags = a.tags.isEmpty ? nil : a.tags
                    entry.ocr = a.ocrText
                    entry.human = a.humanCount
                    entry.aes = a.aesthetic
                    entry.clip = a.clipHalf?.base64EncodedString()
                }
                if let f = faces[key], !f.isEmpty {
                    entry.faces = f.map { signal in
                        ShareSidecar.Face(x: signal.boundingBox.origin.x,
                                          y: signal.boundingBox.origin.y,
                                          w: signal.boundingBox.width,
                                          h: signal.boundingBox.height,
                                          e: signal.embedding.base64EncodedString(),
                                          q: signal.quality,
                                          s: signal.hasSmile,
                                          d: signal.captureDate?.timeIntervalSince1970)
                    }
                }
                if entry != ShareSidecar.Entry() { entries[key] = entry }
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

    init(peopleEngine: PeopleEngine, autoAlbumEngine: AutoAlbumEngine) {
        self.peopleEngine = peopleEngine
        self.autoAlbumEngine = autoAlbumEngine
    }

    func currentMembers(for key: ShareSourceKey) async -> [String]? {
        switch key {
        case .group(let id):
            // 現存するグループだけ解決する（解除済みなら nil＝孤児セット）。
            guard peopleEngine.peopleGroups.contains(where: { $0.id == id }) else { return nil }
            return await peopleEngine.memberRefKeys(forGroup: id)
        case .person(let clusterID):
            guard peopleEngine.people.contains(where: { $0.clusterID == clusterID }) else { return nil }
            return await peopleEngine.memberRefKeys(forPerson: clusterID)
        case .album(let id):
            let all = autoAlbumEngine.albums + autoAlbumEngine.aiAlbums + autoAlbumEngine.pathAlbums
            guard let album = all.first(where: { $0.id == id }) else { return nil }
            return album.memberRefs
        }
    }
}

// MARK: - 受信側: サイドカーの取り込み

/// 家族の共有フォルダから解析サイドカーを取得し、受信側の各ストア
/// （タグ台帳・CLIP 埋め込み・顔）へ取り込む。取り込み済み写真は夜間の自前解析
/// （サムネ DL＋推論）がスキップされる。
@Observable
final class SharedAnalysisImporter {
    private let dropboxStore: DropboxPhotoStore
    private let autoAlbumEngine: AutoAlbumEngine
    private let peopleEngine: PeopleEngine
    private(set) var isRunning = false

    init(dropboxStore: DropboxPhotoStore, autoAlbumEngine: AutoAlbumEngine,
         peopleEngine: PeopleEngine) {
        self.dropboxStore = dropboxStore
        self.autoAlbumEngine = autoAlbumEngine
        self.peopleEngine = peopleEngine
    }

    /// 家族フォルダが設定されていれば、更新されたサイドカーを取得して取り込む。
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

        let fetched = await ShareSidecarFetch().fetchUpdated(roots: roots, token: token)
        guard !fetched.isEmpty else { return }

        let versions = ShareImportPlanning.ReceiverVersions(
            tag: AutoAlbumEngine.shareTagVersion,
            perception: AutoAlbumEngine.sharePerceptionVersion,
            face: peopleEngine.effectiveScanVersion)

        // ⚠️ ここから先は **すべてオフメイン**（規約: 巨大コレクションを MainActor に通さない）。
        // 受信側の突合は 6.8 万件規模の走査＋文字列生成、さらにサイドカーごとの base64 デコード
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
            // 索引は 1 回だけ作ってサイドカー間で使い回す。
            let index = ShareImportPlanning.index(of: localItems)
            let hashSet = Set(index.keys)

            return fetched.map { sidecar in
                let batch = ShareImportPlanning.plan(sidecar: sidecar.file, index: index,
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
                            captureDate: face.d.map { Date(timeIntervalSince1970: $0) })
                    }
                    if !signals.isEmpty { faces.append((refKey, signals)) }
                }
                // まだ同期されていない写真が残っているサイドカーは rev を記録しない
                // （次回の実行で残りを取り込む。取り込みは既存レコードをスキップするので冪等）。
                let fullyMatched = sidecar.file.entries.keys.allSatisfy { hashSet.contains($0) }
                return PreparedImport(sidecar: sidecar, tags: tags,
                                      embeddings: batch.embeddings, faces: faces,
                                      fullyMatched: fullyMatched)
            }
        }.value

        for prepared in prepared {
            let counts = await autoAlbumEngine.importSharedAnalysis(
                tags: prepared.tags, embeddings: prepared.embeddings)
            let faces = await peopleEngine.importFaceScans(prepared.faces)
            Diagnostics.mark("share import: \(prepared.sidecar.setFolderPathLower) — "
                + "tags \(counts.tags), embeddings \(counts.embeddings), faces \(faces.photos) photos")
            // ⚠️ 「取り込み済み」を記録するのは、**全部コミットできたとき**だけ。
            // 保存に失敗した回に記録すると、同じサイドカーは以後ダウンロードされず、
            // 欠けた解析結果を再取得できない（レビュー指摘）。
            // 未同期の写真が残っている場合（fullyMatched=false）も同様に記録しない。
            let committed = counts.saved && faces.saved
            if prepared.fullyMatched && committed {
                ShareSidecarFetch.markImported(prepared.sidecar)
            } else if !committed {
                Diagnostics.mark("share import: \(prepared.sidecar.setFolderPathLower) — "
                    + "not marked imported (persistence failed); will retry")
            }
        }
    }
}

/// オフメインで組み立てた取り込み材料（メインへはこれだけ返す）。
private struct PreparedImport: Sendable {
    let sidecar: ShareSidecarFetch.Fetched
    let tags: [(refKey: String, info: PhotoSenseInfo)]
    let embeddings: [(refKey: String, vectorHalf: Data)]
    let faces: [(refKey: String, faces: [DetectedFaceSignal])]
    /// サイドカーの全エントリが手元の写真に突合できたか（rev 記録の可否）。
    let fullyMatched: Bool
}

// MARK: - 共有の表示ポリシー（送信側の二重表示対策）

enum ShareVisibility {
    /// 自分の共有ルートを Cloud/All の表示から除外する（原本と共有コピーの重複表示を防ぐ）。
    /// ただしそのパスが「家族フォルダ」として登録されている場合は除外しない（受信側）。
    static func apply(to store: DropboxPhotoStore) {
        let root = ShareSettingsKeys.currentShareRoot().lowercased()
        let family = ShareSettingsKeys.currentFamilyFolders().map { $0.lowercased() }
        store.setExcludedPathPrefixes(family.contains(root) ? [] : [root])
    }
}

// MARK: - 共有セット作成シート

/// アルバム／人物から「家族と共有…」で開く作成シート。
struct ShareSetCreationSheet: View {
    let suggestedName: String
    let refKeys: [String]
    let shareEngine: ShareSyncEngine
    /// 作成元（グループ/人物/アルバム）。元カードの「クラウド共有中」バッジ表示に使う。
    var sourceKey: String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Set name"), text: $name)
                } footer: {
                    Text(String(format: L("%d photos will be copied into a folder with this name inside your shared folder. Originals and backups are not moved. AI analysis (tags, search index, faces) is included so receiving devices don't re-analyze them."), refKeys.count))
                }
            }
            .navigationTitle(L("Cloud Share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button(L("Share")) {
                            isCreating = true
                            Task {
                                await shareEngine.createSet(name: name, refKeys: refKeys,
                                                            sourceKey: sourceKey)
                                dismiss()
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { if name.isEmpty { name = suggestedName } }
        }
    }
}

// MARK: - クラウド共有の停止（共有元から）

/// 停止対象の共有セット。共有元（人物 / グループ / アルバム）のメニューから渡す。
struct StopSharingTarget: Identifiable {
    let setID: UUID
    let name: String
    var id: UUID { setID }
}

/// 「クラウド共有を停止」の確認ダイアログ。
///
/// 停止＝**共有フォルダごと削除**する。共有元（人物・アルバム）も、端末写真も、
/// バックアップも消えない——ここを取り違えると怖くて押せないので、文言で明示する。
/// 相手が既に保存した写真は取り消せない点も併せて伝える。
private struct StopSharingConfirmation: ViewModifier {
    @Binding var target: StopSharingTarget?
    let shareEngine: ShareSyncEngine?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L("Stop cloud sharing? The folder is removed from your shared area, so people you share with will no longer see these photos. Copies they already saved can't be removed. The album or person, your photos, and your backup are all kept."),
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible, presenting: target
        ) { item in
            Button(L("Stop Sharing"), role: .destructive) {
                guard let shareEngine else { return }
                // 停止はフォルダ削除の往復を伴う。UI は待たせず、完了は共有バッジが消えて伝わる。
                Task { await shareEngine.stopSharing(setID: item.setID) }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
}

extension View {
    func stopSharingConfirmation(_ target: Binding<StopSharingTarget?>,
                                 shareEngine: ShareSyncEngine?) -> some View {
        modifier(StopSharingConfirmation(target: target, shareEngine: shareEngine))
    }
}
