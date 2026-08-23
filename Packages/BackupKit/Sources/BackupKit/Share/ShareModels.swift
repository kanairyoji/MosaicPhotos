import Foundation
import SwiftData

/// 共有セット（＝共有フォルダ内のサブフォルダ 1 つ）。
/// 「共有はバックアップの射影」——実体はバックアップ（またはクラウド原本）からの
/// サーバーサイドコピーで、セット削除は共有側のフォルダ削除のみ（正本は無傷）。
@Model
public final class ShareSet {
    @Attribute(.unique) public var id: UUID
    /// 表示名（ユーザー入力そのまま）。
    public var name: String
    /// 実フォルダ名（`ShareNaming.sanitize` 済み・共有ルート直下）。
    public var folderName: String
    public var createdAt: Date
    /// 最後にアップロードしたサイドカーのチェックサム（変化がなければ再アップロードを省く）。
    public var sidecarChecksum: String?
    /// 作成元（"pgroup-<uuid>" / "person-<clusterID>" / "album-<id>"）。
    /// 元のカードに「クラウド共有中」バッジを出すための参照。手動作成は nil。
    public var sourceKey: String?

    public init(id: UUID = UUID(), name: String, folderName: String,
                createdAt: Date = Date(), sidecarChecksum: String? = nil,
                sourceKey: String? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.createdAt = createdAt
        self.sidecarChecksum = sidecarChecksum
        self.sourceKey = sourceKey
    }
}

/// 共有セットの 1 メンバー（写真 1 枚）。
@Model
public final class ShareItem {
    public var setID: UUID
    /// 写真の統一キー（"L-<localIdentifier>" / "C-<Dropbox パス>"）。
    public var refKey: String
    /// コピー元パス（解決済みのとき。L- はバックアップ実体・C- は原本パス）。
    public var sourcePath: String?
    /// コピー結果の実パス（autorename 後・小文字正規化）。
    public var sharedPath: String?
    /// コピー時点の content_hash（解析サイドカーの結合キー・ドリフト検知）。
    public var sharedContentHash: String?
    /// ShareItemState の rawValue。
    public var stateRaw: String
    public var addedAt: Date
    public var copiedAt: Date?

    public init(setID: UUID, refKey: String, stateRaw: String = ShareItemState.pending.rawValue,
                addedAt: Date = Date()) {
        self.setID = setID
        self.refKey = refKey
        self.stateRaw = stateRaw
        self.addedAt = addedAt
    }
}

/// 共有アイテムの状態。
public enum ShareItemState: String, Sendable {
    /// 未反映（次回同期でコピーする）。
    case pending
    /// ローカル写真がまだバックアップされていない（バックアップ完了後に自動反映）。
    case waitingBackup
    /// 共有フォルダへコピー済み。
    case copied
    /// コピー失敗（次回同期で再試行）。
    case failed
}

// MARK: - Sendable 値（actor 境界の外へ @Model を漏らさない・プロジェクト規約）

public struct ShareSetLite: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let folderName: String
    public let createdAt: Date
    public let sidecarChecksum: String?
    public let sourceKey: String?

    public init(id: UUID, name: String, folderName: String, createdAt: Date,
                sidecarChecksum: String?, sourceKey: String? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.createdAt = createdAt
        self.sidecarChecksum = sidecarChecksum
        self.sourceKey = sourceKey
    }
}

public struct ShareItemLite: Sendable, Equatable {
    public let refKey: String
    public let sourcePath: String?
    public let sharedPath: String?
    public let sharedContentHash: String?
    public let state: ShareItemState
    public let addedAt: Date

    public init(refKey: String, sourcePath: String?, sharedPath: String?,
                sharedContentHash: String?, state: ShareItemState, addedAt: Date) {
        self.refKey = refKey
        self.sourcePath = sourcePath
        self.sharedPath = sharedPath
        self.sharedContentHash = sharedContentHash
        self.state = state
        self.addedAt = addedAt
    }
}
