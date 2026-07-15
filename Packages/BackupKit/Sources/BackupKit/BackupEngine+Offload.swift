import DropboxCore
import Foundation
import Photos
import SwiftData

/// 本番の削除実行（PhotoKit）。`PHAssetChangeRequest.deleteAssets` は
/// **OS のシステム確認ダイアログが必ず表示され**、削除後も「最近削除した項目」に
/// 30 日間残る（復元可能）。アプリが黙って消すことは構造的にできない。
public struct PhotoKitDeleter: PhotoDeleter {
    public init() {}

    public func delete(localIdentifiers: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            // ユーザーがダイアログでキャンセルした場合もここに来る（＝削除されていない）。
            return false
        }
    }
}

// MARK: - BackupEngine のオフロード API（ADR-40）

extension BackupEngine {

    /// オフロード候補（バックアップ済み・端末に現存する写真）を古い順に列挙する。
    /// 実データ読み込みは遅延（`loadData` クロージャ・hash 再計算時のみ）。
    public func offloadCandidateAssets(scanLimit: Int = 200) -> [OffloadableAsset] {
        guard let context = modelContext,
              let records = try? context.fetch(FetchDescriptor<BackupAssetRecord>(
                  sortBy: [SortDescriptor(\.creationDate, order: .forward)])) else { return [] }
        var out: [OffloadableAsset] = []
        for record in records {
            if out.count >= scanLimit { break }
            guard let id = record.localIdentifier else { continue }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                .firstObject else { continue }   // 端末に無い（既にオフロード/削除済み）
            out.append(OffloadableAsset(
                localIdentifier: id,
                dropboxPath: record.dropboxPath,
                filename: record.filename,
                albums: record.albums,
                captureDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                backedUpAt: record.backedUpAt,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                loadData: { [id, filename = record.filename] in
                    // PHAsset は Sendable でないため、クロージャ内で ID から取り直す。
                    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                        .firstObject else { return nil }
                    if case .success(let data, _) = await BackupAssetReader.read(asset: asset,
                                                                                 fallback: filename) {
                        return data
                    }
                    return nil
                }))
        }
        return out
    }

    /// オフロードのドライラン：候補を検証して削除可否と理由の一覧を返す。**何も削除しない**。
    public func planOffload(limit: Int) async -> OffloadPlan {
        let service = makeOffloadService()
        return await service.plan(assets: offloadCandidateAssets(), limit: limit)
    }

    /// オフロードの実行（多層防御・ADR-40）：直前再検証 → 台帳記録 → PhotoKit 削除
    /// （OS 確認ダイアログ）→ metadata マーカー。キャンセル時は台帳をロールバック。
    /// 呼び出し側（UI）は Developer Options のゲートを確認してから呼ぶこと。
    public func executeOffload(limit: Int) async -> (deleted: [String], skipped: [(String, String)]) {
        let service = makeOffloadService()
        let result = await service.execute(
            assets: offloadCandidateAssets(), limit: limit,
            recordLedger: { [weak self] items in self?.recordOffloads(items) },
            rollbackLedger: { [weak self] ids in self?.removeOffloads(localIdentifiers: ids) })
        if !result.deleted.isEmpty {
            addLog("Offload: deleted \(result.deleted.count) photo(s) (verified, ledger recorded)")
        }
        return result
    }

    private func makeOffloadService(deleter: PhotoDeleter = PhotoKitDeleter()) -> OffloadService {
        OffloadService(uploader: uploader, tokenProvider: tokenProvider,
                       deleter: deleter, log: { [weak self] in self?.addLog($0) })
    }
}
