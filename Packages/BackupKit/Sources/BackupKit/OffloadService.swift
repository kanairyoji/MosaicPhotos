import DropboxCore
import Foundation
import MosaicSupport

// MARK: - Seams（テストで差し替える境界）

/// 端末写真の削除実行の seam（ADR-40・層 2 テストの要）。
/// 本番＝`PhotoKitDeleter`（PHAssetChangeRequest.deleteAssets ＝ OS の確認ダイアログが必ず出て、
/// 削除後 30 日間は「最近削除した項目」から復元可能）。テスト＝呼び出し記録のみのモック。
public protocol PhotoDeleter: Sendable {
    /// 削除を要求する。戻り値: 実際に削除されたか（ユーザーがダイアログでキャンセル→ false）。
    func delete(localIdentifiers: [String]) async -> Bool
}

/// オフロード候補（バックアップ済み写真）の現在の実体。アプリが PHAsset から組み立てて渡す
///（BackupKit のロジックを PhotoKit から切り離し、macOS でテスト可能に保つ）。
public struct OffloadableAsset: Sendable {
    public let localIdentifier: String
    public let dropboxPath: String          // 記録上のバックアップ先（小文字正規化済み）
    public let filename: String
    public let albums: [String]             // 現在の所属アルバム名
    public let captureDate: Date?
    public let modificationDate: Date?      // PHAsset.modificationDate（編集検知）
    public let backedUpAt: Date?            // BackupAssetRecord.backedUpAt
    public let isLivePhoto: Bool
    /// 写真の現データ（hash 再計算用）。取得不可（iCloud のみ等）は nil。
    public let loadData: @Sendable () async -> Data?

    public init(localIdentifier: String, dropboxPath: String, filename: String,
                albums: [String], captureDate: Date?, modificationDate: Date?,
                backedUpAt: Date?, isLivePhoto: Bool,
                loadData: @escaping @Sendable () async -> Data?) {
        self.localIdentifier = localIdentifier
        self.dropboxPath = dropboxPath
        self.filename = filename
        self.albums = albums
        self.captureDate = captureDate
        self.modificationDate = modificationDate
        self.backedUpAt = backedUpAt
        self.isLivePhoto = isLivePhoto
        self.loadData = loadData
    }
}

// MARK: - 判定（純ロジック・層 1 テスト対象）

/// オフロード可否の判定結果。skip の理由を必ず言語化する（ドライラン一覧・診断ログに出す）。
public enum OffloadVerdict: Equatable, Sendable {
    case eligible
    case skip(reason: String)
}

enum OffloadPlanning {

    /// 削除してよいかの**決定的判定**（ADR-40「削除は証明の後」）。
    /// すべての条件はここに集約する（サービス側に条件分岐を散らさない）。
    /// - Parameters:
    ///   - localHash: 端末の現データから**今**計算した content_hash（nil = データ取得不可）
    ///   - remote: Dropbox の get_metadata で**今**取得した実体情報（nil = クラウドに存在しない）
    static func verdict(asset: OffloadableAsset, localHash: String?, localSize: Int?,
                        remote: RemoteFileInfo?) -> OffloadVerdict {
        if asset.isLivePhoto {
            // Live Photo は動画部分をバックアップしていない＝消すと動画が失われる。
            return .skip(reason: "Live Photo (video part is not backed up)")
        }
        if let modified = asset.modificationDate, let backedUp = asset.backedUpAt,
           modified > backedUp {
            // バックアップ後に編集された＝消すと編集が失われる。再バックアップ後に候補へ戻る。
            return .skip(reason: "edited after backup")
        }
        guard let localHash, let localSize else {
            return .skip(reason: "could not read photo data (iCloud-only?)")
        }
        guard let remote else {
            return .skip(reason: "not found on Dropbox")
        }
        guard remote.contentHash == localHash else {
            return .skip(reason: "content hash mismatch (cloud copy differs from device)")
        }
        if let size = remote.size, size != localSize {
            return .skip(reason: "size mismatch (cloud \(size) vs device \(localSize) bytes)")
        }
        return .eligible
    }
}

// MARK: - ドライラン結果（UI 表示用）

public struct OffloadPlanItem: Identifiable, Sendable {
    public var id: String { localIdentifier }
    public let localIdentifier: String
    public let filename: String
    public let dropboxPath: String
    public let captureDate: Date?
    public let verdict: OffloadVerdict
    public var isEligible: Bool { verdict == .eligible }
    public var skipReason: String? {
        if case .skip(let reason) = verdict { return reason }
        return nil
    }
}

public struct OffloadPlan: Sendable {
    public let items: [OffloadPlanItem]
    public var eligible: [OffloadPlanItem] { items.filter(\.isEligible) }
    public var skipped: [OffloadPlanItem] { items.filter { !$0.isEligible } }
}

// MARK: - Service（検証 → 台帳 → 削除 → マーカー）

/// オフロードの実行ユニット（ADR-40）。多層防御：
/// 1. **その場での実体検証** — 端末データの hash 再計算 × Dropbox get_metadata の完全一致
/// 2. **記録が先、削除が後** — 台帳（OffloadRecord）へ書いてから削除。キャンセルでロールバック
/// 3. **削除は PhotoKit 経由** — OS の確認ダイアログ必須＋「最近削除した項目」に 30 日残る
/// 4. **上限つき**・ドライラン既定
@MainActor
public final class OffloadService {

    private let uploader: DropboxBackupUploader
    private let tokenProvider: AccessTokenProvider
    private let deleter: PhotoDeleter
    private let log: @MainActor (String) -> Void

    init(uploader: DropboxBackupUploader, tokenProvider: AccessTokenProvider,
         deleter: PhotoDeleter, log: @escaping @MainActor (String) -> Void) {
        self.uploader = uploader
        self.tokenProvider = tokenProvider
        self.deleter = deleter
        self.log = log
    }

    /// ドライラン：候補ごとに検証を実行し、削除可否と理由の一覧を返す。**何も削除しない**。
    public func plan(assets: [OffloadableAsset], limit: Int) async -> OffloadPlan {
        guard let token = try? await tokenProvider.freshAccessToken() else {
            log("offload.plan: authentication failed")
            return OffloadPlan(items: [])
        }
        var items: [OffloadPlanItem] = []
        var eligibleCount = 0
        for asset in assets {
            if eligibleCount >= limit { break }
            let data = await asset.loadData()
            let localHash = data.map { DropboxContentHash.hash(of: $0) }
            let remote = await uploader.getMetadata(path: asset.dropboxPath, token: token)
            let verdict = OffloadPlanning.verdict(asset: asset, localHash: localHash,
                                                  localSize: data?.count, remote: remote)
            if verdict == .eligible { eligibleCount += 1 }
            items.append(OffloadPlanItem(localIdentifier: asset.localIdentifier,
                                         filename: asset.filename,
                                         dropboxPath: asset.dropboxPath,
                                         captureDate: asset.captureDate,
                                         verdict: verdict))
            log("offload.plan: \(asset.filename) → \(verdict)")
        }
        return OffloadPlan(items: items)
    }

    /// 実削除：**直前にもう一度検証**し、台帳へ記録してから削除する。
    /// 戻り値: (削除した localIdentifier, スキップ理由一覧)。
    /// - `recordLedger`: 台帳書き込み（BackupEngine.recordOffloads）。削除より先に呼ぶ。
    /// - `rollbackLedger`: 削除キャンセル/失敗時の台帳ロールバック（removeOffloads）。
    public func execute(assets: [OffloadableAsset], limit: Int,
                        recordLedger: ([(localIdentifier: String, dropboxPath: String,
                                        albums: [String], captureDate: Date?,
                                        contentHash: String?)]) async -> Void,
                        rollbackLedger: ([String]) async -> Void) async -> (deleted: [String], skipped: [(String, String)]) {
        guard let token = try? await tokenProvider.freshAccessToken() else {
            log("offload.execute: authentication failed")
            return ([], [])
        }
        // 1. 直前の再検証（plan とダイアログの間に写真が編集された等のズレを排除する）。
        var verified: [(asset: OffloadableAsset, hash: String)] = []
        var skipped: [(String, String)] = []
        for asset in assets {
            if verified.count >= limit { break }
            let data = await asset.loadData()
            let localHash = data.map { DropboxContentHash.hash(of: $0) }
            let remote = await uploader.getMetadata(path: asset.dropboxPath, token: token)
            switch OffloadPlanning.verdict(asset: asset, localHash: localHash,
                                           localSize: data?.count, remote: remote) {
            case .eligible:
                verified.append((asset, localHash ?? ""))
            case .skip(let reason):
                skipped.append((asset.filename, reason))
                log("offload.execute: skip \(asset.filename) — \(reason)")
            }
        }
        guard !verified.isEmpty else { return ([], skipped) }

        // 2. 記録が先（台帳）。削除がキャンセル/失敗したらロールバックする。
        let ledgerItems = verified.map { v in
            (localIdentifier: v.asset.localIdentifier, dropboxPath: v.asset.dropboxPath,
             albums: v.asset.albums, captureDate: v.asset.captureDate,
             contentHash: Optional(v.hash))
        }
        await recordLedger(ledgerItems)   // 記録の完了を待ってから削除する（不変条件）

        // 3. 削除（PhotoKit＝OS 確認ダイアログ・「最近削除した項目」へ）。
        let ids = verified.map(\.asset.localIdentifier)
        let deleted = await deleter.delete(localIdentifiers: ids)
        guard deleted else {
            log("offload.execute: deletion cancelled — rolling back ledger (\(ids.count))")
            await rollbackLedger(ids)
            return ([], skipped)
        }
        log("offload.execute: deleted \(ids.count) photo(s), verified hashes, ledger recorded")

        // 4. metadata v2 へ offloadedAt / verifiedAt マーカーを書く（再インストール時の台帳再構築用）。
        //    失敗しても台帳（端末）が正なので致命的ではない。次回実行で再試行される。
        await uploadOffloadMarkers(for: verified.map(\.asset), token: token)
        return (ids, skipped)
    }

    /// 触った撮影月シャードに offloadedAt / verifiedAt を書き込む。
    private func uploadOffloadMarkers(for assets: [OffloadableAsset], token: String) async {
        // シャード（撮影月）ごとにまとめて、既存エントリへマーカーだけ足して書き戻す。
        let folderByPath: (String) -> String? = { path in
            // "/Folder/name.jpg" → "/Folder"（バックアップフォルダ直下前提）
            guard let idx = path.lastIndex(of: "/") else { return nil }
            return String(path[..<idx])
        }
        let now = ISO8601DateFormatter().string(from: Date())
        var byShard: [String: [OffloadableAsset]] = [:]
        for asset in assets {
            byShard[BackupMetadataV2.shardName(for: asset.captureDate), default: []].append(asset)
        }
        for (shard, shardAssets) in byShard {
            guard let folder = folderByPath(shardAssets[0].dropboxPath) else { continue }
            let shardPath = folder + BackupMetadataV2.shardSuffix(shard)
            let existing = await uploader.download(path: shardPath, token: token)
            var metadata = existing.flatMap { try? JSONDecoder().decode(DropboxBackupMetadata.self, from: $0) }
                ?? DropboxBackupMetadata()
            for asset in shardAssets {
                var entry = metadata.entries[asset.dropboxPath]
                    ?? DropboxBackupMetadata.Entry(people: [], albums: asset.albums,
                                                   localIdentifier: asset.localIdentifier)
                entry.offloadedAt = now
                entry.verifiedAt = now
                metadata.entries[asset.dropboxPath] = entry
            }
            let result = await uploader.uploadJSON(metadata, to: shardPath, token: token)
            log("offload.marker: meta/\(shard).json (\(shardAssets.count) marker(s)): \(result)")
        }
    }
}
