import Foundation
import SwiftData

/// 共有セットの**作成元**（どのカードから作られたか）。
///
/// 文字列プロトコル（`"album-…"` 等）の符号化/復号を 1 か所に閉じる。以前は生成側 3 ファイル・
/// 復号側 1 ファイルに素のリテラルと `dropFirst(7)` が散らばっており、画面ルーティング用の
/// `HomeDestination.id` が**同じ接頭辞を別の意味で**使っていて紛らわしかった（規約: 文字列
/// リテラルを読み手・書き手に重複させない）。
public enum ShareSourceKey: Equatable, Sendable {
    case album(String)
    case person(Int)
    case group(UUID)

    private static let albumPrefix = "album-"
    private static let personPrefix = "person-"
    private static let groupPrefix = "pgroup-"

    public var encoded: String {
        switch self {
        case .album(let id):  return Self.albumPrefix + id
        case .person(let id): return Self.personPrefix + String(id)
        case .group(let id):  return Self.groupPrefix + id.uuidString
        }
    }

    /// 種類（album / person / group）。**同名でも種類が違えば別物**として扱うために使う。
    public enum Kind: String, Sendable { case album, person, group }

    public var kind: Kind {
        switch self {
        case .album:  return .album
        case .person: return .person
        case .group:  return .group
        }
    }

    public init?(_ raw: String) {
        if raw.hasPrefix(Self.groupPrefix) {
            guard let uuid = UUID(uuidString: String(raw.dropFirst(Self.groupPrefix.count))) else { return nil }
            self = .group(uuid)
        } else if raw.hasPrefix(Self.personPrefix) {
            guard let id = Int(raw.dropFirst(Self.personPrefix.count)) else { return nil }
            self = .person(id)
        } else if raw.hasPrefix(Self.albumPrefix) {
            let id = String(raw.dropFirst(Self.albumPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .album(id)
        } else {
            return nil
        }
    }
}

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
