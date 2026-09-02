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
/// マーカー書き込みに必要な最小情報。**削除済みの写真にも作れる**ことが要点
/// （`OffloadableAsset` は PHAsset 由来なので、消えた写真からは作れない）。
public struct OffloadMarkerTarget: Sendable {
    public let localIdentifier: String
    public let dropboxPath: String
    public let albums: [String]
    public let captureDate: Date?

    public init(localIdentifier: String, dropboxPath: String, albums: [String],
                captureDate: Date?) {
        self.localIdentifier = localIdentifier
        self.dropboxPath = dropboxPath
        self.albums = albums
        self.captureDate = captureDate
    }

    init(_ asset: OffloadableAsset) {
        self.init(localIdentifier: asset.localIdentifier, dropboxPath: asset.dropboxPath,
                  albums: asset.albums, captureDate: asset.captureDate)
    }
}

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
    ///
    /// ⚠️ 「削除によって失われるもの」を読むこと（ADR-168）。編集済みの写真では
    /// **編集結果**（`.fullSizePhoto`）を読み、`isEditedRendition` でそれを伝える。
    /// 原画を読んでしまうと、クラウド上の原画と hash が一致して適格になり、
    /// 編集結果を保全しないまま削除する。
    public let loadData: @Sendable () async -> (data: Data, isEditedRendition: Bool)?

    public init(localIdentifier: String, dropboxPath: String, filename: String,
                albums: [String], captureDate: Date?, modificationDate: Date?,
                backedUpAt: Date?, isLivePhoto: Bool,
                loadData: @escaping @Sendable () async -> (data: Data, isEditedRendition: Bool)?) {
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

    /// 台帳の走査結果（候補一覧・適格数・構造的に不適格だった数）。
    struct CandidateScan {
        var candidates: [OffloadableAsset] = []
        var usable = 0
        var skippedStructural = 0
    }

    /// 台帳（撮影日昇順）から候補を選ぶ。
    ///
    /// ⚠️ 上限（`scanLimit`）は**構造的に不適格なものを除いた数**で数え、走査自体は
    /// 台帳の最後まで進む。出力の件数で打ち切ると、古い順の先頭が Live Photo・編集済みで
    /// 埋まっている場合に**その先へ永久に到達できない**（＝何度実行してもオフロードされない）。
    /// 不適格分は一覧表示のために `maxIneligibleShown` 件だけ持つ（メモリの保険）。
    static func scanCandidates<Record>(records: [Record], scanLimit: Int,
                                       maxIneligibleShown: Int = 50,
                                       makeCandidate: (Record) -> OffloadableAsset?) -> CandidateScan {
        var scan = CandidateScan()
        for record in records {
            if scan.usable >= scanLimit { break }
            guard let candidate = makeCandidate(record) else { continue }
            if isStructurallyIneligible(candidate) {
                scan.skippedStructural += 1
                if scan.skippedStructural <= maxIneligibleShown { scan.candidates.append(candidate) }
                continue
            }
            scan.usable += 1
            scan.candidates.append(candidate)
        }
        return scan
    }

    /// 削除してよいかの**決定的判定**（ADR-40「削除は証明の後」）。
    /// すべての条件はここに集約する（サービス側に条件分岐を散らさない）。
    /// - Parameters:
    ///   - localHash: 端末の現データから**今**計算した content_hash（nil = データ取得不可）
    ///   - remote: Dropbox の get_metadata で**今**取得した実体情報（nil = クラウドに存在しない）
    /// 通信もデータ読み込みも要らない**構造的な**不適格判定（候補列挙のふるいに使う）。
    ///
    /// ⚠️ 候補列挙を上限で打ち切る前にこれを通す。通さないと、古い順の先頭が Live Photo や
    /// 編集済みで埋まっている場合、**その先の適格な写真が永久に検査されない**（レビュー指摘）。
    static func isStructurallyIneligible(_ asset: OffloadableAsset) -> Bool {
        if asset.isLivePhoto { return true }
        if let modified = asset.modificationDate, let backedUp = asset.backedUpAt,
           modified > backedUp { return true }
        return false
    }

    /// - Parameter isEditedRendition: 端末側で読んだのが**編集結果**か（`loadData` の報告）。
    ///   hash 不一致の理由を「クラウドには編集前の原画しか無い」と言い分けるために使う。
    static func verdict(asset: OffloadableAsset, localHash: String?, localSize: Int?,
                        remote: RemoteFileInfo?,
                        isEditedRendition: Bool = false) -> OffloadVerdict {
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
            if isEditedRendition {
                // この修正より前に上げた編集済み写真＝クラウド側は原画のまま。削除すると
                // 編集結果が失われるので、再バックアップされるまで永久に不適格でよい。
                return .skip(reason: "edited version is not backed up "
                             + "(cloud copy is the unedited original)")
            }
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
            let loaded = await asset.loadData()
            let localHash = loaded.map { DropboxContentHash.hash(of: $0.data) }
            let remote = await uploader.getMetadata(path: asset.dropboxPath, token: token)
            let verdict = OffloadPlanning.verdict(asset: asset, localHash: localHash,
                                                  localSize: loaded?.data.count, remote: remote,
                                                  isEditedRendition: loaded?.isEditedRendition ?? false)
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
    ///   **永続化できたかを返すこと**——false なら削除しない（記録の無い削除を作らない）。
    /// - `rollbackLedger`: 削除キャンセル/失敗時の台帳ロールバック（removeOffloads）。
    public func execute(assets: [OffloadableAsset], limit: Int,
                        recordLedger: ([(localIdentifier: String, dropboxPath: String,
                                        albums: [String], captureDate: Date?,
                                        contentHash: String?)]) async -> Bool,
                        rollbackLedger: ([String]) async -> Void,
                        markMarkersUploaded: ([String]) async -> Void = { _ in }) async
                        -> (deleted: [String], skipped: [(String, String)]) {
        guard let token = try? await tokenProvider.freshAccessToken() else {
            log("offload.execute: authentication failed")
            return ([], [])
        }
        // 1. 直前の再検証（plan とダイアログの間に写真が編集された等のズレを排除する）。
        var verified: [(asset: OffloadableAsset, hash: String)] = []
        var skipped: [(String, String)] = []
        for asset in assets {
            if verified.count >= limit { break }
            let loaded = await asset.loadData()
            let localHash = loaded.map { DropboxContentHash.hash(of: $0.data) }
            let remote = await uploader.getMetadata(path: asset.dropboxPath, token: token)
            switch OffloadPlanning.verdict(asset: asset, localHash: localHash,
                                           localSize: loaded?.data.count, remote: remote,
                                           isEditedRendition: loaded?.isEditedRendition ?? false) {
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
        // 記録の**永続化を確認**してから削除する（不変条件）。容量不足・SwiftData 障害で
        // 保存に失敗したまま消すと、クラウドにしか無い写真が台帳から漏れて追跡不能になる。
        guard await recordLedger(ledgerItems) else {
            log("offload.execute: ledger write failed — aborting deletion (\(ledgerItems.count))")
            // 部分的に書けている可能性があるので、この回の分は台帳から戻す。
            await rollbackLedger(ledgerItems.map(\.localIdentifier))
            let reason = "ledger write failed"
            return ([], skipped + verified.map { ($0.asset.filename, reason) })
        }

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
        //    書けた分だけ台帳に印を付ける。書けなかった分は「未送信」として残り、
        //    `retryPendingMarkers` が後から再送する（写真はもう PHAsset には現れないため、
        //    次回のオフロード実行任せにはできない・レビュー指摘）。
        let written = await uploadOffloadMarkers(
            for: verified.map { OffloadMarkerTarget($0.asset) }, token: token)
        await markMarkersUploaded(written)
        return (ids, skipped)
    }

    /// 触った撮影月シャードに offloadedAt / verifiedAt を書き込む
    /// （download→merge→upload は `MetadataShardWriter` に集約＝B3）。
    /// - Returns: **書き込めた** localIdentifier（呼び出し側が台帳へ印を付ける）。
    ///   書けなかった分は台帳に「未送信」として残り、後から再送される。
    @discardableResult
    public func uploadOffloadMarkers(for targets: [OffloadMarkerTarget],
                                     token: String) async -> [String] {
        let folderByPath: (String) -> String? = { path in
            // "/Folder/name.jpg" → "/Folder"（バックアップフォルダ直下前提）
            guard let idx = path.lastIndex(of: "/") else { return nil }
            return String(path[..<idx])
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let writer = MetadataShardWriter(uploader: uploader, token: token)
        // ⚠️ **フォルダとシャードの組**で束ねる。撮影月だけで束ねて先頭要素の親フォルダへ
        // まとめて書くと、旧レイアウトと端末フォルダ、あるいは保存先変更の前後の写真が
        // 同じ月に混ざったとき、**別フォルダのエントリまで最初のシャードへ書かれ**、
        // しかも全件を送信済み扱いにしてしまう（レビュー指摘）。
        var byFolderShard: [String: (folder: String, shard: String, targets: [OffloadMarkerTarget])] = [:]
        for target in targets {
            guard let folder = folderByPath(target.dropboxPath) else { continue }
            let shard = BackupMetadataV2.shardName(for: target.captureDate)
            let key = "\(folder.lowercased())|\(shard)"
            byFolderShard[key, default: (folder, shard, [])].targets.append(target)
        }
        var written: [String] = []
        for (_, group) in byFolderShard {
            let folder = group.folder
            let shard = group.shard
            let shardTargets = group.targets
            let byPath = Dictionary(shardTargets.map { ($0.dropboxPath, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let ok = await writer.updateEntries(
                paths: shardTargets.map(\.dropboxPath), folder: folder, shardName: shard,
                mutate: { entry in
                    entry.offloadedAt = now
                    entry.verifiedAt = now
                },
                makeDefault: { path in
                    DropboxBackupMetadata.Entry(people: [], albums: byPath[path]?.albums ?? [],
                                                localIdentifier: byPath[path]?.localIdentifier)
                },
                log: { line in self.log(line) })
            if ok { written.append(contentsOf: shardTargets.map(\.localIdentifier)) }
        }
        return written
    }
}
