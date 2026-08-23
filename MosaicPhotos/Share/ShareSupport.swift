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

        // 受信側の同期済みアイテム（家族フォルダ配下・content_hash 付き）。
        let rootsLower = roots.map { $0.lowercased() }
        let localItems: [ShareImportPlanning.LocalItem] = dropboxStore.items.compactMap { item in
            guard let hash = item.contentHash else { return nil }
            let lower = item.path.lowercased()
            guard rootsLower.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") })
            else { return nil }
            return ShareImportPlanning.LocalItem(refKey: PhotoRef.cloud(item.path).encoded,
                                                 contentHash: hash)
        }
        let hashSet = Set(localItems.map { $0.contentHash.lowercased() })

        let versions = ShareImportPlanning.ReceiverVersions(
            tag: AutoAlbumEngine.shareTagVersion,
            perception: AutoAlbumEngine.sharePerceptionVersion,
            face: peopleEngine.effectiveScanVersion)

        for sidecar in fetched {
            let batch = ShareImportPlanning.plan(sidecar: sidecar.file,
                                                localItems: localItems, versions: versions)
            let tagBatch = batch.tags.map {
                (refKey: $0.refKey,
                 info: PhotoSenseInfo(tags: $0.entry.tags ?? [], ocrText: $0.entry.ocr,
                                      humanCount: $0.entry.human, aesthetic: $0.entry.aes))
            }
            let counts = await autoAlbumEngine.importSharedAnalysis(
                tags: tagBatch, embeddings: batch.embeddings)
            var faceBatch: [(refKey: String, faces: [DetectedFaceSignal])] = []
            for (refKey, faces) in batch.faces {
                let signals = faces.compactMap { face -> DetectedFaceSignal? in
                    guard let embedding = Data(base64Encoded: face.e) else { return nil }
                    return DetectedFaceSignal(
                        boundingBox: CGRect(x: face.x, y: face.y, width: face.w, height: face.h),
                        embedding: embedding, quality: face.q, hasSmile: face.s,
                        captureDate: face.d.map { Date(timeIntervalSince1970: $0) })
                }
                if !signals.isEmpty { faceBatch.append((refKey, signals)) }
            }
            let importedFaces = await peopleEngine.importFaceScans(faceBatch)
            Diagnostics.mark("share import: \(sidecar.setFolderPathLower) — "
                + "tags \(counts.tags), embeddings \(counts.embeddings), faces \(importedFaces) photos")

            // まだ同期されていない写真が残っているサイドカーは rev を記録しない
            // （次回の実行で残りを取り込む。取り込みは既存レコードをスキップするので冪等）。
            let matched = sidecar.file.entries.keys.filter { hashSet.contains($0) }.count
            if matched == sidecar.file.entries.count {
                ShareSidecarFetch.markImported(sidecar)
            }
        }
    }
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
