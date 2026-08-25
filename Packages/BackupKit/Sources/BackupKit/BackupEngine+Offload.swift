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
    /// 記録は store actor（オフメイン）から取得し、PHAsset は **1 回の一括フェッチ**で解決する
    /// （旧: 記録ごとに fetchAssets を呼びメインを塞いでいた）。
    /// 実データ読み込みは遅延（`loadData` クロージャ・hash 再計算時のみ）。
    ///
    /// ⚠️ 上限（`scanLimit`）は**構造的に不適格なものを除いた数**で数える。単純に先頭 N 件で
    /// 打ち切ると、古い順の先頭が Live Photo・編集済みで埋まっている場合に、その先の適格な
    /// 写真が plan/execute のどちらにも渡らず、**何度実行してもオフロードされない**
    /// （レビュー指摘）。台帳は撮影日昇順なので、そのまま奥へ走査すればよい。
    public func offloadCandidateAssets(scanLimit: Int = 200) async -> [OffloadableAsset] {
        let records = await store().allRecordsLite()
        let ids = records.compactMap(\.localIdentifier)
        guard !ids.isEmpty else { return [] }
        // PHAsset を一括フェッチして辞書化（存在しない ID＝既にオフロード/削除済みは落ちる）。
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assetByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assetByID[asset.localIdentifier] = asset }

        var out: [OffloadableAsset] = []
        var usable = 0            // 構造的に不適格でない候補の数（上限はこちらで数える）
        var skippedStructural = 0
        // 台帳全体が不適格なときに無限に積まないための保険（打ち切りはログに残す）。
        let maxScanned = scanLimit * 10
        for record in records {
            if usable >= scanLimit || out.count >= maxScanned { break }
            guard let id = record.localIdentifier, let asset = assetByID[id] else { continue }
            let candidate = OffloadableAsset(
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
                })
            // ⚠️ 構造的に不適格（Live Photo・編集済み）なものは**上限に数えない**。
            // 数えると、古い順の先頭がそれで埋まったときに奥へ進めなくなる。
            // 一覧（ドライラン）にはスキップ理由を出したいので、候補自体は含める。
            if OffloadPlanning.isStructurallyIneligible(candidate) {
                skippedStructural += 1
                out.append(candidate)   // 一覧にはスキップ理由つきで出す
                continue
            }
            usable += 1
            out.append(candidate)
        }
        if skippedStructural > 0 {
            addLog("Offload: scanned past \(skippedStructural) structurally ineligible photo(s) "
                   + "(usable=\(usable))")
        }
        if out.count >= maxScanned {
            addLog("Offload: stopped scanning at \(maxScanned) record(s) — usable=\(usable)")
        }
        return out
    }

    /// オフロードのドライラン：候補を検証して削除可否と理由の一覧を返す。**何も削除しない**。
    public func planOffload(limit: Int) async -> OffloadPlan {
        let service = makeOffloadService()
        return await service.plan(assets: await offloadCandidateAssets(), limit: limit)
    }

    /// オフロードの実行（多層防御・ADR-40）：直前再検証 → 台帳記録 → PhotoKit 削除
    /// （OS 確認ダイアログ）→ metadata マーカー。キャンセル時は台帳をロールバック。
    /// 呼び出し側（UI）は Developer Options のゲートを確認してから呼ぶこと。
    public func executeOffload(limit: Int) async -> (deleted: [String], skipped: [(String, String)]) {
        // 前回書けなかったマーカーを先に片付ける（対象の写真はもう端末に無いので、
        // 候補走査には現れない＝ここで面倒を見ないと永久に未送信のまま）。
        await retryPendingOffloadMarkers()

        let service = makeOffloadService()
        let result = await service.execute(
            assets: await offloadCandidateAssets(), limit: limit,
            // self が消えていたら記録できていない＝削除させない（false）。
            recordLedger: { [weak self] items in await self?.recordOffloads(items) ?? false },
            rollbackLedger: { [weak self] ids in await self?.removeOffloads(localIdentifiers: ids) },
            markMarkersUploaded: { [weak self] ids in
                await self?.store().markOffloadMarkersUploaded(localIdentifiers: ids)
            })
        if !result.deleted.isEmpty {
            addLog("Offload: deleted \(result.deleted.count) photo(s) (verified, ledger recorded)")
        }
        return result
    }

    /// 未送信の offloadedAt マーカーを再送する。
    ///
    /// マーカーは**再インストール後に台帳を建て直す唯一の手掛かり**。書けないまま放置すると、
    /// その写真はクラウドにあるのに「オフロードした写真」として復元できなくなる。
    /// 対象の写真は既に端末から消えていて候補走査に現れないため、台帳を出典に再送する。
    /// バックアップ完走時とオフロード実行前に呼ぶ（通信できる文脈）。
    @discardableResult
    public func retryPendingOffloadMarkers() async -> Int {
        let pending = await store().offloadsPendingMarker()
        guard !pending.isEmpty else { return 0 }
        guard let token = try? await tokenProvider.freshAccessToken() else { return 0 }
        let targets = pending.map {
            OffloadMarkerTarget(localIdentifier: $0.localIdentifier, dropboxPath: $0.dropboxPath,
                                albums: $0.albums, captureDate: $0.captureDate)
        }
        let written = await makeOffloadService().uploadOffloadMarkers(for: targets, token: token)
        await store().markOffloadMarkersUploaded(localIdentifiers: written)
        if !written.isEmpty {
            addLog("Offload: re-sent \(written.count) pending marker(s)")
        }
        return written.count
    }

    private func makeOffloadService(deleter: PhotoDeleter = PhotoKitDeleter()) -> OffloadService {
        OffloadService(uploader: uploader, tokenProvider: tokenProvider,
                       deleter: deleter, log: { [weak self] in self?.addLog($0) })
    }
}
